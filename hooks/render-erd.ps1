<#
.SYNOPSIS
    Genera el ERD HTML del modelo BD y lo abre en el navegador.
    Output JSON: success, path, opened, table_count.

.PARAMETER Workspace
    Ruta raíz del proyecto (carpeta trunk).

.PARAMETER Proyecto
    Nombre del proyecto (carpeta anterior a trunk). Inferido del workspace si se omite.
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$Proyecto = ""
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"
$env:PYTHONUTF8 = "1"

if (-not $Proyecto) {
    $Proyecto = Split-Path (Split-Path $Workspace -Parent) -Leaf
}

$py   = Join-Path $PSScriptRoot "..\scripts\render-erd.py"
$html = Join-Path $Workspace "BD\$Proyecto-erd.html"

$output = python $py $Workspace $Proyecto 2>&1
$exitCode = $LASTEXITCODE

if ($exitCode -eq 0 -and (Test-Path $html)) {
    Start-Process $html

    # Contar tablas en el modelo para info
    $modelPath = Join-Path $Workspace "BD\$Proyecto-model.json"
    $tableCount = 0
    if (Test-Path $modelPath) {
        try {
            $model = Get-Content $modelPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $tableCount = ($model.tables | Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue).Count
        } catch { }
    }

    @{
        success     = $true
        path        = $html
        opened      = $true
        proyecto    = $Proyecto
        table_count = $tableCount
    } | ConvertTo-Json
} else {
    @{
        success  = $false
        error    = ($output -join "`n").Trim()
        proyecto = $Proyecto
        path     = $html
    } | ConvertTo-Json
}
