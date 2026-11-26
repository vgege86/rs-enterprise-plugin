<#
.SYNOPSIS
    Añade a Git una lista EXPLICITA de ficheros sin trackear, con degradacion:
    1. git CLI
    2. TortoiseGitProc.exe /command:add (solo ficheros)
    3. Instrucciones para el alta manual

.DESCRIPTION
    Espejo de svn-add.ps1. ⛔ Nunca "anade todo": hasta la 3.30.0, -Files vacio anadia todos
    los ?? del workspace y una carpeta arrastraba todo su contenido sin que el resultado lo
    reflejara (ver lib-vcsrutas.ps1). Ahora:
      - -Files es obligatorio; vacio, '.', la raiz, rutas fuera del workspace o comodines -> error.
      - Lo ya trackeado sale en skipped; lo ignorado por .gitignore no se fuerza.
      - Una carpeta se anade solo si lo que arrastra (git ls-files --others --exclude-standard,
        exacto) no pasa de -MaxFiles en total; si pasa, no se anade NADA.
      - added es lo que quedo REALMENTE en el indice como nuevo (antes/despues).

.PARAMETER Workspace
    Raiz del workspace (o subcarpeta del repositorio).

.PARAMETER Files
    Rutas separadas por ';' (se acepta ',' por compatibilidad), absolutas o relativas al workspace.

.PARAMETER MaxFiles
    Maximo de ficheros que puede anadir la llamada entre todas las carpetas (defecto 50).

.EXAMPLE
    .\git-add.ps1 "C:\Git\RS\<Proyecto>\trunk" -Files "Batch\BusIN\Helper.cs;Batch\BusIN\IHelper.cs"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Files,
    [int]$MaxFiles = 50
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot "lib-vcsrutas.ps1")
$tortoiseGitPath = "C:\Program Files\TortoiseGit\bin\TortoiseGitProc.exe"
$maxListado      = 200

function Write-RsResultado {
    <#
    .SYNOPSIS
        Emite el JSON de salida y termina con el codigo indicado.
    .PARAMETER Datos
        Hashtable con el resultado.
    .PARAMETER Codigo
        Codigo de salida (0 ok, 1 error).
    #>
    param([hashtable]$Datos, [int]$Codigo)
    $Datos | ConvertTo-Json -Depth 5
    exit $Codigo
}

function Get-RsGitAnadidos {
    <#
    .SYNOPSIS
        Ficheros nuevos en el indice, relativos al workspace.
    .OUTPUTS
        Array de rutas con '/' (formato de git).
    #>
    return @(& git -C "$Workspace" diff --cached --name-only --relative --diff-filter=A 2>$null | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

$r = Resolve-RsRutasExplicitas -Files $Files -Raiz $Workspace
if (-not $r.ok) {
    Write-RsResultado @{ success = $false; method = "none"; error = "lista de ficheros no valida: no se ha anadido nada"
                         rejected = @($r.errores); added = @(); failed = @() } 1
}

$hasGitCli = $false
try { $null = & git --version 2>&1; $hasGitCli = ($LASTEXITCODE -eq 0) } catch {}

# ── Nivel 1: Git CLI ──────────────────────────────────────────────────────────
if ($hasGitCli) {
    $aAnadir = @(); $skipped = @(); $failed = @(); $expanded = @(); $total = 0
    foreach ($p in $r.rutas) {
        $rel = Get-RsRutaRelativa $p $Workspace
        if (-not (Test-Path -LiteralPath $p)) { $failed += @{ path = $rel; error = "no existe" }; continue }
        if (Test-Path -LiteralPath $p -PathType Container) {
            $n = @(& git -C "$Workspace" ls-files --others --exclude-standard -- "$p" 2>$null | Where-Object { "$_".Trim() }).Count
            if ($n -eq 0) { $skipped += @{ path = $rel; reason = "sin ficheros nuevos que anadir (trackeados o ignorados)" }; continue }
            $expanded += @{ path = $rel; files = $n }
            $total += $n
            $aAnadir += $p
            continue
        }
        & git -C "$Workspace" ls-files --error-unmatch -- "$p" *> $null
        if ($LASTEXITCODE -eq 0) { $skipped += @{ path = $rel; reason = "ya trackeado" }; continue }
        & git -C "$Workspace" check-ignore -q -- "$p" *> $null
        if ($LASTEXITCODE -eq 0) { $failed += @{ path = $rel; error = "ignorado por .gitignore: no se fuerza" }; continue }
        $total += 1
        $aAnadir += $p
    }

    if ($total -gt $MaxFiles) {
        Write-RsResultado @{
            success = $false; method = "cli"
            error   = "se anadirian $total ficheros (maximo $MaxFiles): no se ha anadido nada. Revisar el contenido de las carpetas o subir max_files si de verdad hay que anadirlas enteras."
            expanded = @($expanded); added = @(); skipped = @($skipped); failed = @($failed)
        } 1
    }

    $antes = Get-RsGitAnadidos
    foreach ($p in $aAnadir) {
        $err = & git -C "$Workspace" add -- "$p" 2>&1
        if ($LASTEXITCODE -ne 0) { $failed += @{ path = (Get-RsRutaRelativa $p $Workspace); error = "$($err -join ' ')".Trim() } }
    }
    $nuevos = @(Get-RsGitAnadidos | Where-Object { $antes -notcontains $_ })

    $resultado = @{
        success         = ($failed.Count -eq 0)
        method          = "cli"
        manual_required = $false
        requested       = @($r.rutas | ForEach-Object { Get-RsRutaRelativa $_ $Workspace })
        added_count     = $nuevos.Count
        added           = @($nuevos | Select-Object -First $maxListado)
        added_truncated = ($nuevos.Count -gt $maxListado)
        expanded        = @($expanded)
        skipped         = @($skipped)
        failed          = @($failed)
    }
    if ($nuevos.Count -gt $aAnadir.Count) {
        $resultado.warning = "se anadieron $($nuevos.Count) ficheros para $($aAnadir.Count) rutas pedidas (carpetas con contenido): revisar added antes del commit"
    }
    Write-RsResultado $resultado 0
}

# ── Nivel 2: TortoiseGitProc (solo ficheros) ──────────────────────────────────
if (Test-Path $tortoiseGitPath) {
    $added = @(); $failed = @()
    foreach ($p in $r.rutas) {
        $rel = Get-RsRutaRelativa $p $Workspace
        if (Test-Path -LiteralPath $p -PathType Container) {
            $failed += @{ path = $rel; error = "carpeta: sin git CLI solo se anaden ficheros uno a uno" }; continue
        }
        $proc = Start-Process -FilePath $tortoiseGitPath -ArgumentList "/command:add /path:`"$p`" /closeonend:3" `
                              -Wait -PassThru -WindowStyle Minimized
        if ($proc.ExitCode -eq 0) { $added += $rel } else { $failed += @{ path = $rel; error = "TortoiseGitProc exit $($proc.ExitCode)" } }
    }
    Write-RsResultado @{
        success = ($failed.Count -eq 0); method = "tortoisegit"; manual_required = ($failed.Count -gt 0)
        added = @($added); added_count = $added.Count; failed = @($failed)
        note  = "Anadido via TortoiseGit, sin poder verificar con git status: comprobar el estado antes del commit."
    } 0
}

# ── Nivel 3: Manual ───────────────────────────────────────────────────────────
$relFiles = @($r.rutas | ForEach-Object { Get-RsRutaRelativa $_ $Workspace })
Write-RsResultado @{
    success         = $false
    method          = "manual"
    manual_required = $true
    files_pending   = $relFiles
    instructions    = @(
        "Git CLI y TortoiseGit no disponibles para anadir automaticamente.",
        "Anade manualmente SOLO estos ficheros antes del commit:",
        "  - Via TortoiseGit: clic derecho en cada fichero -> TortoiseGit -> Add",
        "  - Via CLI (si disponible): git add -- <fichero>"
    )
    added  = @()
    failed = @()
} 0
