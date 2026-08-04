<#
.SYNOPSIS
    Convierte ficheros Markdown del agentic_manual a un documento Word (.docx) aplicando una
    plantilla .dotx del workspace. Output JSON: success, path, pages, tables, sources, template,
    warnings.

.DESCRIPTION
    Requiere Microsoft Word instalado (automatización COM). El plugin NO lleva pandoc ni
    python-docx: sin Word no hay conversión posible y la tool devuelve success=false.

    Cada fichero .md se vuelca como un capítulo: su encabezado de nivel 1 pasa a Título 1 y el
    resto de niveles baja en consecuencia. Los estilos se resuelven por ID built-in de Word
    (wdStyleHeading1 = -2 ...), no por nombre local, para que funcione con Word en cualquier idioma.

    Sobre la plantilla se hace:
      - portada: el párrafo con estilo Title de la PRIMERA sección recibe -Title, el Subtitle -Objeto
      - historial de cambios: si se pasa -Autor, se rellena la fila 2 de la primera tabla
      - contenido de ejemplo de la última sección: se elimina
      - índice: si la plantilla ya trae un campo TOC se ACTUALIZA; nunca se inserta otro

.PARAMETER Workspace
    Ruta raíz del proyecto (carpeta trunk). Las rutas relativas se resuelven contra ella.

.PARAMETER Sources
    Ficheros .md y/o carpetas, separados por ';'. Una carpeta aporta sus *.md ordenados por nombre.

.PARAMETER Template
    Plantilla .dotx. Si se omite, se autodetecta el primer *.dotx de <Workspace>\docs.

.PARAMETER Output
    Ruta del .docx a generar. Si se omite: <Workspace>\docs\<Title>.docx.

.PARAMETER Title
    Título del documento (portada). Si se omite, el nombre base del fichero de salida.

.PARAMETER Objeto
    Subtítulo / objeto del documento (portada).

.PARAMETER Autor
    Autor para el historial de cambios. Si se omite, la tabla de historial se deja intacta.

.PARAMETER Version
    Versión para el historial de cambios. Default "1.0".

.PARAMETER StripMarks
    Retira las marcas de procedencia de los runbooks: U+2705 (verificado en código) y U+1F464
    (aportado por operación). En celda de tabla que quede vacía escribe "Código" / "Operación"
    en su lugar, para no dejar huecos.

.PARAMETER Open
    Abre el .docx generado al terminar.

.NOTES
    Limitación conocida: el formateo inline (**negrita**, `código`) se aplica con Find de comodines
    sobre TODO el documento, incluidos los bloques de código fenced. Un bloque que contenga ** o
    backticks sueltos puede verse reformateado.
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Sources,
    [string]$Template = "",
    [string]$Output   = "",
    [string]$Title    = "",
    [string]$Objeto   = "",
    [string]$Autor    = "",
    [string]$Version  = "1.0",
    [switch]$StripMarks,
    [switch]$Open
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$warnings = New-Object System.Collections.ArrayList

function Write-Result {
    param([hashtable]$Data)
    $Data | ConvertTo-Json -Depth 4
    exit 0
}

function Fail([string]$msg) {
    Write-Result @{ success = $false; error = $msg; warnings = @($warnings) }
}

# --- IDs built-in de Word (independientes del idioma de la instalación) ------
$WD_NORMAL   = -1
$WD_HEADING  = @(-2, -3, -4, -5, -6, -7, -8, -9, -10)   # Heading 1..9
$WD_TITLE    = -63
$WD_SUBTITLE = -75

# --- marcas de procedencia --------------------------------------------------
$MARK_CODE = [string][char]0x2705                                  # verificado en código
$MARK_OPS  = [string][char]0xD83D + [string][char]0xDC64           # aportado por operación
$VARSEL    = [string][char]0xFE0F                                  # variation selector

# ---------------------------------------------------------------------------
# Resolución de entradas
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Workspace)) { Fail "Workspace no encontrado: $Workspace" }

$mdFiles = New-Object System.Collections.ArrayList
foreach ($raw in ($Sources -split ';')) {
    $s = $raw.Trim()
    if ($s.Length -eq 0) { continue }
    if (-not [System.IO.Path]::IsPathRooted($s)) { $s = Join-Path $Workspace $s }
    if (-not (Test-Path -LiteralPath $s)) {
        [void]$warnings.Add("Origen no encontrado, se omite: $s")
        continue
    }
    if ((Get-Item -LiteralPath $s).PSIsContainer) {
        $found = Get-ChildItem -LiteralPath $s -Filter "*.md" -File | Sort-Object Name
        if ($found.Count -eq 0) { [void]$warnings.Add("Carpeta sin .md: $s") }
        foreach ($f in $found) { [void]$mdFiles.Add($f.FullName) }
    } else {
        [void]$mdFiles.Add((Resolve-Path -LiteralPath $s).Path)
    }
}
if ($mdFiles.Count -eq 0) { Fail "No hay ficheros .md que convertir en -Sources: $Sources" }

# plantilla
if ($Template.Length -eq 0) {
    $docsDir = Join-Path $Workspace "docs"
    if (Test-Path -LiteralPath $docsDir) {
        $cand = Get-ChildItem -LiteralPath $docsDir -Filter "*.dotx" -File | Sort-Object Name | Select-Object -First 1
        if ($cand) { $Template = $cand.FullName }
    }
}
if ($Template.Length -eq 0) { Fail "No se encontró plantilla .dotx en <Workspace>\docs y no se pasó -Template" }
if (-not [System.IO.Path]::IsPathRooted($Template)) { $Template = Join-Path $Workspace $Template }
if (-not (Test-Path -LiteralPath $Template)) { Fail "Plantilla no encontrada: $Template" }
$Template = (Resolve-Path -LiteralPath $Template).Path

# titulo / salida
if ($Title.Length -eq 0 -and $Output.Length -gt 0) { $Title = [System.IO.Path]::GetFileNameWithoutExtension($Output) }
if ($Title.Length -eq 0) { $Title = [System.IO.Path]::GetFileNameWithoutExtension($mdFiles[0]) }
if ($Output.Length -eq 0) {
    $safe = ($Title -replace '[\\/:\*\?"<>\|]', '-')
    $Output = Join-Path (Join-Path $Workspace "docs") "$safe.docx"
}
if (-not [System.IO.Path]::IsPathRooted($Output)) { $Output = Join-Path $Workspace $Output }
$outDir = Split-Path -Parent $Output
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# La plantilla puede venir de una unidad de red o marcada por el navegador; Word rehúsa abrirla.
$tplLocal = Join-Path $env:TEMP ("rs-render-word-" + [System.IO.Path]::GetFileNameWithoutExtension($Template) + ".dotx")
Copy-Item -LiteralPath $Template -Destination $tplLocal -Force
try { Unblock-File -LiteralPath $tplLocal -ErrorAction SilentlyContinue } catch { }

# ---------------------------------------------------------------------------
# Limpieza de texto Markdown
# ---------------------------------------------------------------------------
function Clean-Text {
    param([string]$Text, [bool]$IsCell = $false)
    if ($null -eq $Text) { return "" }
    $t = $Text

    # [texto](url) -> texto: los enlaces relativos del manual no navegan en Word
    $t = [regex]::Replace($t, '\[([^\]]+)\]\([^\)]*\)', '$1')

    if ($StripMarks) {
        if ($IsCell) {
            $bare = $t.Trim() -replace [regex]::Escape($VARSEL), ''
            if ($bare -eq $MARK_CODE) { return "Código" }
            if ($bare -eq $MARK_OPS)  { return "Operación" }
        }
        $t = $t -replace [regex]::Escape($MARK_CODE), ''
        $t = $t -replace [regex]::Escape($MARK_OPS), ''
        $t = $t -replace [regex]::Escape($VARSEL), ''
        $t = $t -replace '\s{2,}', ' '
        $t = $t.Trim()
        $t = $t -replace '^[/·\-—]\s*', ''
        $t = $t -replace '\s+([,\.;:])', '$1'
        if ($IsCell -and $t.Length -eq 0) { return "Operación" }
    } else {
        $t = $t.Trim()
    }
    return $t
}

function Strip-HeadingNumber([string]$Text) {
    # Los estilos de título de la plantilla ya numeran solos: un "3.2." manual duplicaría
    return ($Text -replace '^\d+(\.\d+)*\.?\s+', '')
}

# ---------------------------------------------------------------------------
# Word
# ---------------------------------------------------------------------------
try {
    $word = New-Object -ComObject Word.Application
} catch {
    Fail ("Microsoft Word no disponible por COM: " + $_.Exception.Message +
          ". Sin Word no hay conversión posible — el plugin no usa pandoc ni python-docx.")
}

$doc = $null
try {
    $word.Visible = $false
    $word.DisplayAlerts = 0

    # ⛔ 4º argumento (Visible del DOCUMENTO) = $true: sin ventana de documento, $word.Selection
    # es null y no se puede escribir. La aplicación sigue oculta por $word.Visible = $false.
    $doc = $word.Documents.Add($tplLocal, $false, 0, $true)

    $styNormal = $doc.Styles.Item($WD_NORMAL)
    $styHead   = @()
    foreach ($id in $WD_HEADING) {
        try   { $styHead += $doc.Styles.Item($id) }
        catch { $styHead += $styNormal }
    }

    # ---- 1. contenido de ejemplo de la plantilla -----------------------------
    $lastSection = $doc.Sections.Count
    $toDelete = @()
    foreach ($p in $doc.Paragraphs) {
        $txt = ($p.Range.Text -replace "[\r\n\x07]", "").Trim()
        if ($txt.Length -eq 0) { continue }
        $isHeading = $false
        foreach ($h in $styHead) { if ($p.Style.NameLocal -eq $h.NameLocal) { $isHeading = $true; break } }
        if ($isHeading) { $toDelete += $p; continue }
        if ($lastSection -ge 2 -and $p.Range.Sections.Item(1).Index -eq $lastSection) { $toDelete += $p }
    }
    for ($i = $toDelete.Count - 1; $i -ge 0; $i--) {
        try { $toDelete[$i].Range.Delete() | Out-Null } catch { }
    }

    # ---- 2. portada (por estilo, no por texto literal) -----------------------
    $portadaOk = $false
    foreach ($p in $doc.Paragraphs) {
        if ($p.Range.Sections.Item(1).Index -ne 1) { continue }
        $st = $p.Style.NameLocal
        $r = $p.Range
        if ($st -eq $doc.Styles.Item($WD_TITLE).NameLocal) {
            $r.MoveEnd(1, -1) | Out-Null; $r.Text = $Title; $portadaOk = $true
        }
        elseif ($Objeto.Length -gt 0 -and $st -eq $doc.Styles.Item($WD_SUBTITLE).NameLocal) {
            $r.MoveEnd(1, -1) | Out-Null; $r.Text = $Objeto
        }
    }
    if (-not $portadaOk) { [void]$warnings.Add("La plantilla no tiene párrafo con estilo Title en la 1ª sección: portada sin sustituir") }

    # ---- 3. historial de cambios --------------------------------------------
    if ($Autor.Length -gt 0) {
        if ($doc.Tables.Count -ge 1 -and $doc.Tables.Item(1).Rows.Count -ge 2 -and $doc.Tables.Item(1).Columns.Count -ge 4) {
            $ht = $doc.Tables.Item(1)
            $ht.Cell(2, 1).Range.Text = $Version
            $ht.Cell(2, 2).Range.Text = (Get-Date -Format "dd/MM/yyyy")
            $ht.Cell(2, 3).Range.Text = $Autor
            $ht.Cell(2, 4).Range.Text = "Versión inicial"
        } else {
            [void]$warnings.Add("No se encontró tabla de historial de cambios (>=2 filas, >=4 columnas): -Autor ignorado")
        }
    }

    # ---- 4. índice ----------------------------------------------------------
    # Si la plantilla trae un campo TOC, sus párrafos son RESULTADO DE CAMPO (rango de solo
    # lectura): intentar borrarlos o insertar otro TOC falla. Solo se actualiza al final.
    if ($doc.TablesOfContents.Count -eq 0) {
        [void]$warnings.Add("La plantilla no trae campo TOC: el documento saldrá sin índice")
    }

    # ---- 5. volcado del Markdown --------------------------------------------
    $sel = $word.Selection
    if ($null -eq $sel) { throw "Word no expone Selection (documento sin ventana)" }
    $sel.EndKey(6) | Out-Null   # wdStory

    $script:tableBuf = @()
    $script:inTable  = $false

    function Add-Para {
        param([string]$Text, $Style, [int]$IndentPt = 0, [bool]$Mono = $false)
        $sel.Style = $Style
        $sel.ParagraphFormat.LeftIndent = $IndentPt
        if ($Mono) { $sel.Font.Name = "Consolas"; $sel.Font.Size = 9 }
        if ($Text.Length -gt 0) { $sel.TypeText($Text) }
        $sel.TypeParagraph()
        if ($Mono) { $sel.Font.Name = $styNormal.Font.Name; $sel.Font.Size = $styNormal.Font.Size }
    }

    function Flush-Table {
        if (-not $script:inTable -or $script:tableBuf.Count -eq 0) {
            $script:tableBuf = @(); $script:inTable = $false; return
        }
        $rows = $script:tableBuf
        $nRows = $rows.Count
        $nCols = 0
        foreach ($r in $rows) { if ($r.Count -gt $nCols) { $nCols = $r.Count } }

        $sel.Style = $styNormal
        $sel.ParagraphFormat.LeftIndent = 0
        $tbl = $doc.Tables.Add($sel.Range, $nRows, $nCols)
        $tbl.Borders.InsideLineStyle  = 1
        $tbl.Borders.OutsideLineStyle = 1
        $tbl.Range.ParagraphFormat.SpaceAfter  = 2
        $tbl.Range.ParagraphFormat.SpaceBefore = 2
        $tbl.Range.Font.Size = 9

        for ($r = 0; $r -lt $nRows; $r++) {
            for ($c = 0; $c -lt $nCols; $c++) {
                $val = ""
                if ($c -lt $rows[$r].Count) { $val = $rows[$r][$c] }
                if ($val.Length -gt 0) { $tbl.Cell($r + 1, $c + 1).Range.Text = $val }
            }
        }
        $tbl.Rows.Item(1).Range.Font.Bold = $true
        $tbl.Rows.Item(1).Shading.BackgroundPatternColor = 15132390
        $tbl.Rows.Item(1).HeadingFormat = $true          # repite cabecera al partir de página
        $tbl.AutoFitBehavior(2) | Out-Null               # wdAutoFitWindow

        $sel.EndKey(6) | Out-Null
        $sel.Style = $styNormal
        $sel.ParagraphFormat.LeftIndent = 0

        $script:tableBuf = @()
        $script:inTable  = $false
    }

    foreach ($mdPath in $mdFiles) {
        $lines = Get-Content -LiteralPath $mdPath -Encoding UTF8
        $firstH1 = $true
        $inFence = $false

        foreach ($rawLine in $lines) {
            $line = $rawLine.TrimEnd()

            # ---- bloques de código fenced ----
            if ($line -match '^\s*```') {
                if ($script:inTable) { Flush-Table }
                $inFence = -not $inFence
                continue
            }
            if ($inFence) {
                Add-Para $rawLine $styNormal 18 $true
                continue
            }

            # ---- tablas ----
            if ($line -match '^\s*\|') {
                $cells = $line.Trim().Trim('|') -split '(?<!\\)\|'
                $isSep = $true
                foreach ($c in $cells) { if ($c.Trim() -notmatch '^:?-{2,}:?$') { $isSep = $false } }
                if (-not $isSep) {
                    $clean = @()
                    foreach ($c in $cells) { $clean += (Clean-Text $c $true) }
                    $script:tableBuf += , $clean
                }
                $script:inTable = $true
                continue
            }
            if ($script:inTable) { Flush-Table }

            if ($line.Trim().Length -eq 0) { continue }
            if ($line -match '^\s*---+\s*$') { continue }

            # ---- encabezados ----
            if ($line -match '^(#{1,6})\s+(.*)$') {
                $lvl = $Matches[1].Length
                $txt = Clean-Text $Matches[2]
                if ($lvl -eq 1) {
                    if ($firstH1) { Add-Para $txt $styHead[0]; $firstH1 = $false }
                    else { Add-Para (Strip-HeadingNumber $txt) $styHead[1] }
                    continue
                }
                $idx = [Math]::Min($lvl, 9) - 1
                Add-Para (Strip-HeadingNumber $txt) $styHead[$idx]
                continue
            }

            # ---- cita ----
            if ($line -match '^\s*>\s?(.*)$') {
                $inner = $Matches[1]
                if ($inner.Trim().Length -eq 0) { continue }
                if ($inner -match '^\s*-\s+(.*)$') { Add-Para ("• " + (Clean-Text $Matches[1])) $styNormal 36 }
                else { Add-Para (Clean-Text $inner) $styNormal 24 }
                continue
            }

            # ---- checklist ----
            if ($line -match '^\s*-\s+\[( |x|X)\]\s+(.*)$') {
                Add-Para ([string][char]0x2610 + " " + (Clean-Text $Matches[2])) $styNormal 18
                continue
            }

            # ---- viñetas ----
            if ($line -match '^(\s*)[-\*]\s+(.*)$') {
                $depth = [Math]::Floor($Matches[1].Length / 2)
                $bullet = [string][char]0x2022
                if ($depth -ge 1) { $bullet = [string][char]0x25E6 }
                Add-Para ($bullet + " " + (Clean-Text $Matches[2])) $styNormal (18 + 18 * $depth)
                continue
            }

            # ---- numeradas ----
            if ($line -match '^(\s*)\d+\.\s+(.*)$') {
                Add-Para (Clean-Text $line.Trim()) $styNormal 18
                continue
            }

            Add-Para (Clean-Text $line) $styNormal 0
        }
        Flush-Table
    }

    # ---- 6. formato inline ---------------------------------------------------
    # wdReplaceAll = 2, wdFindContinue = 1. El patrón [!x]@ evita que el comodín se coma
    # varias ocurrencias de la misma línea.
    $fB = $doc.Content.Find
    $fB.ClearFormatting(); $fB.Replacement.ClearFormatting()
    $fB.Replacement.Font.Bold = $true
    $null = $fB.Execute('\*\*([!\*]@)\*\*', $false, $false, $true, $false, $false, $true, 1, $true, '\1', 2)

    $fC = $doc.Content.Find
    $fC.ClearFormatting(); $fC.Replacement.ClearFormatting()
    $fC.Replacement.Font.Name = "Consolas"
    $fC.Replacement.Font.Size = 9
    $null = $fC.Execute('`([!`]@)`', $false, $false, $true, $false, $false, $true, 1, $true, '\1', 2)

    # ---- 7. índice y guardado ------------------------------------------------
    $doc.Repaginate()
    if ($doc.TablesOfContents.Count -ge 1) { $doc.TablesOfContents.Item(1).Update() | Out-Null }
    if ($doc.Fields.Count -ge 1) { $doc.Fields.Update() | Out-Null }

    $doc.SaveAs([ref]$Output, [ref]16)   # wdFormatDocumentDefault (.docx)

    $pages  = $doc.ComputeStatistics(2)  # wdStatisticPages
    $tables = $doc.Tables.Count

    $doc.Close(0)
    $doc = $null
    $word.Quit()
    $word = $null

    Write-Result @{
        success  = $true
        path     = $Output
        pages    = $pages
        tables   = $tables
        sources  = $mdFiles.Count
        template = $Template
        opened   = [bool]$Open
        warnings = @($warnings)
    }
}
catch {
    $msg = $_.Exception.Message
    try { if ($null -ne $doc)  { $doc.Close(0) } }  catch { }
    try { if ($null -ne $word) { $word.Quit() } }   catch { }
    Fail "Error generando el documento: $msg"
}
finally {
    if ($Open -and (Test-Path -LiteralPath $Output)) { Start-Process $Output }
}
