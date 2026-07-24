<#
.SYNOPSIS
    Compila una solución de tipo Servicio (servicio Windows .NET Framework + su instalador .vdproj).
    Los Setup Projects .vdproj NO los soporta MSBuild → se compilan con devenv. Como construir el
    instalador ya exige devenv, este hook usa devenv para el build completo (código + instalador) y
    cae a MSBuild solo-código si no hay devenv.
    ⛔ NO copia a AIS: el artefacto instalador (.msi/setup.exe) es el entregable que se lleva al
    cliente (allí se instala como servicio de Windows).

.PARAMETER slnPath
    Ruta COMPLETA a la .sln del servicio (no está bajo Batch\Soluciones\ ni OnLine\ — layout libre
    bajo <Proyecto>\trunk\, ej. RecBatch2014\RecBatchSvc\RecBatchSvc.sln).
.PARAMETER workspace
    Trunk del proyecto (informativo).
#>
param(
    [Parameter(Mandatory=$true)][string]$slnPath,
    [string]$workspace
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

if (!(Test-Path $slnPath)) {
    Write-Host "ERROR: solución no encontrada: $slnPath"
    exit 1
}
$slnDir = Split-Path $slnPath -Parent
Write-Host "Building Servicio solution: $slnPath"

# --- Localizar vswhere / msbuild / devenv ---
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (!(Test-Path $vswhere)) { Write-Host "ERROR: vswhere not found at $vswhere"; exit 1 }

$msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
if (!$msbuild -or !(Test-Path $msbuild)) { Write-Host "ERROR: msbuild not found via vswhere"; exit 1 }

$devenv = & $vswhere -latest -property productPath | Select-Object -First 1   # ...\Common7\IDE\devenv.exe

# --- Localizar el proyecto instalador (.vdproj) referenciado en la .sln ---
$vdproj = $null
foreach ($line in (Get-Content $slnPath -Encoding UTF8)) {
    if ($line -match 'Project\([^)]+\)\s*=\s*"[^"]+",\s*"([^"]+\.vdproj)"') {
        $vdproj = [System.IO.Path]::GetFullPath((Join-Path $slnDir ($Matches[1].Trim().Replace('/', '\'))))
        break
    }
}

# --- Build ---
$installerBuilt = $false
if ($devenv -and (Test-Path $devenv)) {
    Write-Host "Using devenv: $devenv"
    Write-Host "== devenv /Build Release (código + instalador) =="
    & "$devenv" "$slnPath" /Build "Release"
    $exit = $LASTEXITCODE
    if ($exit -eq 0) {
        $installerBuilt = [bool]$vdproj
    } else {
        Write-Host "AVISO: devenv /Build falló (exit $exit). ¿Falta la extensión 'Microsoft Visual Studio Installer Projects'?"
        Write-Host "Reintentando solo el código con MSBuild (el instalador habrá que generarlo a mano en Visual Studio)..."
        & "$msbuild" "$slnPath" /p:Configuration=Release /nologo /verbosity:minimal
        if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: MSBuild también falló (exit $LASTEXITCODE)"; exit $LASTEXITCODE }
    }
} else {
    Write-Host "AVISO: devenv no encontrado — MSBuild no compila .vdproj. Solo se compila el código."
    Write-Host "Using msbuild: $msbuild"
    & "$msbuild" "$slnPath" /p:Configuration=Release /nologo /verbosity:minimal
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: MSBuild falló (exit $LASTEXITCODE)"; exit $LASTEXITCODE }
}

# --- Evidencia: EXE del servicio + artefacto instalador ---
$exe = Get-ChildItem $slnDir -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue |
       Where-Object { $_.DirectoryName -match "bin.Release" } | Select-Object -First 1
if ($exe) { Write-Host "Servicio EXE: $($exe.FullName)" }
else       { Write-Host "AVISO: no se encontró EXE en bin\Release bajo $slnDir" }

if ($vdproj) {
    $insDir = Join-Path (Split-Path $vdproj -Parent) "Release"
    $art = Get-ChildItem $insDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in ".msi", ".exe" }
    if ($art)                { Write-Host "Instalador: $(($art | ForEach-Object FullName) -join '; ')" }
    elseif ($installerBuilt) { Write-Host "AVISO: devenv OK pero no se encontró .msi/setup.exe en $insDir" }
    else                     { Write-Host "Instalador NO generado — genera el .vdproj a mano en Visual Studio (menú Build → Build <Instalador>)." }
}

Write-Host "OK — build Servicio finalizado."
