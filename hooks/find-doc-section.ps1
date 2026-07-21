<#
.SYNOPSIS
    Busca en la documentación funcional y técnica del workspace secciones relacionadas con un keyword.
    Devuelve archivo, heading más cercano, línea y fragmento de contexto.

.PARAMETER Workspace
    Ruta raíz del proyecto.

.PARAMETER Keyword
    Término a buscar (nombre de proceso, método, pantalla, validación, tabla).

.EXAMPLE
    .\find-doc-section.ps1 "C:\SVN\RS\<Proyecto>\trunk" "ValidarFecha"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Keyword
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:PYTHONUTF8 = "1"

$docsBase    = Join-Path $Workspace "docs\agentic_manual\funcional"
$docsTecnica = Join-Path $Workspace "docs\agentic_manual\tecnica"
$docsRoot    = Join-Path $Workspace "docs\agentic_manual"
if (-not (Test-Path $docsRoot)) {
    @{ found = $false; error = "Directorio de docs no encontrado: $docsRoot" } | ConvertTo-Json
    exit 0
}

# Buscar en los .md funcionales (recursivo) + técnicos (recursivo, manual de convenciones)
# + los docs sueltos de la raíz agentic_manual (p.ej. AIS-ARQ-DT-Gestor de servicios.md,
# que no cuelga de funcional\ ni tecnica\).
$mdFiles = @()
if (Test-Path $docsBase) {
    $mdFiles += Get-ChildItem $docsBase -Recurse -Filter "*.md" -ErrorAction SilentlyContinue
}
if (Test-Path $docsTecnica) {
    $mdFiles += Get-ChildItem $docsTecnica -Recurse -Filter "*.md" -ErrorAction SilentlyContinue
}
$mdFiles += Get-ChildItem $docsRoot -Filter "*.md" -File -ErrorAction SilentlyContinue
if (-not $mdFiles -or $mdFiles.Count -eq 0) {
    @{ found = $false; error = "No se encontraron archivos .md en $docsRoot" } | ConvertTo-Json
    exit 0
}

$docMatches = @()

foreach ($file in $mdFiles) {
    $lines   = Get-Content $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $lines) { continue }

    $currentHeading = ""
    $lineNum = 0

    foreach ($line in $lines) {
        $lineNum++

        # Rastrear heading activo
        if ($line -match '^#{1,4}\s+(.+)$') {
            $currentHeading = $Matches[1].Trim()
        }

        # Buscar keyword (case-insensitive)
        if ($line -match [regex]::Escape($Keyword)) {
            $relPath = $file.FullName.Replace($Workspace, "").TrimStart("\").TrimStart("/")
            $snippet = $line.Trim() -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
            if ($snippet.Length -gt 120) { $snippet = $snippet.Substring(0, 120) + "..." }

            $docMatches += [PSCustomObject]@{
                file    = $relPath
                section = $currentHeading
                line    = $lineNum
                snippet = $snippet
            }
        }
    }
}

if ($docMatches.Count -eq 0) {
    @{
        found      = $false
        keyword    = $Keyword
        docs_base  = $docsBase
        message    = "Sin coincidencias — puede requerirse nueva sección en el índice funcional o técnico"
    } | ConvertTo-Json
} else {
    @{
        found      = $true
        keyword    = $Keyword
        match_count = $docMatches.Count
        matches    = $docMatches
    } | ConvertTo-Json -Depth 4
}
