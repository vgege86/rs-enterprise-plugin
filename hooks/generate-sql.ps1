<#
.SYNOPSIS
    Genera DDL SQL desde el modelo BD y escribe a C:\AIS\<proyecto-lowercase>\scripts\<proyecto>-ddl-<motor>.sql.
    Output JSON: success, path, motor, message.

.PARAMETER Workspace
    Ruta raíz del proyecto.

.PARAMETER Proyecto
    Nombre del proyecto. Inferido del workspace si se omite.

.PARAMETER Motor
    ORACLE o SQLSERVER. Usa el del modelo JSON si se omite.
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$Proyecto = "",
    [string]$Motor = ""
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"
$env:PYTHONUTF8 = "1"

if (-not $Proyecto) {
    $Proyecto = Split-Path (Split-Path $Workspace -Parent) -Leaf
}

$py     = Join-Path $PSScriptRoot "..\scripts\generate-sql.py"
$pyArgs = @($Workspace, $Proyecto)
if ($Motor) { $pyArgs += $Motor }

$pyOutput = python $py @pyArgs 2>&1
$exitCode = $LASTEXITCODE

# Detectar motor efectivo del modelo si no se pasó
if (-not $Motor) {
    $modelPath = Join-Path $Workspace "BD\$Proyecto-model.json"
    if (Test-Path $modelPath) {
        try {
            $model  = Get-Content $modelPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $Motor  = $model.engine
        } catch { $Motor = "UNKNOWN" }
    }
}

$sqlPath = "C:\AIS\$($Proyecto.ToLower())\scripts\$Proyecto-ddl-$($Motor.ToLower()).sql"

if ($exitCode -eq 0 -and (Test-Path $sqlPath)) {
    $lineCount = (Get-Content $sqlPath).Count
    @{
        success    = $true
        path       = $sqlPath
        motor      = $Motor
        line_count = $lineCount
        proyecto   = $Proyecto
    } | ConvertTo-Json
} else {
    @{
        success  = $false
        error    = ($pyOutput -join "`n").Trim()
        motor    = $Motor
        proyecto = $Proyecto
    } | ConvertTo-Json
}
