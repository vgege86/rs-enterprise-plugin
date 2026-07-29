<#
.SYNOPSIS
    Instala en el servidor del cliente el contenido de este paquete (instalacion limpia o
    actualizador), haciendo backup previo de cada carpeta destino.

    NO toca la base de datos. Los scripts SQL se ejecutan aparte con Ejecutar-Scripts.ps1
    (ver readme.txt para el orden correcto).

.DESCRIPTION
    Las rutas de instalacion y de backup salen de rutas.json, que tiene una entrada por
    entorno (DESA / TEST / PROD). Por cada carpeta de modulo presente en el paquete:

      1. Si la carpeta destino existe -> backup ZIP en <backup>\<ENTORNO>_<modulo>_<timestamp>.zip
      2. Copia del contenido del paquete sobre el destino (sin borrar lo que no viene)

    En modo Actualizacion se aborta si el paquete contiene ficheros de configuracion
    (*.config, appsettings*.json): un actualizador NUNCA debe pisar la configuracion del
    cliente. Es una defensa en profundidad — el generador ya los excluye.

.PARAMETER Entorno
    DESA | TEST | PROD. Debe existir como clave en rutas.json.

.PARAMETER Modo
    Instalacion (paquete completo) | Actualizacion (entrega incremental). Default: se deduce
    del readme.txt del paquete; si no se puede, Actualizacion (el mas restrictivo).

.PARAMETER RutasJson
    Ruta del rutas.json. Default: el que acompana a este script.

.PARAMETER SinBackup
    Omite el backup previo. Usar solo si el backup se ha hecho por otros medios.

.PARAMETER Simular
    No copia nada: muestra que haria (backup + ficheros por modulo).

.EXAMPLE
    .\Instalar.ps1 -Entorno TEST
    .\Instalar.ps1 -Entorno PROD -Simular
#>
param(
    [Parameter(Mandatory=$true)][ValidateSet('DESA','TEST','PROD')][string]$Entorno,
    [ValidateSet('Instalacion','Actualizacion')][string]$Modo = "",
    [string]$RutasJson = "",
    [switch]$SinBackup,
    [switch]$Simular
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$paquete = $PSScriptRoot
if (-not $RutasJson) { $RutasJson = Join-Path $paquete "rutas.json" }
if (!(Test-Path $RutasJson)) { Write-Host "ERROR: no se encuentra rutas.json: $RutasJson"; exit 1 }

$cfg = Get-Content $RutasJson -Raw -Encoding UTF8 | ConvertFrom-Json
$ent = $cfg.entornos.$Entorno
if (-not $ent) { Write-Host "ERROR: el entorno '$Entorno' no esta definido en rutas.json"; exit 1 }

# Modo: si no viene por parametro, deducir del readme del paquete
if (-not $Modo) {
    $readme = Join-Path $paquete "readme.txt"
    $Modo = if ((Test-Path $readme) -and ((Get-Content $readme -Raw -Encoding UTF8) -match 'INSTALACION LIMPIA')) { 'Instalacion' } else { 'Actualizacion' }
}

Write-Host "== Modo $Modo — entorno $Entorno =="
Write-Host "Paquete: $paquete"

# --- Modulos presentes en el paquete (carpeta -> ruta destino segun rutas.json) ---
# Modulos\ va dentro de ServiceManager\ en el paquete, pero puede tener destino propio.
$mapa = [ordered]@{
    'AgendaWeb'              = $ent.modulos.AgendaWeb
    'Exes'                   = $ent.modulos.Exes
    'ServiceManager\Modulos' = $ent.modulos.Modulos
    'ServiceManager'         = $ent.modulos.ServiceManager
}

$presentes = @()
foreach ($k in $mapa.Keys) {
    $src = Join-Path $paquete $k
    if (Test-Path $src) {
        $n = @(Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($n -gt 0) { $presentes += [PSCustomObject]@{ Modulo = $k; Origen = $src; Destino = $mapa[$k]; Ficheros = $n } }
    }
}
if ($presentes.Count -eq 0) { Write-Host "ERROR: el paquete no contiene ninguna carpeta de modulo con ficheros."; exit 1 }

# ServiceManager entero incluye Modulos: si ambos se instalan, excluir Modulos de la copia del host
$instalaModulosAparte = @($presentes | Where-Object { $_.Modulo -eq 'ServiceManager\Modulos' }).Count -gt 0

# --- Gate: en Actualizacion no viaja la configuracion FUNCIONAL del cliente ---
# Los *.config del binario (RSProcIN.exe.config, DLL .config) SI son parte de la entrega: llevan los
# binding redirects y separarlos de sus DLL provoca FileLoadException. Lo que no puede pisarse es la
# configuracion del entorno: web.config, el <proceso>.xml de cada batch y appsettings*.json.
if ($Modo -eq 'Actualizacion') {
    $config = @()
    foreach ($p in $presentes) {
        $ficheros = @(Get-ChildItem $p.Origen -Recurse -File -ErrorAction SilentlyContinue)
        $config += $ficheros | Where-Object { $_.Name -ieq 'web.config' -or $_.Name -like 'appsettings*.json' }
        $exeNames = @($ficheros | Where-Object { $_.Extension -eq '.exe' } | ForEach-Object { $_.BaseName.ToLower() })
        if ($exeNames.Count -gt 0) {
            $config += $ficheros | Where-Object { $_.Extension -eq '.xml' -and $exeNames -contains $_.BaseName.ToLower() }
        }
    }
    if ($config.Count -gt 0) {
        Write-Host "ERROR: el actualizador trae configuracion del entorno — instalarla pisaria la del cliente:"
        $config | Sort-Object FullName -Unique | ForEach-Object { Write-Host "  $($_.FullName.Substring($paquete.Length + 1))" }
        Write-Host "Retirala del paquete y vuelve a ejecutar (los parametros nuevos van en readme.txt)."
        exit 1
    }
}

# --- Validacion de destinos antes de tocar nada ---
$sinRuta = @($presentes | Where-Object { -not $_.Destino })
if ($sinRuta.Count -gt 0) {
    Write-Host "ERROR: hay modulos en el paquete sin ruta de instalacion en rutas.json (entorno $Entorno):"
    $sinRuta | ForEach-Object { Write-Host "  $($_.Modulo)" }
    exit 1
}

$backupRoot = $ent.backup
if (-not $SinBackup -and -not $backupRoot) {
    Write-Host "ERROR: 'backup' no definido para el entorno $Entorno en rutas.json (usa -SinBackup para omitirlo conscientemente)."
    exit 1
}

Write-Host "`nModulos a instalar:"
$presentes | ForEach-Object { Write-Host ("  {0,-24} {1,5} ficheros -> {2}" -f $_.Modulo, $_.Ficheros, $_.Destino) }
if ($Simular) { Write-Host "`n(-Simular: no se copia nada)" }

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$fallos = @()

foreach ($p in $presentes) {
    Write-Host "`n--- $($p.Modulo) ---"

    # 1. Backup del destino actual
    if (-not $SinBackup) {
        if (Test-Path $p.Destino) {
            $nombre = ($p.Modulo -replace '[\\/]', '_')
            $zip = Join-Path $backupRoot "${Entorno}_${nombre}_${stamp}.zip"
            if ($Simular) {
                Write-Host "SIMULADO backup: $($p.Destino) -> $zip"
            } else {
                New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
                Write-Host "Backup: $($p.Destino) -> $zip"
                try {
                    Compress-Archive -Path (Join-Path $p.Destino '*') -DestinationPath $zip -Force -ErrorAction Stop
                } catch {
                    Write-Host "ERROR: backup fallido de $($p.Modulo): $_"
                    Write-Host "No se instala este modulo (no se pisa sin copia de seguridad)."
                    $fallos += $p.Modulo
                    continue
                }
            }
        } else {
            Write-Host "Destino no existe todavia ($($p.Destino)) — sin backup previo."
        }
    }

    # 2. Copia
    if ($Simular) { Write-Host "SIMULADO copia: $($p.Origen)\* -> $($p.Destino)"; continue }

    New-Item -ItemType Directory -Path $p.Destino -Force | Out-Null
    try {
        if ($p.Modulo -eq 'ServiceManager' -and $instalaModulosAparte) {
            # El host se copia sin su subcarpeta Modulos (se instala aparte, con su propio destino)
            Get-ChildItem $p.Origen -Force | Where-Object { $_.Name -ne 'Modulos' } |
                ForEach-Object { Copy-Item $_.FullName -Destination $p.Destino -Recurse -Force }
        } else {
            Copy-Item (Join-Path $p.Origen '*') -Destination $p.Destino -Recurse -Force
        }
        Write-Host "OK — $($p.Ficheros) ficheros instalados en $($p.Destino)"
    } catch {
        Write-Host "ERROR: copia fallida de $($p.Modulo): $_"
        $fallos += $p.Modulo
    }
}

Write-Host "`n== Resumen: $($presentes.Count - $fallos.Count)/$($presentes.Count) modulos instalados =="
if ($fallos.Count -gt 0) {
    Write-Host "Fallos: $($fallos -join ', ')"
    Write-Host "Los backups ZIP quedan en $backupRoot para restaurar manualmente."
    exit 1
}
Write-Host "Revisa readme.txt: scripts SQL a ejecutar y parametros de configuracion a anadir a mano."
