<#
.SYNOPSIS
    Añade ficheros sin versionar a SVN con degradación graceful:
    1. svn CLI (si disponible)
    2. TortoiseProc.exe /command:add (si TortoiseSVN instalado)
    3. Lista ficheros pendientes para add manual

.PARAMETER Workspace
    Ruta raíz del proyecto.

.PARAMETER Files
    Rutas de ficheros a añadir separadas por coma.
    Si se omite → detecta automáticamente todos los ficheros sin versionar (status ?)
    dentro del workspace, excluyendo bin/obj/.vs.

.EXAMPLE
    .\svn-add.ps1 "C:\SVN\RS\<Proyecto>\trunk"
    .\svn-add.ps1 "C:\SVN\RS\<Proyecto>\trunk" -Files "Batch\BusIN\Helper.cs,Batch\BusIN\IHelper.cs"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$Files = ""
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ignorePatterns = @('\\bin\\','\\obj\\','\\.vs\\','\.user$','\.suo$','\\packages\\')
$tortoisePath   = "C:\Program Files\TortoiseSVN\bin\TortoiseProc.exe"

# ── Detectar ficheros a añadir ────────────────────────────────────────────────
$filesToAdd = @()

if ($Files) {
    $filesToAdd = $Files -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } |
                  ForEach-Object { if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $Workspace $_ } }
} else {
    # Auto-detectar mediante svn status o búsqueda directa
    $hasSvnCli = $false
    try { $null = & svn --version --quiet 2>&1; $hasSvnCli = ($LASTEXITCODE -eq 0) } catch {}

    if ($hasSvnCli) {
        $statusOutput = & svn status $Workspace 2>&1
        foreach ($line in $statusOutput) {
            $lineStr = $line -as [string]
            if ($lineStr -match '^\?\s+(.+)$') {
                $path = $Matches[1].Trim()
                $skip = $false
                foreach ($pat in $ignorePatterns) { if ($path -match $pat) { $skip = $true; break } }
                if (-not $skip) { $filesToAdd += $path }
            }
        }
    } else {
        # Sin CLI: buscar ficheros no versionados escaneando .svn/entries o simplemente
        # devolver aviso de que se requiere detección manual
        @{
            success         = $false
            method          = "none"
            manual_required = $true
            message         = "SVN CLI no disponible y no se pasaron ficheros concretos. Usa TortoiseSVN para ver ficheros sin versionar (icono ?)."
            added           = @()
            failed          = @()
        } | ConvertTo-Json; exit 0
    }
}

if ($filesToAdd.Count -eq 0) {
    @{ success = $true; method = "none"; message = "Sin ficheros sin versionar que añadir"; added = @(); failed = @() } | ConvertTo-Json
    exit 0
}

# ── Nivel 1: SVN CLI ──────────────────────────────────────────────────────────
$hasSvnCli = $false
try { $null = & svn --version --quiet 2>&1; $hasSvnCli = ($LASTEXITCODE -eq 0) } catch {}

if ($hasSvnCli) {
    $added = @(); $failed = @()
    foreach ($f in $filesToAdd) {
        & svn add $f --force 2>&1 | Out-Null
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

# ── Nivel 2: TortoiseProc ─────────────────────────────────────────────────────
if (Test-Path $tortoisePath) {
    $added = @(); $failed = @()
    foreach ($f in $filesToAdd) {
        $proc = Start-Process -FilePath $tortoisePath `
            -ArgumentList "/command:add /path:`"$f`" /closeonend:3" `
            -Wait -PassThru -WindowStyle Minimized 2>&1
        if ($proc.ExitCode -eq 0) { $added += $f } else { $failed += $f }
    }
    @{
        success         = ($failed.Count -eq 0)
        method          = "tortoisesvn"
        manual_required = ($failed.Count -gt 0)
        added           = $added
        failed          = $failed
        note            = "Añadido via TortoiseSVN. Puede requerir confirmación visual si algún fichero falló."
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
        "SVN CLI y TortoiseSVN no disponibles para añadir automáticamente.",
        "Añade manualmente estos ficheros antes del commit:",
        "  - Via TortoiseSVN: clic derecho en cada fichero → TortoiseSVN → Add",
        "  - Via CLI (si disponible): svn add <fichero>",
        "  - Via IDE: SVN plugin → Mark for Add"
    )
    added  = @()
    failed = $filesToAdd
} | ConvertTo-Json -Depth 3
