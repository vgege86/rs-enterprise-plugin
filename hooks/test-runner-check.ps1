<#
.SYNOPSIS
    Ejecuta dotnet test sobre la solución y devuelve resultados como JSON estructurado.
    Sustituye la simulación mental del LLM por ejecución real de tests.

.PARAMETER SlnPath
    Ruta completa al archivo .sln

.PARAMETER NoBuild
    Si se especifica, omite build previo (usar cuando compile-check ya pasó)

.EXAMPLE
    .\test-runner-check.ps1 "C:\...\RSProcIN.sln" -NoBuild
#>
param(
    [Parameter(Mandatory=$true)][string]$SlnPath,
    [switch]$NoBuild
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

if (-not (Test-Path $SlnPath)) {
    @{ success = $false; error = "Archivo no encontrado: $SlnPath" } | ConvertTo-Json
    exit 1
}

if (-not (Get-Command "dotnet" -ErrorAction SilentlyContinue)) {
    @{ success = $false; error = "dotnet CLI no encontrado en PATH" } | ConvertTo-Json
    exit 1
}

# Detectar proyectos de test en la solución
$slnDir = Split-Path $SlnPath -Parent
$slnContent = Get-Content $SlnPath -Encoding UTF8
$testProjects = @()
foreach ($line in $slnContent) {
    if ($line -match '"([^"]+\.csproj)"') {
        $csprojRel = $Matches[1].Replace('/', '\')
        $csprojAbs = Join-Path $slnDir $csprojRel
        if (Test-Path $csprojAbs) {
            $csprojContent = Get-Content $csprojAbs -Encoding UTF8 -Raw
            if ($csprojContent -match 'Microsoft\.NET\.Test\.Sdk|xunit|NUnit|MSTest') {
                $testProjects += $csprojAbs
            }
        }
    }
}

if ($testProjects.Count -eq 0) {
    @{ has_test_project = $false; reason = "No se encontraron proyectos de test en la solución" } | ConvertTo-Json
    exit 0
}

$noBuildFlag = if ($NoBuild) { "--no-build" } else { "" }
$cmd = "dotnet test `"$SlnPath`" $noBuildFlag --nologo -v normal 2>&1"
$raw = Invoke-Expression $cmd
$exitCode = $LASTEXITCODE

# Parsear resumen
$passed  = 0; $failed = 0; $skipped = 0
$failures = @()
$currentFail = $null

foreach ($line in $raw) {
    # Línea de resumen: "Passed: 10, Failed: 2, Skipped: 1"
    if ($line -match 'Passed:\s*(\d+)') { $passed  = [int]$Matches[1] }
    if ($line -match 'Failed:\s*(\d+)') { $failed  = [int]$Matches[1] }
    if ($line -match 'Skipped:\s*(\d+)') { $skipped = [int]$Matches[1] }

    # Inicio de test fallido: "  Failed  NombreTest [N ms]"
    if ($line -match '^\s+Failed\s+(.+?)\s+\[') {
        if ($currentFail) { $failures += $currentFail }
        $currentFail = @{ test = $Matches[1].Trim(); message = ""; stack = "" }
    }
    # Mensaje de error dentro del test
    elseif ($currentFail -and $line -match '^\s+Error Message:\s+(.+)') {
        $currentFail.message = $Matches[1].Trim()
    }
    elseif ($currentFail -and $line -match '^\s+Stack Trace:\s+(.+)') {
        $currentFail.stack = $Matches[1].Trim()
    }
}
if ($currentFail) { $failures += $currentFail }

@{
    success          = ($exitCode -eq 0)
    has_test_project = $true
    exit_code        = $exitCode
    test_projects    = $testProjects.Count
    passed           = $passed
    failed         = $failed
    skipped        = $skipped
    failures       = $failures
    raw_summary    = @($raw | Where-Object { $_ -match '(Passed|Failed|Skipped|Test run)' })
} | ConvertTo-Json -Depth 4
