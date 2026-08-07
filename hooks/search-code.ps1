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
. (Join-Path $hooksDir "lib-buscar.ps1")

# Obtener scope_dirs desde la solución
$scopeJson = & "$hooksDir\parse-sln.ps1" $SlnPath 2>&1
try {
    $scope = $scopeJson | ConvertFrom-Json
    $scopeDirs = if ($scope.scope_dirs) { $scope.scope_dirs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } }
                 else { @($Workspace) }
} catch {
    $scopeDirs = @($Workspace)
}

$encontradas = Invoke-RsBusqueda -Patrones @($Pattern) -Directorios @($scopeDirs) `
                                 -Globs @($Glob) -CarpetasExcluidas @('bin', 'obj')

$truncado    = ($encontradas.Count -gt $MaxResults)
$encontradas = @($encontradas | Select-Object -First $MaxResults)

# El contexto se lee DESPUÉS de acotar, y solo de los ficheros que han dado alguna coincidencia.
# Antes se abría cada fichero del scope con Select-String -Context para descubrir si tenía algo;
# ahora la búsqueda ya dice dónde mirar, así que se abren como mucho $MaxResults ficheros. La
# caché evita releer un fichero con varias coincidencias.
$cacheLineas = @{}
function Get-RsLineasFichero {
    param([string]$Ruta)
    if (-not $cacheLineas.ContainsKey($Ruta)) {
        $cacheLineas[$Ruta] = @(Get-Content -LiteralPath $Ruta -Encoding UTF8 -ErrorAction SilentlyContinue)
    }
    return $cacheLineas[$Ruta]
}

$results = New-Object System.Collections.ArrayList
foreach ($e in $encontradas) {
    $lineas = Get-RsLineasFichero $e.file
    $idx    = $e.line - 1
    $desde  = [Math]::Max(0, $idx - $Context)
    $hasta  = [Math]::Min($lineas.Count - 1, $idx + $Context)

    $antes   = if ($idx -gt $desde)   { ($lineas[$desde..($idx - 1)]) -join "`n" } else { "" }
    $despues = if ($hasta -gt $idx)   { ($lineas[($idx + 1)..$hasta]) -join "`n" } else { "" }

    [void]$results.Add([PSCustomObject]@{
        file   = $e.file
        line   = $e.line
        match  = $e.texto.Trim()
        before = $antes
        after  = $despues
    })
}

@{
    success       = $true
    pattern       = $Pattern
    glob          = $Glob
    scope_dirs    = $scopeDirs
    files_matched = @($results | Select-Object -ExpandProperty file -Unique).Count
    result_count  = $results.Count
    truncated     = $truncado
    results       = $results
} | ConvertTo-Json -Depth 4
