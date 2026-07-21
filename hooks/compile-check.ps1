<#
.SYNOPSIS
    Compila la solución con dotnet build y devuelve errores/warnings como JSON estructurado.
    Sustituye la validación heurística del LLM por salida real del compilador.

.PARAMETER SlnPath
    Ruta completa al archivo .sln

.PARAMETER NoRestore
    Si se especifica, omite restore de paquetes NuGet (más rápido, usar cuando restore ya se hizo)

.EXAMPLE
    .\compile-check.ps1 "C:\...\RSProcIN.sln"
    .\compile-check.ps1 "C:\...\RSProcIN.sln" -NoRestore
#>
param(
    [Parameter(Mandatory=$true)][string]$SlnPath,
    [switch]$NoRestore
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

if (-not (Test-Path $SlnPath)) {
    @{ success = $false; error = "Archivo no encontrado: $SlnPath" } | ConvertTo-Json
    exit 1
}

# Verificar dotnet
if (-not (Get-Command "dotnet" -ErrorAction SilentlyContinue)) {
    @{ success = $false; error = "dotnet CLI no encontrado en PATH" } | ConvertTo-Json
    exit 1
}

$restoreFlag = if ($NoRestore) { "--no-restore" } else { "" }
$cmd = "dotnet build `"$SlnPath`" $restoreFlag -v quiet --nologo 2>&1"
$raw = Invoke-Expression $cmd
$exitCode = $LASTEXITCODE

# Parsear líneas de error/warning del compilador
# Formato: <archivo>(<linea>,<col>): <severity> <CS####>: <mensaje> [<proyecto>]
$diagnostics = @()
foreach ($line in $raw) {
    if ($line -match '^(.+)\((\d+),(\d+)\):\s+(error|warning)\s+(CS\w+):\s+(.+?)(\s+\[.+\])?$') {
        $diagnostics += @{
            file     = $Matches[1].Trim()
            line     = [int]$Matches[2]
            col      = [int]$Matches[3]
            severity = $Matches[4]
            code     = $Matches[5]
            message  = $Matches[6].Trim()
        }
    }
}

$errors   = @($diagnostics | Where-Object { $_.severity -eq "error" })
$warnings = @($diagnostics | Where-Object { $_.severity -eq "warning" })

@{
    success       = ($exitCode -eq 0)
    exit_code     = $exitCode
    error_count   = $errors.Count
    warning_count = $warnings.Count
    errors        = $errors
    warnings      = $warnings
    raw_lines     = if ($exitCode -ne 0 -and $diagnostics.Count -eq 0) { @($raw | Where-Object { $_ -match '\S' }) } else { @() }
} | ConvertTo-Json -Depth 4
