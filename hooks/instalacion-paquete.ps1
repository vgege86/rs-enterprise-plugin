<#
.SYNOPSIS
    Anade a un paquete (instalador completo o actualizador) los ficheros de instalacion en
    cliente, comunes a ambos modos:

      Instalar.ps1          backup + copia de carpetas (NO toca BD)
      Ejecutar-Scripts.ps1  ejecucion ordenada y fail-fast de los .sql
      rutas.json            rutas de instalacion y backup, una entrada por entorno
      readme.txt            esqueleto (el agente lo reescribe con el contenido real)
      + en modo Instalacion: el DDL de RVERSIONES en la carpeta de scripts

    Las plantillas viven versionadas en assets\instalacion\ del plugin: la logica de backup e
    instalacion no la reescribe el modelo en cada entrega.

.PARAMETER workspace  Ruta trunk del proyecto
.PARAMETER destino    Carpeta del paquete (Instalador\ o Actualizador\<ENTORNO>_<AAAAMMDD>\)
.PARAMETER modo       Instalacion | Actualizacion
.PARAMETER entorno    DESA|TEST|PROD (solo informativo en modo Actualizacion)
.PARAMETER motor      ORACLE|SQLSERVER. Si se omite, se resuelve con get-config.ps1

.EXAMPLE
    .\instalacion-paquete.ps1 "C:\SVN\RS\<P>\trunk" "C:\AIS\<P>\Instalador" Instalacion
    .\instalacion-paquete.ps1 "C:\SVN\RS\<P>\trunk" "C:\AIS\<P>\Actualizador\TEST_20260729" Actualizacion TEST
#>
param(
    [Parameter(Mandatory=$true)][string]$workspace,
    [Parameter(Mandatory=$true)][string]$destino,
    [Parameter(Mandatory=$true)][ValidateSet('Instalacion','Actualizacion')][string]$modo,
    [string]$entorno = "",
    [string]$motor = ""
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
foreach ($p in $cfgPaths) {
    $c = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($c.entornos) { $entornosCfg = $c.entornos; Write-Host "rutas.json <- $p"; break }
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
