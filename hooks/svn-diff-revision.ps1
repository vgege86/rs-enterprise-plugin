<#
.SYNOPSIS
    Obtiene el diff y metadatos de una o varias revisiones SVN.
    Filtra ficheros binarios/generados. Útil para validar qué cambió en un commit.

.PARAMETER Workspace
    Ruta raíz del proyecto.

.PARAMETER Revisions
    Revisión o revisiones separadas por coma. Ej: "1234" o "1234,1235,1236".

.PARAMETER MaxDiffChars
    Límite de caracteres del diff combinado (defecto 15000). Evita contextos enormes.

.EXAMPLE
    .\svn-diff-revision.ps1 "C:\SVN\RS\<Proyecto>\trunk" "1234"
    .\svn-diff-revision.ps1 "C:\SVN\RS\<Proyecto>\trunk" "1234,1235"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Revisions,
    [int]$MaxDiffChars = 15000
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
# Verificar SVN disponible
try {
    $null = & svn --version --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        @{ error = "SVN no disponible" } | ConvertTo-Json; exit 1
    }
} catch {
    @{ error = "SVN no encontrado en PATH" } | ConvertTo-Json; exit 1
}

# Extensiones relevantes (excluir binarios y generados)
$relevantExts  = @('.cs','.aspx','.asax','.ascx','.config','.xml','.sql','.json','.md','.ps1','.csproj','.sln')
$ignorePatterns = @('\\bin\\','\\obj\\','\\.vs\\','\.user$','\.suo$','\\packages\\','\.dll$','\.exe$','\.pdb$')

function Get-RevisionInfo([string]$workspace, [string]$rev) {
    # Metadatos via svn log --xml
    $logXml = & svn log $workspace -r $rev --xml --limit 1 2>&1
    $info = @{ revision = [int]$rev; author = ""; date = ""; message = "" }
    if ($LASTEXITCODE -eq 0) {
        try {
            [xml]$xml = ($logXml -join "`n")
            $entry = $xml.log.logentry
            if ($entry) {
                $info.author  = ($entry.author -as [string]).Trim()
                $rawDate = ($entry.date -as [string]).Trim()
                $info.date    = if ($rawDate.Length -ge 19) { $rawDate.Substring(0,19).Replace("T"," ") } else { $rawDate }
                $info.message = ($entry.msg -as [string]).Trim()
            }
        } catch {}
    }

    # Diff del changeset
    $diffLines  = & svn diff $workspace -c $rev 2>&1
    $filesChanged = @()
    $diffContent  = @()
    $currentFile  = ""
    $skipFile     = $false

    foreach ($line in $diffLines) {
        $lineStr = $line -as [string]

        # Detectar inicio de fichero en el diff
        if ($lineStr -match '^Index:\s+(.+)$') {
            $filePath = $Matches[1].Trim()
            $currentFile = $filePath

            # Decidir si incluir este fichero
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $skipFile = $relevantExts -notcontains $ext

            if (-not $skipFile) {
                foreach ($pat in $ignorePatterns) {
                    if ($filePath -match $pat) { $skipFile = $true; break }
                }
            }

            if (-not $skipFile) {
                $relPath = $filePath.Replace($workspace, "").TrimStart("\").TrimStart("/")
                if ($relPath -notin $filesChanged) { $filesChanged += $relPath }
            }
        }

        if (-not $skipFile) { $diffContent += $lineStr }
    }

    # Inferir solución desde paths o mensaje
    $inferredSln = ""
    $slnCandidate = $filesChanged | Where-Object { $_ -match '\\([^\\]+)\\[^\\]+\.cs$' } | Select-Object -First 1
    if ($slnCandidate -and $slnCandidate -match '\\([^\\]+)\\') {
        $inferredSln = $Matches[1]
    }
    if (-not $inferredSln -and $info.message -match '(\w+\.sln)') {
        $inferredSln = $Matches[1] -replace '\.sln$',''
    }

    return @{
        revision         = $info.revision
        author           = $info.author
        date             = $info.date
        message          = $info.message
        files_changed    = $filesChanged
        file_count       = $filesChanged.Count
        inferred_solution = $inferredSln
        diff_content     = ($diffContent -join "`n")
    }
}

# Procesar cada revisión
$revList = $Revisions -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
$revData = @()
$combinedDiff = ""

foreach ($rev in $revList) {
    $data = Get-RevisionInfo $Workspace $rev
    $revData += $data
    $combinedDiff += "`n### Revisión r$($data.revision) — $($data.message)`n" + $data.diff_content
}

# Truncar si es muy largo
$truncated = $false
if ($combinedDiff.Length -gt $MaxDiffChars) {
    $combinedDiff = $combinedDiff.Substring(0, $MaxDiffChars) + "`n`n[... DIFF TRUNCADO — $($combinedDiff.Length) chars totales, límite $MaxDiffChars ...]"
    $truncated = $true
}

# Unificar lista de ficheros
$allFiles = @($revData | ForEach-Object { $_.files_changed } | Select-Object -Unique)

# Inferir solución dominante
$inferredSln = $revData | Where-Object { $_.inferred_solution } | Select-Object -First 1 -ExpandProperty inferred_solution

@{
    workspace        = $Workspace
    revisions        = $revData | Select-Object revision, author, date, message, file_count, inferred_solution
    all_files        = $allFiles
    total_files      = $allFiles.Count
    inferred_solution = $inferredSln
    combined_diff    = $combinedDiff
    truncated        = $truncated
} | ConvertTo-Json -Depth 5
