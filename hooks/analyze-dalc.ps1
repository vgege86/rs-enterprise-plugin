<#
.SYNOPSIS
    Analiza ficheros DALC (Online y Batch) para inferir relaciones entre tablas.
    Actualiza el modelo JSON con las relaciones encontradas.

.PARAMETER Workspace
    Ruta raiz del proyecto

.PARAMETER Proyecto
    Nombre del proyecto AIS

.PARAMETER SolutionPath
    Opcional: ruta al .sln para limitar scope. Si no se pasa, busca en patrones estandar.
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Proyecto,
    [string]$SolutionPath = ""
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Delegar al script Python que hace el parsing real
$pyScript = Join-Path $scriptDir "..\scripts\analyze-dalc.py"
$modelPath = Join-Path $Workspace "BD\$Proyecto-model.json"

if (-not (Test-Path $modelPath)) {
    Write-Error "Modelo no encontrado: $modelPath — ejecutar sync-from-db.ps1 primero"
    exit 1
}

$pyArgs = @($Workspace, $Proyecto, $modelPath)
if ($SolutionPath) { $pyArgs += $SolutionPath }

$env:PYTHONUTF8 = "1"
$pyOutput = python $pyScript @pyArgs 2>&1
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    @{ success = $false; error = ($pyOutput -join "`n").Trim(); model_path = $modelPath } | ConvertTo-Json
    exit 1
}

# Intentar parsear output Python como JSON; si no, extraer info de texto plano
$parsed = $null
try { $parsed = ($pyOutput -join "`n").Trim() | ConvertFrom-Json } catch { }

if ($parsed -and $parsed.relations_found -ne $null) {
    $parsed | Add-Member -Force -NotePropertyName 'success' -NotePropertyValue $true
    $parsed | Add-Member -Force -NotePropertyName 'model_path' -NotePropertyValue $modelPath
    $parsed | ConvertTo-Json
} else {
    @{
        success    = $true
        model_path = $modelPath
        output     = ($pyOutput -join "`n").Trim()
    } | ConvertTo-Json
}
