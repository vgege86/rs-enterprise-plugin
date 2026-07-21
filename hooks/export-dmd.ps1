<#
.SYNOPSIS
    Exporta el modelo BD a formato Oracle Data Modeler (.dmd).
    Output JSON: success, path, table_count.

.PARAMETER Workspace
    Ruta raíz del proyecto.

.PARAMETER Proyecto
    Nombre del proyecto. Inferido del workspace si se omite.
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

$py       = Join-Path $PSScriptRoot "..\scripts\export-dmd.py"
$pyOutput = python $py $Workspace $Proyecto 2>&1
$exitCode = $LASTEXITCODE

$dmdPath = Join-Path $Workspace "BD\$Proyecto.dmd"

if ($exitCode -eq 0 -and (Test-Path $dmdPath)) {
    $tableCount = 0
    $modelPath  = Join-Path $Workspace "BD\$Proyecto-model.json"
    if (Test-Path $modelPath) {
        try {
            $model = Get-Content $modelPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $tableCount = if ($model.tables -is [System.Array]) { $model.tables.Count }
                          else { ($model.tables | Get-Member -MemberType NoteProperty).Count }
        } catch { }
    }
    @{ success = $true; path = $dmdPath; table_count = $tableCount; proyecto = $Proyecto } | ConvertTo-Json
} else {
    @{ success = $false; error = ($pyOutput -join "`n").Trim(); proyecto = $Proyecto } | ConvertTo-Json
}
