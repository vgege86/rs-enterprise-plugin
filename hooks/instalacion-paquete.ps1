<#
.SYNOPSIS
    Anade a un paquete (instalador completo o actualizador) los ficheros de instalacion en
    cliente, comunes a ambos modos:

      Instalar.ps1          backup + copia de carpetas (NO toca BD)
      Ejecutar-Scripts.ps1  ejecucion ordenada y fail-fast de los .sql
      rutas.json            rutas de instalacion y backup, una entrada por entorno
      readme.txt            esqueleto (el agente lo reescribe con el contenido real)
      + en modo Instalacion:
          Scripts\00-RVERSIONES.sql                     DDL de la tabla de versiones
          Scripts\PorEntorno\99-RVERSIONES-<ENT>.sql    fila base de la instalacion, un
                                                        fichero por entorno declarado

    Las plantillas viven versionadas en assets\instalacion\ del plugin: la logica de backup e
    instalacion no la reescribe el modelo en cada entrega. El insert inicial de RVERSIONES se
    genera aqui (no lo redacta el modelo): sin esa fila, el primer /rs-actualizador de ese
    entorno no tiene fecha de partida para el delta.

.PARAMETER workspace  Ruta trunk del proyecto
.PARAMETER destino    Carpeta del paquete (Instalador\ o Actualizador\<ENTORNO>_<AAAAMMDD>\)
.PARAMETER modo       Instalacion | Actualizacion
.PARAMETER entorno    DESA|TEST|PROD (solo informativo en modo Actualizacion)
.PARAMETER motor      ORACLE|SQLSERVER. Si se omite, se resuelve con get-config.ps1
.PARAMETER Soluciones Lista ;-separada de soluciones a registrar en RVERSIONES. Si se omite, se
                      deduce de la config del proyecto (batch + agendaweb + modulos).

.EXAMPLE
    .\instalacion-paquete.ps1 "C:\SVN\RS\<P>\trunk" "C:\AIS\<P>\Instalador" Instalacion
    .\instalacion-paquete.ps1 "C:\SVN\RS\<P>\trunk" "C:\AIS\<P>\Instalador" Instalacion -Soluciones "RSProcIN;AgendaWeb"
    .\instalacion-paquete.ps1 "C:\SVN\RS\<P>\trunk" "C:\AIS\<P>\Actualizador\TEST_20260729" Actualizacion TEST
#>
param(
    [Parameter(Mandatory=$true)][string]$workspace,
    [Parameter(Mandatory=$true)][string]$destino,
    [Parameter(Mandatory=$true)][ValidateSet('Instalacion','Actualizacion')][string]$modo,
    [string]$entorno = "",
    [string]$motor = "",
    [string]$Soluciones = "",
    [switch]$DotSourceOnly
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

function Test-RsAuthEntornoCoherente {
    <#  Revisa el bloque `bd` de UN entorno y devuelve los avisos que merece.

        El bloque viaja LITERAL de la config del proyecto a rutas.json, y rutas.json es lo que
        Ejecutar-Scripts.ps1 lee en el servidor del cliente. Una declaracion incoherente no da
        error al generar: se descubre cuando alguien esta delante del servidor del cliente
        intentando instalar. Por eso se avisa AQUI, en la generacion, y no solo alli.

        Los tres casos, por orden de lo que cuestan:
          - 'autenticacion' externa Y 'usuario' a la vez: contradictorio. En modo wallet el
            usuario no se envia, asi que uno de los dos sobra y nadie sabe cual es la verdad.
            Ejecutar-Scripts.ps1 ya no se queda sin salida por esto, pero sigue sin poder
            adivinarlo: la decision es de quien prepara la entrega.
          - wallet con 'conexion' que no es un alias de tnsnames.ora: el wallet indexa la
            credencial por el texto exacto del alias, y un descriptor o un host:puerto/servicio
            dan un ORA-12154 que parece de red.
          - ni 'autenticacion' ni 'usuario': el cliente tendra que teclear el usuario. No es un
            error, pero conviene saberlo antes de entregar.

        Devuelve una lista de cadenas; vacia = coherente.  #>
    param($Bd, [string]$Entorno)
    $avisos = @()
    if (-not $Bd) { return $avisos }
    $auth    = "$($Bd.autenticacion)".Trim()
    $usuario = "$($Bd.usuario)".Trim()
    $conex   = "$($Bd.conexion)".Trim()
    $externa = $auth -match '(?i)^(wallet|externa|integrada)$'

    if ($externa -and $usuario) {
        $avisos += "[$Entorno] declara autenticacion '$auth' Y usuario '$usuario' a la vez. En modo externo el usuario NO se envia: sobra uno de los dos y el paquete no puede adivinar cual."
    }
    if ($externa -and $conex -and ($conex.StartsWith('(') -or $conex -match '[\s/@]' -or $conex -match ':\d')) {
        $avisos += "[$Entorno] declara autenticacion externa pero 'conexion' no es un alias de tnsnames.ora ('$conex'). Con wallet la credencial se busca por el texto EXACTO del alias -> ORA-12154."
    }
    if (-not $auth -and -not $usuario) {
        $avisos += "[$Entorno] no declara 'autenticacion' ni 'usuario': el cliente tendra que teclear el usuario al instalar."
    }
    return $avisos
}

if ($DotSourceOnly) { return }

if (!(Test-Path $destino)) { Write-Host "ERROR: destino no encontrado: $destino"; exit 1 }

$pluginRoot = Split-Path $PSScriptRoot -Parent
$assets     = Join-Path $pluginRoot "assets\instalacion"
if (!(Test-Path $assets)) { Write-Host "ERROR: plantillas no encontradas: $assets"; exit 1 }

$proyecto = if ((Split-Path $workspace -Leaf) -eq 'trunk') { Split-Path (Split-Path $workspace -Parent) -Leaf } else { Split-Path $workspace -Leaf }
$copiados = @()

# --- 1. Scripts PS de cliente ---
foreach ($f in @('Instalar.ps1','Ejecutar-Scripts.ps1')) {
    Copy-Item (Join-Path $assets $f) (Join-Path $destino $f) -Force
    $copiados += $f
}

# --- 2. rutas.json: desde la config del proyecto si tiene bloque 'entornos'; si no, plantilla ---
$rutasOut = Join-Path $destino "rutas.json"
$cfgPaths = @("docs\$proyecto-actualizador.json", "docs\$proyecto-instalador.json") |
            ForEach-Object { Join-Path $workspace $_ } | Where-Object { Test-Path $_ }

$entornosCfg = $null
$cfgObj      = $null
foreach ($p in $cfgPaths) {
    $c = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $cfgObj) { $cfgObj = $c }
    if ($c.entornos) { $entornosCfg = $c.entornos; $cfgObj = $c; Write-Host "rutas.json <- $p"; break }
}

if ($entornosCfg) {
    [ordered]@{
        _comentario = "Rutas de instalacion y backup en el servidor del cliente. Sin contrasenas: Ejecutar-Scripts.ps1 las pide por consola y nunca las pasa por la linea de comandos. Para autenticacion externa (wallet Oracle / integrada SQL Server), en el bloque bd: autenticacion=wallet, usuario vacio, conexion = ALIAS de tnsnames.ora y tnsAdmin = carpeta del wallet."
        proyecto    = $proyecto
        entornos    = $entornosCfg
    } | ConvertTo-Json -Depth 6 | Set-Content $rutasOut -Encoding UTF8

    # El bloque 'bd' se acaba de copiar LITERAL al rutas.json que viaja al cliente. Si es
    # incoherente, el sitio barato de enterarse es aqui; el caro es el servidor del cliente.
    $avisosAuth = @()
    foreach ($e in $entornosCfg.PSObject.Properties) {
        $avisosAuth += Test-RsAuthEntornoCoherente -Bd $e.Value.bd -Entorno $e.Name
    }
    if ($avisosAuth.Count -gt 0) {
        Write-Host "AVISO: la declaracion de conexion de rutas.json tiene $($avisosAuth.Count) incoherencia(s):"
        foreach ($a in $avisosAuth) { Write-Host "       - $a" }
        Write-Host "       No bloquea la generacion: Ejecutar-Scripts.ps1 resuelve el modo por evidencia y"
        Write-Host "       ofrece usuario/contrasena si hace falta. Pero corrigelo antes de entregar."
    }
} else {
    (Get-Content (Join-Path $assets "rutas.json.tpl") -Raw -Encoding UTF8).Replace('<PROYECTO>', $proyecto) |
        Set-Content $rutasOut -Encoding UTF8
    Write-Host "AVISO: no habia bloque 'entornos' en la config del proyecto — rutas.json va como PLANTILLA."
    Write-Host "       Hay que rellenar rutas de instalacion, backup y conexion antes de entregarlo."
}
$copiados += "rutas.json"

# --- 3. DDL de RVERSIONES (solo instalacion limpia: en el cliente la tabla aun no existe) ---
if ($modo -eq 'Instalacion') {
    if (-not $motor) {
        try {
            $cfg = & (Join-Path $PSScriptRoot "get-config.ps1") $workspace | ConvertFrom-Json
            if ($cfg.motor) { $motor = "$($cfg.motor)".ToUpper() }
        } catch { }
    }
    $scriptsDir = Join-Path $destino "Scripts"
    New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null

    $ddl = switch ($motor) {
        'ORACLE'    { 'RVERSIONES-oracle.sql' }
        'SQLSERVER' { 'RVERSIONES-sqlserver.sql' }
        default     { $null }
    }
    if ($ddl) {
        Copy-Item (Join-Path $assets $ddl) (Join-Path $scriptsDir "00-RVERSIONES.sql") -Force
        $copiados += "Scripts\00-RVERSIONES.sql ($motor)"
    } else {
        foreach ($f in @('RVERSIONES-oracle.sql','RVERSIONES-sqlserver.sql')) {
            Copy-Item (Join-Path $assets $f) (Join-Path $scriptsDir "00-$f") -Force
        }
        Write-Host "AVISO: motor no resuelto — se copian los dos DDL de RVERSIONES; borra el que no aplique."
        $copiados += "Scripts\00-RVERSIONES-*.sql (ambos motores)"
    }

    # --- 3b. Fila base de RVERSIONES, un fichero por entorno ---
    # Sin esta fila, el primer /rs-actualizador de ese entorno no tiene FECHA_CORTE de partida
    # y hay que darsela a mano. Se genera aqui y no lo redacta el modelo: es determinista.
    # Un fichero por entorno (y no un placeholder sustituido en ejecucion) para que el DBA del
    # cliente lea exactamente el SQL que va a correr. Ejecutar-Scripts.ps1 lanza solo el suyo.
    $lista = @()
    if ($Soluciones) {
        $lista = @($Soluciones -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } elseif ($cfgObj) {
        if ($cfgObj.batch)                  { $lista += @($cfgObj.batch) }
        if ($cfgObj.agendaweb.sln)          { $lista += ([IO.Path]::GetFileNameWithoutExtension("$($cfgObj.agendaweb.sln)")) }
        if ($cfgObj.servicemanager.modulos) { $lista += @($cfgObj.servicemanager.modulos) }
    }
    $lista = @($lista | Where-Object { $_ } | Select-Object -Unique)

    if ($lista.Count -eq 0) {
        Write-Host "AVISO: no se pudo determinar la lista de soluciones — no se genera la fila base de RVERSIONES."
        Write-Host "       Pasa -Soluciones `"<Sol1;Sol2>`" o rellena 'batch'/'agendaweb'/'servicemanager' en la config."
    } else {
        $hoy      = Get-Date -Format 'yyyy-MM-dd'
        $version  = "INSTALACION_$(Get-Date -Format 'yyyyMMdd')"
        $desc     = "Instalacion inicial del producto"
        $entornos = if ($entornosCfg) { @($entornosCfg.PSObject.Properties.Name) } else { @('DESA','TEST','PROD') }
        $porEntDir = Join-Path $scriptsDir "PorEntorno"
        New-Item -ItemType Directory -Path $porEntDir -Force | Out-Null

        foreach ($ent in $entornos) {
            $e = "$ent".ToUpper()
            if ($e -notin @('DESA','TEST','PROD')) {
                Write-Host "AVISO: entorno '$ent' no es DESA/TEST/PROD — se omite su fila base (el CHECK de RVERSIONES lo rechazaria)."
                continue
            }
            # El motor puede variar por entorno; si no se declara, el del proyecto
            $mEnt = $motor
            if ($entornosCfg -and $entornosCfg.$ent.bd.motor) { $mEnt = "$($entornosCfg.$ent.bd.motor)".ToUpper() }

            $sql = @(
                "-- =====================================================================================",
                "-- RVERSIONES - fila base de la instalacion inicial de $proyecto en $e",
                "-- Generado: $(Get-Date -Format 'yyyy-MM-dd HH:mm')   Motor: $mEnt",
                "-- Idempotente: reejecutarlo no duplica filas.",
                "--",
                "-- FECHA_CORTE = $hoy es el punto de partida del delta del primer /rs-actualizador",
                "-- de este entorno. Si no se ejecuta, hay que darle esa fecha a mano.",
                "-- Requiere que 00-RVERSIONES.sql se haya ejecutado antes (crea la tabla).",
                "-- =====================================================================================",
                ""
            )
            if ($mEnt -eq 'ORACLE') {
                # NEXTVAL no se admite junto a una subconsulta en el WHERE (ORA-02287) -> PL/SQL
                $sql += @("DECLARE", "    v_existe NUMBER;", "BEGIN")
                foreach ($s in $lista) {
                    $sn = "$s".Replace("'","''")
                    $sql += @(
                        "    SELECT COUNT(*) INTO v_existe FROM RVERSIONES",
                        "     WHERE ENTORNO = '$e' AND SOLUCION = '$sn' AND VERSION = '$version';",
                        "    IF v_existe = 0 THEN",
                        "        INSERT INTO RVERSIONES (ID_VERSION, ENTORNO, SOLUCION, VERSION, FECHA_CORTE, DESCRIPCION, USUARIO)",
                        "        VALUES (SEQ_RVERSIONES.NEXTVAL, '$e', '$sn', '$version', TO_DATE('$hoy','YYYY-MM-DD'), '$desc', USER);",
                        "    END IF;",
                        ""
                    )
                }
                $sql += @("    COMMIT;", "END;", "/")
            }
            elseif ($mEnt -eq 'SQLSERVER') {
                foreach ($s in $lista) {
                    $sn = "$s".Replace("'","''")
                    $sql += @(
                        "IF NOT EXISTS (SELECT 1 FROM RVERSIONES WHERE ENTORNO = '$e' AND SOLUCION = '$sn' AND VERSION = '$version')",
                        "    INSERT INTO RVERSIONES (ENTORNO, SOLUCION, VERSION, FECHA_CORTE, DESCRIPCION, USUARIO)",
                        "    VALUES ('$e', '$sn', '$version', CONVERT(DATETIME,'$hoy',120), '$desc', SUSER_SNAME());",
                        "GO",
                        ""
                    )
                }
            }
            else {
                Write-Host "AVISO: motor no resuelto para $e — no se genera su fila base de RVERSIONES."
                continue
            }
            # UTF-8 SIN BOM: sqlplus interpreta el BOM como parte de la primera sentencia
            [IO.File]::WriteAllLines((Join-Path $porEntDir "99-RVERSIONES-$e.sql"), $sql,
                                     (New-Object Text.UTF8Encoding $false))
            $copiados += "Scripts\PorEntorno\99-RVERSIONES-$e.sql ($mEnt, $($lista.Count) soluciones)"
        }
    }

    # --- 3c. Manifiesto scripts.json: fija el ORDEN de ejecucion en el cliente ---
    # Sin manifiesto, Ejecutar-Scripts.ps1 descubre los .sql por convencion y los ordena POR
    # NOMBRE. Con los ficheros de objetos en la carpeta eso es un orden equivocado, no solo
    # feo: "<P>-02-Vistas.sql" y "<P>-05-Triggers.sql" caen ANTES que "<P>-CreacionTablas.sql",
    # asi que el CREATE TRIGGER se lanza sobre tablas que aun no existen (ORA-00942 / Msg 4902)
    # y, como la ejecucion es fail-fast, la instalacion aborta ahi. Ademas el maestro
    # "<P>-CreacionObjetos.sql" tambien casaba con el comodin y volvia a crearlo todo.
    $manifiesto = @()
    $faltanObj  = @()

    foreach ($f in @(Get-ChildItem $scriptsDir -Filter '00-*.sql' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $manifiesto += [ordered]@{ ruta = $f.Name }
    }

    # Orden de dependencias: secuencias -> tablas+indices -> vistas -> funciones ->
    # procedimientos -> triggers -> sinonimos. Es el mismo que declara el maestro.
    $ordenObjetos = @(
        "$proyecto-01-Secuencias.sql",
        "$proyecto-CreacionTablas.sql",
        "$proyecto-02-Vistas.sql",
        "$proyecto-03-Funciones.sql",
        "$proyecto-04-Procedimientos.sql",
        "$proyecto-05-Triggers.sql",
        "$proyecto-06-Sinonimos.sql"
    )
    foreach ($n in $ordenObjetos) {
        if (Test-Path (Join-Path $scriptsDir $n)) { $manifiesto += [ordered]@{ ruta = $n } }
        else { $faltanObj += $n }
    }

    # Maestros: viajan, no se ejecutan (los encadenan a ellos; ejecutarlos duplicaria todo).
    foreach ($m in @("$proyecto-CreacionObjetos.sql", "Inserts\_run_all.sql")) {
        if (Test-Path (Join-Path $scriptsDir $m)) {
            $manifiesto += [ordered]@{
                ruta      = $m.Replace('\','/')
                ejecutar  = $false
                _nota     = "Encadena a los demas ficheros; se entrega para poder lanzarlo a mano, no se ejecuta aqui."
            }
        }
    }

    $insDir = Join-Path $scriptsDir "Inserts"
    foreach ($f in @(Get-ChildItem $insDir -Filter '*.sql' -File -ErrorAction SilentlyContinue |
                     Where-Object { -not $_.Name.StartsWith('_') } | Sort-Object Name)) {
        $manifiesto += [ordered]@{ ruta = "Inserts/$($f.Name)" }
    }

    $porEntDir2 = Join-Path $scriptsDir "PorEntorno"
    foreach ($f in @(Get-ChildItem $porEntDir2 -Filter '99-RVERSIONES-*.sql' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $ent2 = [IO.Path]::GetFileNameWithoutExtension($f.Name) -replace '^99-RVERSIONES-', ''
        $manifiesto += [ordered]@{ ruta = "PorEntorno/$($f.Name)"; entorno = $ent2 }
    }

    [ordered]@{
        _comentario = "Orden de ejecucion de los .sql de este paquete. MANDA sobre el descubrimiento por carpetas de Ejecutar-Scripts.ps1. Generado por instalacion-paquete.ps1 a partir de lo que hay realmente en Scripts\."
        _orden      = "RVERSIONES (DDL) -> secuencias -> tablas+indices -> vistas -> funciones -> procedimientos -> triggers -> sinonimos -> inserts parametricos -> fila base de RVERSIONES del entorno"
        scripts     = @($manifiesto)
    } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $scriptsDir "scripts.json") -Encoding UTF8
    $copiados += "Scripts\scripts.json ($($manifiesto.Count) entradas, orden de dependencias)"

    if ($faltanObj.Count -gt 0) {
        Write-Host ""
        Write-Host "AVISO: el paquete NO lleva $($faltanObj.Count) de los ficheros de objetos esperados:"
        $faltanObj | ForEach-Object { Write-Host "         Scripts\$_" }
        Write-Host "       Vistas, funciones, procedimientos, triggers o sinonimos faltarian en el"
        Write-Host "       cliente. Repetir la etapa de scripts (installer-scripts.ps1 -Solo objetos)"
        Write-Host "       antes de entregar."
    }
}

# --- 4. readme.txt (esqueleto; el agente lo sobreescribe con el contenido real) ---
$readme = Join-Path $destino "readme.txt"
if (!(Test-Path $readme)) {
    $titulo = if ($modo -eq 'Instalacion') { "INSTALACION LIMPIA" } else { "ACTUALIZADOR" }
    $ent    = if ($entorno) { " - entorno $entorno" } else { "" }
    # Nota de configuracion: son DOS bloques OPUESTOS y antes iban en el mismo saco. El
    # <Exe>.exe.config acompana a su binario y lleva los bindingRedirects — si no viaja, el destino
    # conserva el config viejo y el EXE revienta con FileLoadException; es lo que ya hace bien
    # actualizador-build.ps1 y lo que vigila el gate de binding redirects de installer-batch.ps1.
    # La configuracion del entorno del cliente es justo lo contrario: si viajara, machacaria los
    # ajustes del destino. Esto es lo que lee Operaciones para decidir que copia.
    $notaConfig = if ($modo -eq 'Actualizacion') {
        @(
            "NOTA SOBRE LOS FICHEROS DE CONFIGURACION",
            "",
            "   SI VIAJA SIEMPRE:",
            "     <Exe>.exe.config   Acompana a su binario y lleva los bindingRedirects. Si no se",
            "                        copia, el destino conserva el config viejo y el proceso falla",
            "                        al arrancar con FileLoadException. Va junto al .exe, siempre;",
            "                        no se separa de el ni se reconstruye a mano.",
            "",
            "   NO VIAJA NUNCA (es configuracion del entorno del cliente):",
            "     web.config         a cualquier nivel de AgendaWeb",
            "     appsettings*.json  configuracion del host y de los modulos",
            "     <proceso>.xml      el XML de configuracion de cada batch (RSCore.xml, RSActBD.xml,",
            "                        Mul2Bane.xml, RSProcOut.xml, ...)",
            "",
            "   Estos ultimos se modifican A MANO en el destino: llevan las cadenas de conexion,",
            "   rutas y credenciales del cliente. Los parametros nuevos van en el punto 3."
        )
    } else {
        @(
            "NOTA SOBRE LOS FICHEROS DE CONFIGURACION",
            "",
            "   En una instalacion limpia viaja TODO, incluida la configuracion: el cliente no tiene",
            "   nada previo que pisar. Pero los valores son de desarrollo — revisar el punto 3 y",
            "   ajustar cadenas de conexion, rutas y credenciales antes de arrancar nada.",
            "",
            "   El <Exe>.exe.config lo genera MSBuild en cada build y lleva los bindingRedirects: la",
            "   copia valida es la que acompana al binario. No reconstruirlo ni editarlo a mano."
        )
    }
    @(
        "$titulo - $proyecto$ent",
        "Generado: $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
        "",
        "1. SCRIPTS SQL",
        "   (pendiente de completar)",
        "",
        "2. INSTALACION DE FICHEROS",
        "   .\Instalar.ps1 -Entorno <DESA|TEST|PROD>",
        "   Hace backup ZIP de cada carpeta destino antes de copiar (ver rutas.json).",
        "",
        "3. PARAMETROS DE CONFIGURACION",
        "   (pendiente de completar)",
        "",
        $notaConfig
    ) | Set-Content $readme -Encoding UTF8
    $copiados += "readme.txt (esqueleto)"
}

Write-Host "`nOK — paquete de instalacion preparado en $destino"
$copiados | ForEach-Object { Write-Host "  $_" }
