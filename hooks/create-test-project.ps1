<#
.SYNOPSIS
    Crea un proyecto de test xUnit/MSTest/NUnit y lo añade a la solución.
    Usado por el agente crear-tests cuando no existe proyecto de test en la .sln.

.PARAMETER SlnPath
    Ruta completa al archivo .sln

.PARAMETER Framework
    Framework de test: xunit (default), mstest, nunit

.PARAMETER ProjectName
    Nombre del proyecto de test. Por defecto: <SolutionName>.Tests

.EXAMPLE
    .\create-test-project.ps1 "C:\...\RSProcIN.sln"
    .\create-test-project.ps1 "C:\...\RSProcIN.sln" -Framework mstest -ProjectName "RSProcIN.UnitTests"
#>
param(
    [Parameter(Mandatory=$true)][string]$SlnPath,
    [ValidateSet("xunit","mstest","nunit")][string]$Framework = "xunit",
    [string]$ProjectName = ""
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

if (-not (Test-Path $SlnPath)) {
    @{ success = $false; error = "Solución no encontrada: $SlnPath" } | ConvertTo-Json; exit 1
}
if (-not (Get-Command "dotnet" -ErrorAction SilentlyContinue)) {
    @{ success = $false; error = "dotnet CLI no disponible" } | ConvertTo-Json; exit 1
}

$slnFile = Get-Item $SlnPath
$slnDir  = $slnFile.DirectoryName
$slnName = $slnFile.BaseName

if (-not $ProjectName) { $ProjectName = "$slnName.Tests" }

# Convención: .sln vive en <Batch|OnLine>\Soluciones\ → proyecto de test
# va en <Batch|OnLine>\Tests\, no junto a la .sln (ver crear-tests.md paso 2)
$tipoDir  = Split-Path $slnDir -Parent
$testsRoot = Join-Path $tipoDir "Tests"
$testDir = Join-Path $testsRoot $ProjectName

# Verificar que no existe ya
if (Test-Path $testDir) {
    @{ success = $false; error = "Directorio ya existe: $testDir" } | ConvertTo-Json; exit 1
}

# Crear proyecto
$createOut = dotnet new $Framework -n "$ProjectName" -o "$testDir" --no-restore 2>&1
if ($LASTEXITCODE -ne 0) {
    @{ success = $false; error = ($createOut -join "`n") } | ConvertTo-Json; exit 1
}

# Añadir a la solución
$csprojPath = Join-Path $testDir "$ProjectName.csproj"
$addOut = dotnet sln "$SlnPath" add "$csprojPath" 2>&1
if ($LASTEXITCODE -ne 0) {
    @{ success = $false; error = ($addOut -join "`n") } | ConvertTo-Json; exit 1
}

@{
    success      = $true
    project_name = $ProjectName
    project_dir  = $testDir
    csproj_path  = $csprojPath
    framework    = $Framework
    sln_path     = $SlnPath
} | ConvertTo-Json
