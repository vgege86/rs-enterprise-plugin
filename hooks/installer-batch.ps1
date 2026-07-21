<#
.SYNOPSIS
    Instalador — compila en Release los procesos batch ACTIVOS del cliente y copia sus
    ejecutables a <destino>\EXES.

    Lista de procesos activos = docs\<proyecto>-instalador.json → campo "batch" (array de
    nombres de .sln sin extensión, bajo Batch\Soluciones\).

.PARAMETER workspace  Ruta trunk del proyecto (ej. C:\SVN\RS\<Proyecto>\trunk)
.PARAMETER destino    Carpeta Instalador (ej. C:\AIS\<Proyecto>\Instalador)
#>
param(
    [Parameter(Mandatory=$true)][string]$workspace,
    [Parameter(Mandatory=$true)][string]$destino
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# Proyecto = carpeta anterior a trunk (o la propia si no es trunk)
$proyecto = if ((Split-Path $workspace -Leaf) -eq 'trunk') { Split-Path (Split-Path $workspace -Parent) -Leaf } else { Split-Path $workspace -Leaf }
$jsonPath = Join-Path $workspace "docs\$proyecto-instalador.json"

if (!(Test-Path $jsonPath)) {
    Write-Host "ERROR: Config no encontrada: $jsonPath"
    exit 1
}
$cfg = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$batch = @($cfg.batch)
if ($batch.Count -eq 0) {
    Write-Host "AVISO: no hay procesos batch activos en el JSON — nada que compilar."
    exit 0
}

$exesDir = Join-Path $destino "EXES"
New-Item -ItemType Directory -Path $exesDir -Force | Out-Null

Write-Host "== Instalador BATCH — $($batch.Count) procesos =="
$fallos = @()

foreach ($sln in $batch) {
    $slnPath = Join-Path $workspace "Batch\Soluciones\$sln.sln"
    Write-Host "`n--- $sln ---"
    if (!(Test-Path $slnPath)) {
        Write-Host "ERROR: .sln no encontrada: $slnPath"
        $fallos += $sln; continue
    }

    dotnet build "$slnPath" -c Release
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: build Release falló para $sln (exit $LASTEXITCODE)"
        $fallos += $sln; continue
    }

    # Localizar bin\Release (mismas rutas candidatas que batch-build.ps1)
    $candidatos = @(
        "$workspace\Batch\$sln\bin\Release",
        "$workspace\Batch\Soluciones\$sln\bin\Release",
        "$workspace\Batch\Soluciones\$sln\$sln\bin\Release"
    )
    $exePath = $candidatos | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exePath) {
        $found = Get-ChildItem "$workspace\Batch" -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue |
                 Where-Object { $_.DirectoryName -match "bin.Release" -and $_.BaseName -eq $sln } |
                 Select-Object -First 1
        if ($found) { $exePath = $found.DirectoryName }
    }
    if (-not $exePath) {
        Write-Host "ERROR: no se encontró bin\Release para $sln"
        $fallos += $sln; continue
    }

    Write-Host "Binarios: $exePath  ->  $exesDir"
    Copy-Item "$exePath\*" $exesDir -Recurse -Force
}

Write-Host "`n== Resumen BATCH: $($batch.Count - $fallos.Count)/$($batch.Count) OK =="
if ($fallos.Count -gt 0) {
    Write-Host "Fallos: $($fallos -join ', ')"
    exit 1
}
Write-Host "OK — EXES en $exesDir"
