<#
.SYNOPSIS
    Busca un símbolo C# (clase, método, propiedad, interfaz) dentro de los directorios de scope.
    Devuelve lista de coincidencias con archivo y número de línea.
    Elimina que el LLM haga múltiples Glob+Grep para localizar código.

.PARAMETER Symbol
    Nombre del símbolo a buscar (clase, método, propiedad, interfaz, enum)

.PARAMETER ScopeDirs
    Directorios de búsqueda, separados por punto y coma.
    Usar output de parse-sln.ps1 (campo scope_dirs unido con ";")

.PARAMETER Type
    Tipo de símbolo: class|method|property|interface|enum|any (default: any)

.EXAMPLE
    .\find-symbol.ps1 "ProcesarCliente" "C:\...\RSProcIN;C:\...\RSProcIN.DAL"
    .\find-symbol.ps1 "RCLIENTES" "C:\...\RSProcIN" -Type class
#>
param(
    [Parameter(Mandatory=$true)][string]$Symbol,
    [Parameter(Mandatory=$true)][string]$ScopeDirs,
    [string]$Type = "any"
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$dirs = $ScopeDirs -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

# Patrones de búsqueda según tipo
$patterns = switch ($Type.ToLower()) {
    "class"     { @("class\s+$Symbol[\s:{<]", "class\s+$Symbol$") }
    "method"    { @("\s+$Symbol\s*\(", "void\s+$Symbol\s*\(", "public\s+\w+\s+$Symbol\s*\(") }
    "property"  { @("public\s+\w+\s+$Symbol\s*[{;]") }
    "interface" { @("interface\s+$Symbol[\s:{<]", "interface\s+$Symbol$") }
    "enum"      { @("enum\s+$Symbol[\s{]") }
    default     { @("class\s+$Symbol[\s:{<]", "interface\s+$Symbol[\s:{<]", "enum\s+$Symbol[\s{]",
                    "\s+$Symbol\s*\(", "public\s+\w+\s+$Symbol\s*[{;(]", "$Symbol\s*=") }
}

$results = @()
foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) { continue }
    $csFiles = Get-ChildItem $dir -Recurse -Filter "*.cs" -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }
    foreach ($file in $csFiles) {
        $lines = Get-Content $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt $lines.Count; $i++) {
            foreach ($pat in $patterns) {
                if ($lines[$i] -match $pat) {
                    $results += @{
                        file    = $file.FullName
                        line    = $i + 1
                        content = $lines[$i].Trim()
                        match   = $pat
                    }
                    break
                }
            }
        }
    }
}

# Deduplicar por archivo+línea
$results = $results | Sort-Object { "$($_.file):$($_.line)" } -Unique

@{
    symbol  = $Symbol
    type    = $Type
    found   = $results.Count
    matches = $results
} | ConvertTo-Json -Depth 4
