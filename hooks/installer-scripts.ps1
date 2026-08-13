<#
.SYNOPSIS
    Instalador — genera los scripts SQL de instalación limpia en <destino>\Scripts:
      - <proyecto>-CreacionTablas.sql   (DDL de todas las tablas + índices, SIN schema)
      - <proyecto>-01-Secuencias.sql    (secuencias)
      - <proyecto>-02-Vistas.sql        (vistas)
      - <proyecto>-03-Funciones.sql     (funciones)
      - <proyecto>-04-Procedimientos.sql(procedimientos / packages)
      - <proyecto>-05-Triggers.sql      (triggers)
      - <proyecto>-06-Sinonimos.sql     (sinónimos)
      - <proyecto>-CreacionObjetos.sql  (maestro, en orden de dependencias)
      - Inserts\<TABLA>.sql             (un fichero por tabla paramétrica)

    Delega en los scripts Python del plugin:
      scripts\installer-tablas.py   (tablas, columnas con tipo y tamaño EXACTOS, NOT NULL,
                                     DEFAULT, IDENTITY, PK, UNIQUE, CHECK, índices y FK,
                                     desde la BD VIVA. ⛔ Ya NO sale del model.json: la
                                     traducción BD -> modelo es lossy y el modelo se queda
                                     desfasado — ver scripts\installer-ddl.py, retirado)
      scripts\installer-objects.py  (secuencias/vistas/funciones/procs/triggers/sinónimos
                                     desde la BD viva.
                                     ORACLE vía diccionario ALL_*, SQLSERVER vía sys.*)
      scripts\installer-inserts.py  (inserts por tabla paramétrica, vista "Parametricas")
      scripts\installer-gate-fuga.py (gate: ningún artefacto del paquete puede llevar
                                     descripciones del modelo, marcas pii/safe ni tickets)

    ⛔ La etapa `ddl` AHORA NECESITA CONEXIÓN A BD. Antes se generaba sin ella (leía el
    model.json), así que `-Solo ddl` funcionaba sin BD delante. Ya no.

    RENDIMIENTO
      - La config de BD se resuelve UNA sola vez aquí y se pasa a los scripts Python por
        la variable RS_DB_CONFIG_JSON: antes cada uno arrancaba su propio PowerShell para
        releer get-config.ps1. ⛔ Ese fichero NO contiene la password (get-config.ps1 no la
        emite nunca); cada script la sigue leyendo del docs\.rs-databases.json.
      - -Solo regenera una sola parte, y -Tablas un subconjunto de tablas paramétricas:
        tras un error puntual no hace falta repetir toda la etapa.
      - El paralelismo de sesiones BD lo gobierna `parametricas.max_paralelo` del
        docs\<proyecto>-instalador.json, tanto en los inserts como en los objetos.

.PARAMETER workspace  Ruta trunk del proyecto
.PARAMETER destino    Carpeta Instalador
.PARAMETER Solo       todo (default) | ddl | objetos | inserts — qué parte regenerar
.PARAMETER Tablas     Lista "T1;T2" de tablas paramétricas a regenerar. Implica -Solo inserts.
.PARAMETER Conexion   Id de conexión de docs\.rs-databases.json. Si se omite, la principal.
                      Leer como dueño del esquema es la única forma de ver los sinónimos
                      PRIVADOS y todo el PL/SQL: ningún GRANT los expone.
.PARAMETER SinPlsql   Confirma que el esquema NO tiene PL/SQL y permite generar el paquete sin
                      procedimientos. Sin esto, 0 grants EXECUTE es un error duro — ver
                      scripts\installer-objects.py.

.EXAMPLE
    .\installer-scripts.ps1 "C:\SVN\RS\<Proyecto>\trunk" "C:\AIS\<Proyecto>\Instalador"
.EXAMPLE
    .\installer-scripts.ps1 "<trunk>" "<destino>" -Tablas "RTABLA1;RTABLA2"
.EXAMPLE
    .\installer-scripts.ps1 "<trunk>" "<destino>" -Conexion DUENO
#>
param(
    [Parameter(Mandatory=$true)][string]$workspace,
    [Parameter(Mandatory=$true)][string]$destino,
    [ValidateSet("todo","ddl","objetos","inserts")][string]$Solo = "todo",
    [string]$Tablas = "",
    [string]$Conexion = "",
    [switch]$SinPlsql
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# Pedir tablas concretas solo tiene sentido para los inserts: se asume esa parte.
if ($Tablas -and $Solo -eq "todo") { $Solo = "inserts" }

$proyecto = if ((Split-Path $workspace -Leaf) -eq 'trunk') { Split-Path (Split-Path $workspace -Parent) -Leaf } else { Split-Path $workspace -Leaf }
$scriptsDir = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts"

$outScripts = Join-Path $destino "Scripts"
$insertsDir = Join-Path $outScripts "Inserts"
$ddlOut     = Join-Path $outScripts "$proyecto-CreacionTablas.sql"
$maestro    = Join-Path $outScripts "$proyecto-CreacionObjetos.sql"
New-Item -ItemType Directory -Path $insertsDir -Force | Out-Null

$avisos  = $false
$cfgTmp  = ""
$visTmp  = ""
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

# Argumentos comunes de los scripts Python que tocan BD. -Conexion se propaga a TODOS: si solo
# lo recibiera uno, el paquete mezclaría objetos leídos como dueño con inserts leídos con la
# cuenta de consulta.
$argsConexion = @()
if ($Conexion) { $argsConexion = @("--conexion", $Conexion) }

# Los seis tipos de objeto, por nombre. El inventario final los recorre UNO A UNO y marca el
# que falte: antes era un Get-ChildItem con comodín y, si no se había generado ninguno, el
# listado salía vacío y el resumen decía "OK" igual — las vistas y los procedimientos podían
# faltar del paquete entero sin que nada lo dijera.
$tiposObjeto = @("01-Secuencias","02-Vistas","03-Funciones","04-Procedimientos","05-Triggers","06-Sinonimos")
$faltanObj   = @()
if ($Solo -ne "todo") { Write-Host "Regeneración selectiva: $Solo" }

try {
    # --- Config de BD resuelta una vez y compartida con los scripts Python ---
    # Si algo sale mal se sigue adelante sin cachear: cada script Python vuelve a resolverla
    # por su cuenta (comportamiento anterior).
    # ⛔ Ya no se salta para -Solo ddl: desde que el DDL sale de la BD y no del modelo, la
    # etapa de tablas necesita conexión igual que las otras dos.
    $getCfg = Join-Path $PSScriptRoot "get-config.ps1"
    try {
        $cfgJson = (& $getCfg $workspace -Conexion $Conexion) -join "`n"
        $parsed  = $cfgJson | ConvertFrom-Json
        if ($parsed.PSObject.Properties.Name -contains "error") {
            Write-Host "ERROR: get-config.ps1 devolvió error ($($parsed.error))"
            exit 1
        } else {
            $cfgTmp = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($cfgTmp, $cfgJson, (New-Object System.Text.UTF8Encoding($false)))
            $env:RS_DB_CONFIG_JSON = $cfgTmp
            Write-Host "Conexión BD: $($parsed.conexion)  (esquema $($parsed.schema), usuario $($parsed.user))"
        }
    } catch {
        Write-Host "AVISO: no se pudo cachear la config de BD ($($_.Exception.Message)) — cada script la resolverá por su cuenta"
    }

    # Visibilidad de la conexión sobre el esquema: la resuelve UNA vez y la comparten los
    # scripts Python por RS_DB_VISIBILIDAD_JSON. Es lo que decide si un tipo de objeto
    # vacío significa "no hay" o "esta cuenta no lo ve" — ver hooks\db-visibilidad.ps1.
    try {
        $visJson = (& (Join-Path $PSScriptRoot "db-visibilidad.ps1") $workspace -Conexion $Conexion) -join "`n"
        $visTmp  = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($visTmp, $visJson, (New-Object System.Text.UTF8Encoding($false)))
        $env:RS_DB_VISIBILIDAD_JSON = $visTmp
    } catch {
        Write-Host "AVISO: no se pudo diagnosticar la visibilidad del esquema ($($_.Exception.Message))"
    }

    # --- DDL tablas: columnas, PK, UNIQUE, CHECK, DEFAULT, IDENTITY, índices y FK ---
    # Desde la BD VIVA. El model.json ya no es origen de DDL: solo se contrasta para reportar
    # deriva. Ver scripts\installer-tablas.py.
    if ($Solo -eq "todo" -or $Solo -eq "ddl") {
        Write-Host "== DDL creación de tablas (desde la BD viva, sin schema) =="
        $argsDdl = @("$scriptsDir\installer-tablas.py", "$workspace", "$proyecto", "$ddlOut") + $argsConexion
        python @argsDdl
        $ddlCode = $LASTEXITCODE
        # exit 2 = algún tipo llegó sin tamaño. NO es un aviso: el script no ha escrito el
        # fichero, así que continuar dejaría el paquete sin DDL de tablas y el resumen de abajo
        # lo cantaría como ausente. Se corta aquí, que es donde está el diagnóstico.
        if ($ddlCode -ne 0) {
            Write-Host "ERROR: installer-tablas.py falló (exit $ddlCode) — el paquete NO es entregable."
            exit 1
        }
        if (!(Test-Path $ddlOut)) { Write-Host "ERROR: no se generó $ddlOut"; exit 1 }
    }

    # --- Resto de objetos desde la BD viva ---
    if ($Solo -eq "todo" -or $Solo -eq "objetos") {
        Write-Host "`n== Objetos BD: secuencias, vistas, funciones, procedimientos, triggers, sinónimos =="
        $argsObj = @("$scriptsDir\installer-objects.py", "$workspace", "$proyecto", "$outScripts") + $argsConexion
        if ($SinPlsql) { $argsObj += "--sin-plsql" }
        python @argsObj
        $objCode = $LASTEXITCODE
        # exit 1 incluye ahora el caso "esta cuenta no ve NADA del PL/SQL": antes el paquete se
        # generaba igual, con los ficheros de procedimientos vacíos y sin un solo aviso.
        if ($objCode -eq 1) { Write-Host "ERROR: installer-objects.py falló (exit 1) — el paquete NO es entregable."; exit 1 }
        if ($objCode -eq 2) { Write-Host "AVISO: extracción PARCIAL (exit 2) — algún tipo de objeto falló o quedó hueco de cobertura. Revisar log arriba."; $avisos = $true }

        if (!(Test-Path $maestro)) { Write-Host "ERROR: no se generó el maestro $maestro"; exit 1 }
    }

    # --- Inserts paramétricos (uno por tabla) ---
    if ($Solo -eq "todo" -or $Solo -eq "inserts") {
        Write-Host "`n== Inserts tablas paramétricas =="
        if ($Tablas) {
            $env:RS_INSERTS_TABLAS = $Tablas
            Write-Host "   Solo estas tablas: $Tablas"
        }
        $argsIns = @("$scriptsDir\installer-inserts.py", "$workspace", "$proyecto", "$insertsDir") + $argsConexion
        python @argsIns
        $insCode = $LASTEXITCODE
        if ($insCode -eq 1) { Write-Host "ERROR: installer-inserts.py falló (exit 1)"; exit 1 }
        if ($insCode -eq 2) { Write-Host "AVISO: algunas tablas paramétricas dieron error (exit 2) — revisar log arriba."; $avisos = $true }
    }

    $swTotal.Stop()
    $nIns = (Get-ChildItem $insertsDir -Filter *.sql -File -ErrorAction SilentlyContinue).Count
    Write-Host "`nOK — Scripts en $outScripts  ($([math]::Round($swTotal.Elapsed.TotalSeconds,1))s)"
    if (Test-Path $ddlOut)  { Write-Host "   Tablas/índices: $ddlOut" }
    if (Test-Path $maestro) { Write-Host "   Maestro objetos: $maestro" }
    foreach ($t in $tiposObjeto) {
        $nombre = "$proyecto-$t.sql"
        $f = Join-Path $outScripts $nombre
        if (Test-Path $f) { Write-Host ("   {0} ({1:N0} bytes)" -f $nombre, (Get-Item $f).Length) }
        else { Write-Host "   $nombre  AUSENTE"; $faltanObj += $nombre }
    }
    if ($faltanObj.Count -gt 0 -and ($Solo -eq "todo" -or $Solo -eq "objetos")) {
        Write-Host "AVISO: faltan $($faltanObj.Count) fichero(s) de objetos — el paquete iría sin ellos."
        Write-Host "       Repetir con -Solo objetos y revisar el error de arriba."
        $avisos = $true
    }
    Write-Host "   Inserts: $nIns ficheros en $insertsDir"

    # --- Gate: nada de desarrollo puede viajar al cliente ---
    # ⛔ Se comprueba el ARTEFACTO, no se confía en que los generadores se porten bien. Hasta la
    # 3.25.0 el DDL inlineaba las `description` del model.json como comentarios del .sql que se
    # copia al servidor del cliente, y nadie lo había decidido.
    Write-Host "`n== Gate de fuga de metadatos de desarrollo =="
    $modeloPath = Join-Path $workspace "BD\$proyecto-model.json"
    $argsGate = @("$scriptsDir\installer-gate-fuga.py", "$outScripts")
    if (Test-Path $modeloPath) { $argsGate += @("--modelo", "$modeloPath") }
    python @argsGate
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: el paquete contiene metadatos de desarrollo — NO es entregable."
        exit 1
    }

    if ($avisos) { exit 2 }
}
finally {
    # Las variables de entorno son del proceso del hook, pero se limpian igual: el runner
    # puede reutilizar el proceso para otra etapa y no debe heredar un filtro de tablas.
    if ($cfgTmp -and (Test-Path $cfgTmp)) { Remove-Item $cfgTmp -Force -ErrorAction SilentlyContinue }
    if ($visTmp -and (Test-Path $visTmp)) { Remove-Item $visTmp -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:RS_DB_CONFIG_JSON -ErrorAction SilentlyContinue
    Remove-Item Env:RS_DB_VISIBILIDAD_JSON -ErrorAction SilentlyContinue
    Remove-Item Env:RS_INSERTS_TABLAS -ErrorAction SilentlyContinue
}
