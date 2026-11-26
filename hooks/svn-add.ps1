<#
.SYNOPSIS
    Añade a SVN una lista EXPLICITA de ficheros sin versionar, con degradacion:
    1. svn CLI
    2. TortoiseProc.exe /command:add (solo ficheros)
    3. Instrucciones para el alta manual

.DESCRIPTION
    ⛔ Nunca "anade todo". Hasta la 3.30.0, -Files vacio detectaba y anadia todo lo no
    versionado del workspace, y con --force una carpeta arrastraba todo su contenido sin que el
    resultado lo reflejara (ver lib-vcsrutas.ps1). Ahora:
      - -Files es obligatorio; vacio, '.', la raiz, rutas fuera del workspace o comodines -> error.
      - Sin --force: lo ya versionado se informa en skipped, no se recorre.
      - Una carpeta nueva se anade con su contenido solo si el total no pasa de -MaxFiles; si
        pasa, no se anade NADA y se devuelve el desglose.
      - added es lo que quedo REALMENTE en estado A (svn status antes y despues), incluidas las
        carpetas padre que hizo falta anadir (--parents) y lo que arrastro cada carpeta.

.PARAMETER Workspace
    Raiz del working copy.

.PARAMETER Files
    Rutas separadas por ';' (se acepta ',' por compatibilidad), absolutas o relativas al workspace.

.PARAMETER MaxFiles
    Maximo de ficheros que puede programar la llamada entre todas las carpetas (defecto 50).

.EXAMPLE
    .\svn-add.ps1 "C:\SVN\RS\<Proyecto>\trunk" -Files "Batch\BusIN\Helper.cs;Batch\BusIN\IHelper.cs"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Files,
    [int]$MaxFiles = 50
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot "lib-vcsrutas.ps1")
$tortoisePath = "C:\Program Files\TortoiseSVN\bin\TortoiseProc.exe"
$maxListado   = 200

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

function Get-RsSvnAnadidos {
    <#
    .SYNOPSIS
        Rutas en estado A del working copy.
    .OUTPUTS
        Array de rutas tal como las escribe svn status.
    #>
    $salida = & svn status -q "$Workspace" 2>$null
    return @($salida | ForEach-Object { "$_" } | Where-Object { $_.Length -gt 8 -and $_[0] -eq 'A' } |
             ForEach-Object { $_.Substring(8).Trim() })
}

$r = Resolve-RsRutasExplicitas -Files $Files -Raiz $Workspace
if (-not $r.ok) {
    Write-RsResultado @{ success = $false; method = "none"; error = "lista de ficheros no valida: no se ha anadido nada"
                         rejected = @($r.errores); added = @(); failed = @() } 1
}

$hasSvnCli = $false
try { $null = & svn --version --quiet 2>&1; $hasSvnCli = ($LASTEXITCODE -eq 0) } catch {}

# ── Nivel 1: SVN CLI ──────────────────────────────────────────────────────────
if ($hasSvnCli) {
    $aAnadir = @(); $skipped = @(); $failed = @(); $expanded = @(); $total = 0
    foreach ($p in $r.rutas) {
        $rel = Get-RsRutaRelativa $p $Workspace
        if (-not (Test-Path -LiteralPath $p)) { $failed += @{ path = $rel; error = "no existe" }; continue }
        $linea = @(& svn status --depth empty "$p" 2>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() }) | Select-Object -First 1
        # W155010 = el nodo no existe en el working copy: cuelga de una carpeta sin versionar,
        # asi que es tan "sin versionar" como un '?' (svn add --parents anade esas carpetas).
        $codigo = if (-not $linea) { '' }
                  elseif ($linea -match 'W155010') { '?' }
                  elseif ($linea -match '^svn: ') { 'E' }
                  else { $linea[0] }
        switch ($codigo) {
            '?' {
                if (Test-Path -LiteralPath $p -PathType Container) {
                    # Cuenta en disco (fuera .svn): sobrestima lo que excluya svn:ignore, a proposito.
                    $n = @(Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue |
                           Where-Object { $_.FullName -notmatch '[\\/]\.svn([\\/]|$)' }).Count
                    $expanded += @{ path = $rel; files = $n }
                    $total += $n
                } else { $total += 1 }
                $aAnadir += $p
            }
            'I' { $failed += @{ path = $rel; error = "ignorado por svn:ignore: no se fuerza" } }
            'E' { $failed += @{ path = $rel; error = $linea.Trim() } }
            'A' { $skipped += @{ path = $rel; reason = "ya estaba programado para alta" } }
            default { $skipped += @{ path = $rel; reason = "ya versionado" } }
        }
    }

    if ($total -gt $MaxFiles) {
        Write-RsResultado @{
            success = $false; method = "cli"
            error   = "se programarian $total ficheros (maximo $MaxFiles): no se ha anadido nada. Revisar el contenido de las carpetas o subir max_files si de verdad hay que anadirlas enteras."
            expanded = @($expanded); added = @(); skipped = @($skipped); failed = @($failed)
        } 1
    }

    $antes = Get-RsSvnAnadidos
    foreach ($p in $aAnadir) {
        $err = & svn add --parents "$p" 2>&1 | Where-Object { "$_" -match 'svn: E' }
        if ($LASTEXITCODE -ne 0) { $failed += @{ path = (Get-RsRutaRelativa $p $Workspace); error = "$($err -join ' ')".Trim() } }
    }
    $nuevos = @(Get-RsSvnAnadidos | Where-Object { $antes -notcontains $_ } | ForEach-Object { Get-RsRutaRelativa $_ $Workspace })

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
        $resultado.warning = "se programaron $($nuevos.Count) elementos para $($aAnadir.Count) rutas pedidas (carpetas con contenido o carpetas padre): revisar added antes del commit"
    }
    Write-RsResultado $resultado 0
}

# ── Nivel 2: TortoiseProc (solo ficheros) ─────────────────────────────────────
# Sin svn CLI no se puede ni saber que esta versionado ni contar: con una carpeta TortoiseProc
# abre un dialogo con TODO su contenido preseleccionado, asi que las carpetas no se admiten.
if (Test-Path $tortoisePath) {
    $added = @(); $failed = @()
    foreach ($p in $r.rutas) {
        $rel = Get-RsRutaRelativa $p $Workspace
        if (Test-Path -LiteralPath $p -PathType Container) {
            $failed += @{ path = $rel; error = "carpeta: sin svn CLI solo se anaden ficheros uno a uno" }; continue
        }
        $proc = Start-Process -FilePath $tortoisePath -ArgumentList "/command:add /path:`"$p`" /closeonend:3" `
                              -Wait -PassThru -WindowStyle Minimized
        if ($proc.ExitCode -eq 0) { $added += $rel } else { $failed += @{ path = $rel; error = "TortoiseProc exit $($proc.ExitCode)" } }
    }
    Write-RsResultado @{
        success = ($failed.Count -eq 0); method = "tortoisesvn"; manual_required = ($failed.Count -gt 0)
        added = @($added); added_count = $added.Count; failed = @($failed)
        note  = "Anadido via TortoiseSVN, sin poder verificar con svn status: comprobar el estado antes del commit."
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
        "SVN CLI y TortoiseSVN no disponibles para anadir automaticamente.",
        "Anade manualmente SOLO estos ficheros antes del commit:",
        "  - Via TortoiseSVN: clic derecho en cada fichero -> TortoiseSVN -> Add",
        "  - Via CLI (si disponible): svn add --parents <fichero>"
    )
    added  = @()
    failed = @()
} 0
