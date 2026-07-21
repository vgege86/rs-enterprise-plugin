<#
.SYNOPSIS
    Añade ficheros sin trackear a Git con degradación graceful. Espejo de svn-add.ps1:
    1. git CLI (si disponible)
    2. TortoiseGitProc.exe /command:add (si TortoiseGit instalado)
    3. Lista ficheros pendientes para add manual

.PARAMETER Workspace
    Ruta raíz del proyecto.

.PARAMETER Files
    Rutas de ficheros a añadir separadas por coma.
    Si se omite → detecta automáticamente todos los ficheros sin trackear (status ??)
    dentro del workspace, excluyendo bin/obj/.vs.

.EXAMPLE
    .\git-add.ps1 "C:\Git\RS\<Proyecto>\trunk"
    .\git-add.ps1 "C:\Git\RS\<Proyecto>\trunk" -Files "Batch\BusIN\Helper.cs,Batch\BusIN\IHelper.cs"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$Files = ""
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ignorePatterns   = @('\\bin\\','\\obj\\','\\.vs\\','\.user$','\.suo$','\\packages\\')
$tortoiseGitPath  = "C:\Program Files\TortoiseGit\bin\TortoiseGitProc.exe"

# ── Detectar ficheros a añadir ────────────────────────────────────────────────
$filesToAdd = @()

if ($Files) {
    $filesToAdd = $Files -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } |
                  ForEach-Object { if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $Workspace $_ } }
} else {
    # Auto-detectar mediante git status
    $hasGitCli = $false
    try { $null = & git --version 2>&1; $hasGitCli = ($LASTEXITCODE -eq 0) } catch {}

    if ($hasGitCli) {
        $statusOutput = & git -C $Workspace status --porcelain=v1 2>&1
        foreach ($line in $statusOutput) {
            $lineStr = $line -as [string]
            if ($lineStr -match '^\?\?\s+(.+)$') {
                $path = $Matches[1].Trim().Replace('/', '\')
                $skip = $false
                foreach ($pat in $ignorePatterns) { if ($path -match $pat) { $skip = $true; break } }
                if (-not $skip) { $filesToAdd += (Join-Path $Workspace $path) }
            }
        }
    } else {
        @{
            success         = $false
            method          = "none"
            manual_required = $true
            message         = "Git CLI no disponible y no se pasaron ficheros concretos. Usa TortoiseGit para ver ficheros sin trackear."
            added           = @()
            failed          = @()
        } | ConvertTo-Json; exit 0
    }
}

if ($filesToAdd.Count -eq 0) {
    @{ success = $true; method = "none"; message = "Sin ficheros sin trackear que añadir"; added = @(); failed = @() } | ConvertTo-Json
    exit 0
}

# ── Nivel 1: Git CLI ──────────────────────────────────────────────────────────
$hasGitCli = $false
try { $null = & git --version 2>&1; $hasGitCli = ($LASTEXITCODE -eq 0) } catch {}

if ($hasGitCli) {
    $added = @(); $failed = @()
    foreach ($f in $filesToAdd) {
        & git -C $Workspace add -- $f 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $added += $f } else { $failed += $f }
    }
    @{
        success         = ($failed.Count -eq 0)
        method          = "cli"
        manual_required = $false
        added           = $added
        failed          = $failed
    } | ConvertTo-Json -Depth 3
    exit 0
}

# ── Nivel 2: TortoiseGitProc ──────────────────────────────────────────────────
if (Test-Path $tortoiseGitPath) {
    $added = @(); $failed = @()
    foreach ($f in $filesToAdd) {
        $proc = Start-Process -FilePath $tortoiseGitPath `
            -ArgumentList "/command:add /path:`"$f`" /closeonend:3" `
            -Wait -PassThru -WindowStyle Minimized 2>&1
        if ($proc.ExitCode -eq 0) { $added += $f } else { $failed += $f }
    }
    @{
        success         = ($failed.Count -eq 0)
        method          = "tortoisegit"
        manual_required = ($failed.Count -gt 0)
        added           = $added
        failed          = $failed
        note            = "Añadido via TortoiseGit. Puede requerir confirmación visual si algún fichero falló."
    } | ConvertTo-Json -Depth 3
    exit 0
}

# ── Nivel 3: Manual ───────────────────────────────────────────────────────────
$relFiles = $filesToAdd | ForEach-Object { $_.Replace($Workspace,"").TrimStart("\") }
@{
    success         = $false
    method          = "manual"
    manual_required = $true
    files_pending   = $relFiles
    instructions    = @(
        "Git CLI y TortoiseGit no disponibles para añadir automáticamente.",
        "Añade manualmente estos ficheros antes del commit:",
        "  - Via TortoiseGit: clic derecho en cada fichero → TortoiseGit → Add",
        "  - Via CLI (si disponible): git add <fichero>",
        "  - Via IDE: Git plugin → Stage changes"
    )
    added  = @()
    failed = $filesToAdd
} | ConvertTo-Json -Depth 3
