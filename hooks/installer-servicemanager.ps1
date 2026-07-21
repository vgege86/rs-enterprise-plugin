<#
.SYNOPSIS
    Instalador — compila y publica AIS.ServicesManager (net8) a <destino>\ServiceManager y
    los módulos ACTIVOS del cliente a <destino>\ServiceManager\Modulos.

    Host  = OnLine\AISServiceManager\AISServiceManager\AIS.ServicesManager.sln
    Módulos activos = docs\<proyecto>-instalador.json → servicemanager.modulos (array de
    nombres de carpeta bajo OnLine\AISServiceManager\Modulos\; el .sln interno puede tener
    otro nombre).

    De cada módulo se copian a Modulos solo las DLL que NO están ya en el host publicado
    (evita duplicar ArqNet / framework / assemblies compartidos).

.PARAMETER workspace  Ruta trunk del proyecto
.PARAMETER destino    Carpeta Instalador
#>
param(
    [Parameter(Mandatory=$true)][string]$workspace,
    [Parameter(Mandatory=$true)][string]$destino
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$proyecto = if ((Split-Path $workspace -Leaf) -eq 'trunk') { Split-Path (Split-Path $workspace -Parent) -Leaf } else { Split-Path $workspace -Leaf }
$jsonPath = Join-Path $workspace "docs\$proyecto-instalador.json"
if (!(Test-Path $jsonPath)) { Write-Host "ERROR: Config no encontrada: $jsonPath"; exit 1 }
$cfg = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

$hostSln = Join-Path $workspace "OnLine\AISServiceManager\AISServiceManager\AIS.ServicesManager.sln"
if (!(Test-Path $hostSln)) { Write-Host "ERROR: host .sln no encontrada: $hostSln"; exit 1 }

$smDir  = Join-Path $destino "ServiceManager"
$modDir = Join-Path $smDir "Modulos"
if (Test-Path $smDir) { Remove-Item $smDir -Recurse -Force }
New-Item -ItemType Directory -Path $modDir -Force | Out-Null

# --- Host ---
Write-Host "== Publicando AIS.ServicesManager (host) -> $smDir =="
dotnet publish "$hostSln" -c Release -o "$smDir"
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: publish host falló (exit $LASTEXITCODE)"; exit $LASTEXITCODE }

# DLLs ya presentes en el host (para deduplicar módulos)
$hostDlls = @{}
Get-ChildItem $smDir -Filter *.dll -File -ErrorAction SilentlyContinue | ForEach-Object { $hostDlls[$_.Name] = $true }

# --- Módulos ---
$modulos = @($cfg.servicemanager.modulos)
Write-Host "`n== Módulos activos: $($modulos.Count) =="
$fallos = @()
$modulosRoot = Join-Path $workspace "OnLine\AISServiceManager\Modulos"

foreach ($mod in $modulos) {
    Write-Host "`n--- $mod ---"
    $modFolder = Join-Path $modulosRoot $mod
    if (!(Test-Path $modFolder)) {
        Write-Host "ERROR: carpeta de módulo no encontrada: $modFolder"
        $fallos += $mod; continue
    }
    # El .sln del módulo puede llamarse distinto que la carpeta
    $modSln = Get-ChildItem $modFolder -Filter *.sln -File -Recurse -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if (-not $modSln) {
        Write-Host "ERROR: no hay .sln en $modFolder"
        $fallos += $mod; continue
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "instmod_$($mod -replace '[^\w]','_')"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }

    dotnet publish "$($modSln.FullName)" -c Release -o "$tmp"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: publish módulo $mod falló (exit $LASTEXITCODE)"
        $fallos += $mod
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        continue
    }

    # Copiar solo DLLs nuevas (no presentes en el host)
    $copiadas = 0
    Get-ChildItem $tmp -Filter *.dll -File | ForEach-Object {
        if (-not $hostDlls.ContainsKey($_.Name)) {
            Copy-Item $_.FullName $modDir -Force
            $copiadas++
        }
    }
    Write-Host "$mod -> $copiadas DLL copiadas a Modulos"
    if ($copiadas -eq 0) { Write-Host "AVISO: 0 DLL nuevas para $mod (¿ya en el host?)" }
    Remove-Item $tmp -Recurse -Force
}

Write-Host "`n== Resumen ServiceManager: host OK, módulos $($modulos.Count - $fallos.Count)/$($modulos.Count) =="
if ($fallos.Count -gt 0) { Write-Host "Fallos: $($fallos -join ', ')"; exit 1 }
Write-Host "OK — ServiceManager en $smDir (Modulos: $modDir)"
