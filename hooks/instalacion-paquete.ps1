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
    [string]$Soluciones = ""
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

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
        _comentario = "Rutas de instalacion y backup en el servidor del cliente. Sin contrasenas: Ejecutar-Scripts.ps1 las pide por consola."
        proyecto    = $proyecto
        entornos    = $entornosCfg
    } | ConvertTo-Json -Depth 6 | Set-Content $rutasOut -Encoding UTF8
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
}

# --- 4. readme.txt (esqueleto; el agente lo sobreescribe con el contenido real) ---
$readme = Join-Path $destino "readme.txt"
if (!(Test-Path $readme)) {
    $titulo = if ($modo -eq 'Instalacion') { "INSTALACION LIMPIA" } else { "ACTUALIZADOR" }
    $ent    = if ($entorno) { " - entorno $entorno" } else { "" }
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
        "NOTA: los ficheros de configuracion (web.config, *.exe.config) NO viajan en el paquete",
        "      cuando es un actualizador: los parametros nuevos se anaden a mano segun el punto 3."
    ) | Set-Content $readme -Encoding UTF8
    $copiados += "readme.txt (esqueleto)"
}

Write-Host "`nOK — paquete de instalacion preparado en $destino"
$copiados | ForEach-Object { Write-Host "  $_" }
