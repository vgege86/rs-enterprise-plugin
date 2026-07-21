<#
.SYNOPSIS
    Obtiene el diff y metadatos de uno o varios commits Git. Espejo de svn-diff-revision.ps1.
    Filtra ficheros binarios/generados. Útil para validar qué cambió en un commit.

.PARAMETER Workspace
    Ruta raíz del proyecto.

.PARAMETER Revisions
    Hash (corto o completo) o hashes separados por coma. Ej: "a1b2c3d" o "a1b2c3d,e4f5a6b".

.PARAMETER MaxDiffChars
    Límite de caracteres del diff combinado (defecto 15000). Evita contextos enormes.

.EXAMPLE
    .\git-diff-revision.ps1 "C:\Git\RS\<Proyecto>\trunk" "a1b2c3d"
    .\git-diff-revision.ps1 "C:\Git\RS\<Proyecto>\trunk" "a1b2c3d,e4f5a6b"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Revisions,
    [int]$MaxDiffChars = 15000
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
# Verificar Git disponible
try {
    $null = & git --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        @{ error = "Git no disponible" } | ConvertTo-Json; exit 1
    }
} catch {
    @{ error = "Git no encontrado en PATH" } | ConvertTo-Json; exit 1
}

# Extensiones relevantes (excluir binarios y generados)
$relevantExts   = @('.cs','.aspx','.asax','.ascx','.config','.xml','.sql','.json','.md','.ps1','.csproj','.sln')
$ignorePatterns = @('\\bin\\','\\obj\\','\\.vs\\','\.user$','\.suo$','\\packages\\','\.dll$','\.exe$','\.pdb$')

function Get-RevisionInfo([string]$workspace, [string]$rev) {
    # Metadatos vía formato acotado (mismo separador que git-log.ps1)
    $format = "%h%x1f%an%x1f%ad%x1f%s"
    $metaOut = & git -C $workspace log -n 1 "--pretty=format:$format" --date=format:"%Y-%m-%d %H:%M:%S" $rev 2>&1
    $info = @{ revision = $rev; author = ""; date = ""; message = "" }
    if ($LASTEXITCODE -eq 0) {
        $fields = ($metaOut -join "") -split "`u{001f}"
        if ($fields.Count -ge 4) {
            $info.revision = $fields[0].Trim()
            $info.author   = $fields[1].Trim()
            $info.date     = $fields[2].Trim()
            $info.message  = $fields[3].Trim()
        }
    }

    # Diff del commit: "git show <rev>" trae metadatos + diff; nos quedamos solo con el diff
    # usando --format="" para que no repita cabecera, y -M para detectar renames.
    $diffLines = & git -C $workspace show $rev --format="" -M 2>&1
    $filesChanged = @()
    $diffContent  = @()
    $currentFile  = ""
    $skipFile     = $false

    foreach ($line in $diffLines) {
        $lineStr = $line -as [string]

        # Detectar inicio de fichero en el diff ("diff --git a/x b/x")
        if ($lineStr -match '^diff --git a/(.+) b/(.+)$') {
            $filePath = $Matches[2].Trim()
            $currentFile = $filePath

            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $skipFile = $relevantExts -notcontains $ext

            if (-not $skipFile) {
                foreach ($pat in $ignorePatterns) {
                    if ($filePath -match $pat) { $skipFile = $true; break }
                }
            }

            if (-not $skipFile) {
                $relPath = $filePath.Replace('/', '\')
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
        revision          = $info.revision
        author            = $info.author
        date              = $info.date
        message           = $info.message
        files_changed     = $filesChanged
        file_count        = $filesChanged.Count
        inferred_solution = $inferredSln
        diff_content      = ($diffContent -join "`n")
    }
}

# Procesar cada revisión
$revList = $Revisions -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
$revData = @()
$combinedDiff = ""

foreach ($rev in $revList) {
    $data = Get-RevisionInfo $Workspace $rev
    $revData += $data
    $combinedDiff += "`n### Commit $($data.revision) — $($data.message)`n" + $data.diff_content
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
    workspace         = $Workspace
    revisions         = $revData | Select-Object revision, author, date, message, file_count, inferred_solution
    all_files         = $allFiles
    total_files       = $allFiles.Count
    inferred_solution = $inferredSln
    combined_diff     = $combinedDiff
    truncated         = $truncated
} | ConvertTo-Json -Depth 5
