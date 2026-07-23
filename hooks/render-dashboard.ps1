<#
.SYNOPSIS
    Genera el dashboard HTML de estadísticas del pipeline (executions/history.json) y lo abre en el
    navegador. Output JSON: success, path, opened, total.

.PARAMETER Workspace
    Ruta raíz del proyecto (carpeta trunk).
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"
$env:PYTHONUTF8 = "1"

$py   = Join-Path $PSScriptRoot "..\scripts\render-dashboard.py"
$html = Join-Path $Workspace "executions\dashboard.html"

$output   = python $py $Workspace 2>&1
$exitCode = $LASTEXITCODE

if ($exitCode -eq 0 -and (Test-Path $html)) {
    Start-Process $html
    @{
        success = $true
        path    = $html
        opened  = $true
    } | ConvertTo-Json
} else {
    @{
        success = $false
        error   = ($output -join "`n").Trim()
        path    = $html
    } | ConvertTo-Json
}
