<#
.SYNOPSIS
    Renderiza la guía de usuario del plugin (README.md) a un HTML autónomo y lo abre en el
    navegador. Output JSON: success, path, opened.

.DESCRIPTION
    A diferencia de render-dashboard.ps1, la fuente NO es el workspace sino el README.md del propio
    plugin (resuelto vía $PSScriptRoot\..\README.md). El HTML de salida se escribe en
    <Workspace>\executions\rs-help.html para que el usuario tenga una copia local.

.PARAMETER Workspace
    Ruta raíz del proyecto (carpeta trunk) — solo se usa como destino del HTML.
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"
$env:PYTHONUTF8 = "1"

$py     = Join-Path $PSScriptRoot "..\scripts\render-help.py"
$readme = Join-Path $PSScriptRoot "..\README.md"
$html   = Join-Path $Workspace "executions\rs-help.html"

$output   = python $py $readme $html 2>&1
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
