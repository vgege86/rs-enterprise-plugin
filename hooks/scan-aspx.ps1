<#
.SYNOPSIS
    Escanea archivos .aspx en busca de controles AIS (etiquetas y textos literales)
    y devuelve JSON con los textos a registrar en RIDIOMA/RCONTROLES.
    Elimina que el LLM lea y parsee .aspx manualmente.

.PARAMETER SlnPath
    Ruta completa al archivo .sln (para localizar los .aspx en scope)

.PARAMETER ScopeDirs
    Directorios separados por punto y coma (alternativa a SlnPath)

.EXAMPLE
    .\scan-aspx.ps1 "C:\...\AgendaWeb.sln"
#>
param(
    [string]$SlnPath,
    [string]$ScopeDirs
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# Resolver directorios
$dirs = @()
if ($ScopeDirs) {
    $dirs = $ScopeDirs -split ";" | Where-Object { $_ -ne "" } | ForEach-Object { $_.Trim() }
} elseif ($SlnPath) {
    if (-not (Test-Path $SlnPath)) {
        @{ error = "Solución no encontrada: $SlnPath" } | ConvertTo-Json; exit 1
    }
    $slnDir  = Split-Path $SlnPath -Parent
    $content = Get-Content $SlnPath -Encoding UTF8
    foreach ($line in $content) {
        if ($line -match '"([^"]+\.csproj)"') {
            $rel = $Matches[1].Replace('/', '\')
            $dirs += Split-Path (Join-Path $slnDir $rel) -Parent
        }
    }
} else {
    @{ error = "Proporcionar SlnPath o ScopeDirs" } | ConvertTo-Json; exit 1
}

# Patrones de controles AIS en .aspx
# rs:Label, rs:Button, rs:TextBox → texto en Text="" o propiedad Text
# También literales en runat=server labels
$controls  = @()
$processed = @{}

foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) { continue }
    $aspxFiles = Get-ChildItem $dir -Recurse -Filter "*.aspx" -ErrorAction SilentlyContinue
    foreach ($file in $aspxFiles) {
        if ($processed[$file.FullName]) { continue }
        $processed[$file.FullName] = $true
        $lines = Get-Content $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            # Detectar controles rs: con Text=""
            if ($line -match '<rs:\w+[^>]+\bID="([^"]+)"[^>]*\bText="([^"]+)"') {
                $controls += @{
                    file    = $file.FullName
                    line    = $i + 1
                    id      = $Matches[1]
                    text    = $Matches[2]
                    type    = "rs-control"
                }
            } elseif ($line -match '\bText="([^"]+)"[^>]*\bID="([^"]+)"') {
                $controls += @{
                    file    = $file.FullName
                    line    = $i + 1
                    id      = $Matches[2]
                    text    = $Matches[1]
                    type    = "rs-control"
                }
            }
            # asp:Label / asp:Button con Text
            if ($line -match '<asp:\w+[^>]+\bID="([^"]+)"[^>]*\bText="([^"]+)"') {
                $controls += @{
                    file    = $file.FullName
                    line    = $i + 1
                    id      = $Matches[1]
                    text    = $Matches[2]
                    type    = "asp-control"
                }
            }
        }
    }
}

# Deduplicar por ID+texto
$seen     = @{}
$unique   = @()
foreach ($c in $controls) {
    $key = "$($c.id)|$($c.text)"
    if (-not $seen[$key]) { $seen[$key] = $true; $unique += $c }
}

@{
    found    = $unique.Count
    controls = $unique
} | ConvertTo-Json -Depth 4
