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
      scripts\installer-ddl.py      (tablas + índices + valores DEFAULT desde el model.json
                                     — no toca BD. Los DEFAULT salen del campo `default` de
                                     cada columna, que rellena hooks\sync-from-db.ps1: un
                                     modelo sincronizado antes de eso los deja a NULL)
      scripts\installer-objects.py  (secuencias/vistas/funciones/procs/triggers/sinónimos
                                     desde la BD viva — no están en el model.json.
                                     ORACLE vía diccionario ALL_*, SQLSERVER vía sys.*)
      scripts\installer-inserts.py  (inserts por tabla paramétrica, vista "Parametricas")

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

.EXAMPLE
    .\installer-scripts.ps1 "C:\SVN\RS\<Proyecto>\trunk" "C:\AIS\<Proyecto>\Instalador"
.EXAMPLE
    .\installer-scripts.ps1 "<trunk>" "<destino>" -Tablas "RTABLA1;RTABLA2"
#>
param(
    [Parameter(Mandatory=$true)][string]$workspace,
    [Parameter(Mandatory=$true)][string]$destino,
    [ValidateSet("todo","ddl","objetos","inserts")][string]$Solo = "todo",
    [string]$Tablas = ""
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
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

# Los seis tipos de objeto, por nombre. El inventario final los recorre UNO A UNO y marca el
# que falte: antes era un Get-ChildItem con comodín y, si no se había generado ninguno, el
# listado salía vacío y el resumen decía "OK" igual — las vistas y los procedimientos podían
# faltar del paquete entero sin que nada lo dijera.
$tiposObjeto = @("01-Secuencias","02-Vistas","03-Funciones","04-Procedimientos","05-Triggers","06-Sinonimos")
$faltanObj   = @()
if ($Solo -ne "todo") { Write-Host "Regeneración selectiva: $Solo" }

try {
    # --- Config de BD resuelta una vez y compartida con los scripts Python ---
    # Solo hace falta para las partes que tocan BD. Si algo sale mal se sigue adelante sin
    # cachear: cada script Python vuelve a resolverla por su cuenta (comportamiento anterior).
    if ($Solo -ne "ddl") {
        $getCfg = Join-Path $PSScriptRoot "get-config.ps1"
        try {
            $cfgJson = (& $getCfg $workspace) -join "`n"
            $parsed  = $cfgJson | ConvertFrom-Json
            if ($parsed.PSObject.Properties.Name -contains "error") {
                Write-Host "AVISO: get-config.ps1 devolvió error ($($parsed.error)) — cada script resolverá la config por su cuenta"
            } else {
                $cfgTmp = [System.IO.Path]::GetTempFileName()
                [System.IO.File]::WriteAllText($cfgTmp, $cfgJson, (New-Object System.Text.UTF8Encoding($false)))
                $env:RS_DB_CONFIG_JSON = $cfgTmp
            }
        } catch {
            Write-Host "AVISO: no se pudo cachear la config de BD ($($_.Exception.Message)) — cada script la resolverá por su cuenta"
        }
    }

    # --- DDL tablas + índices (sin schema) ---
    if ($Solo -eq "todo" -or $Solo -eq "ddl") {
        Write-Host "== DDL creación de tablas e índices (sin schema) =="
        python "$scriptsDir\installer-ddl.py" "$workspace" "$proyecto" "$ddlOut"
        if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: installer-ddl.py falló (exit $LASTEXITCODE)"; exit 1 }
        if (!(Test-Path $ddlOut)) { Write-Host "ERROR: no se generó $ddlOut"; exit 1 }
    }

    # --- Resto de objetos desde la BD viva ---
    if ($Solo -eq "todo" -or $Solo -eq "objetos") {
        Write-Host "`n== Objetos BD: secuencias, vistas, funciones, procedimientos, triggers, sinónimos =="
        python "$scriptsDir\installer-objects.py" "$workspace" "$proyecto" "$outScripts"
        $objCode = $LASTEXITCODE
        if ($objCode -eq 1) { Write-Host "ERROR: installer-objects.py falló (exit 1)"; exit 1 }
        if ($objCode -eq 2) { Write-Host "AVISO: algún tipo de objeto dio error (exit 2) — revisar log arriba."; $avisos = $true }

        if (!(Test-Path $maestro)) { Write-Host "ERROR: no se generó el maestro $maestro"; exit 1 }
    }

    # --- Inserts paramétricos (uno por tabla) ---
    if ($Solo -eq "todo" -or $Solo -eq "inserts") {
        Write-Host "`n== Inserts tablas paramétricas =="
        if ($Tablas) {
            $env:RS_INSERTS_TABLAS = $Tablas
            Write-Host "   Solo estas tablas: $Tablas"
        }
        python "$scriptsDir\installer-inserts.py" "$workspace" "$proyecto" "$insertsDir"
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
    if ($avisos) { exit 2 }
}
finally {
    # Las variables de entorno son del proceso del hook, pero se limpian igual: el runner
    # puede reutilizar el proceso para otra etapa y no debe heredar un filtro de tablas.
    if ($cfgTmp -and (Test-Path $cfgTmp)) { Remove-Item $cfgTmp -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:RS_DB_CONFIG_JSON -ErrorAction SilentlyContinue
    Remove-Item Env:RS_INSERTS_TABLAS -ErrorAction SilentlyContinue
}
