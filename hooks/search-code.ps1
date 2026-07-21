<#
.SYNOPSIS
    Busca patrón regex en archivos del scope de una solución.
    Reemplaza múltiples llamadas Grep garantizando búsqueda dentro de scope_dirs.

.PARAMETER Workspace
    Ruta raíz del proyecto.

.PARAMETER SlnPath
    Ruta completa al .sln. Usado para inferir scope_dirs.

.PARAMETER Pattern
    Expresión regular a buscar.

.PARAMETER Glob
    Filtro de archivos (default: *.cs).

.PARAMETER Context
    Líneas de contexto antes y después del match (default: 2).

.PARAMETER MaxResults
    Máximo de resultados totales (default: 50).
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$SlnPath,
    [Parameter(Mandatory=$true)][string]$Pattern,
    [string]$Glob       = "*.cs",
    [int]   $Context    = 2,
    [int]   $MaxResults = 50
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"
$hooksDir = Split-Path $PSCommandPath -Parent

# Obtener scope_dirs desde la solución
$scopeJson = & "$hooksDir\parse-sln.ps1" $SlnPath 2>&1
try {
    $scope = $scopeJson | ConvertFrom-Json
    $scopeDirs = if ($scope.scope_dirs) { $scope.scope_dirs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } }
                 else { @($Workspace) }
} catch {
    $scopeDirs = @($Workspace)
}

$results   = @()
$fileCount = 0

foreach ($dir in $scopeDirs) {
    if (-not (Test-Path $dir)) { continue }
    $files = Get-ChildItem -Path $dir -Filter $Glob -Recurse -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        $matches = Select-String -Path $file.FullName -Pattern $Pattern -Context $Context -ErrorAction SilentlyContinue
        if ($matches) { $fileCount++ }
        foreach ($m in $matches) {
            if ($results.Count -ge $MaxResults) { break }
            $results += [PSCustomObject]@{
                file    = $file.FullName
                line    = $m.LineNumber
                match   = $m.Line.Trim()
                before  = if ($m.Context.PreContext)  { $m.Context.PreContext  -join "`n" } else { "" }
                after   = if ($m.Context.PostContext) { $m.Context.PostContext -join "`n" } else { "" }
            }
        }
        if ($results.Count -ge $MaxResults) { break }
    }
    if ($results.Count -ge $MaxResults) { break }
}

@{
    success      = $true
    pattern      = $Pattern
    glob         = $Glob
    scope_dirs   = $scopeDirs
    files_matched = $fileCount
    result_count = $results.Count
    truncated    = ($results.Count -ge $MaxResults)
    results      = $results
} | ConvertTo-Json -Depth 4
