<#
.SYNOPSIS
    Revierte una lista explícita de ficheros a su estado versionado (SVN o Git), o los elimina si
    son nuevos/sin versionar. Autodetecta el motor VCS. Pensado para deshacer los cambios pendientes
    del último cambio del pipeline (que aún no se han commiteado).

    ⛔ Solo revierte los ficheros que se le pasan explícitamente en -Files. Nunca descubre ni revierte
    nada por su cuenta: la lista la construye el llamador (agente rs-deshacer) a partir de git_status/
    svn_status y la confirma un humano antes de ejecutar sin -DryRun.

.PARAMETER Workspace
    Ruta del workspace (raíz del repo o subcarpeta dentro de él).

.PARAMETER Files
    Lista de ficheros a revertir, separados por punto y coma. Cada ruta puede ser absoluta o relativa
    a la raíz del repositorio.

.PARAMETER DryRun
    Si se especifica, no revierte nada: devuelve la acción planificada por fichero (revert / delete /
    skip) para que el llamador la muestre antes de confirmar.

.EXAMPLE
    .\vcs-revert.ps1 "C:\Git\RS\<Proyecto>\trunk" "Batch\...\Foo.cs;Batch\...\Bar.cs" -DryRun
    .\vcs-revert.ps1 "C:\SVN\RS\<Proyecto>\trunk" "Batch\...\Foo.cs"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Files,
    [switch]$DryRun
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
$hooksDir = Split-Path $PSCommandPath -Parent

if (-not (Test-Path $Workspace)) {
    @{ success = $false; error = "Workspace no encontrado: $Workspace" } | ConvertTo-Json
    exit 1
}

# Detectar motor VCS (reutiliza detect-vcs.ps1: sube niveles buscando .git/.svn)
$vcsInfo = & "$hooksDir\detect-vcs.ps1" $Workspace | ConvertFrom-Json
$vcs  = "$($vcsInfo.vcs)"
$root = "$($vcsInfo.root)"
if ($vcs -eq "none" -or -not $root) {
    @{ success = $false; error = "Sin control de versiones bajo $Workspace — no hay nada que revertir automáticamente" } | ConvertTo-Json
    exit 1
}

$fileList = @($Files -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
if ($fileList.Count -eq 0) {
    @{ success = $false; error = "Lista de ficheros vacía" } | ConvertTo-Json
    exit 1
}

# Normaliza a ruta absoluta (las relativas cuelgan de la raíz del repo)
function Resolve-Target {
    param([string]$f)
    if ([System.IO.Path]::IsPathRooted($f)) { return $f }
    return (Join-Path $root ($f -replace '/', '\'))
}

$planned = @()   # { file, action, reason }
$done    = @()
$errors  = @()

foreach ($f in $fileList) {
    $full = Resolve-Target $f

    if ($vcs -eq "git") {
        # Estado del fichero concreto (porcelain, NUL-terminado). Vacío → sin cambios pendientes.
        $st = & git -C $root status --porcelain=v1 -z -- "$full" 2>&1
        if ($LASTEXITCODE -ne 0) { $errors += @{ file = $f; error = "git status: $st" }; continue }
        $st = ("$st" -replace "`0.*$", "")   # primera entrada
        if (-not $st) { $planned += @{ file = $f; action = "skip"; reason = "sin cambios pendientes" }; continue }
        $xy = $st.Substring(0, 2)
        # '??' sin versionar o 'A ' añadido/staged → el fichero es nuevo → eliminar. Resto → restaurar a HEAD.
        if ($xy -eq "??" -or $xy[0] -eq 'A') {
            $planned += @{ file = $f; action = "delete"; reason = "fichero nuevo (no en HEAD)" }
        } else {
            $planned += @{ file = $f; action = "revert"; reason = "restaurar a HEAD (estado '$xy')" }
        }
    } else {
        # SVN: status de una ruta. Primera columna: '?' sin versionar, 'A' añadido, 'M'/'D' modificado/borrado.
        $st = & svn status "$full" 2>&1
        if ($LASTEXITCODE -ne 0) { $errors += @{ file = $f; error = "svn status: $st" }; continue }
        $line = @($st | Where-Object { "$_".Trim() -ne "" } | Select-Object -First 1)
        $code = if ($line) { "$line".Substring(0,1) } else { "" }
        if ($code -eq "?") {
            $planned += @{ file = $f; action = "delete"; reason = "fichero sin versionar" }
        } elseif ($code -eq "A") {
            $planned += @{ file = $f; action = "revert-add"; reason = "svn revert (deshace add) + eliminar" }
        } elseif ($code -eq "") {
            $planned += @{ file = $f; action = "skip"; reason = "sin cambios pendientes" }
        } else {
            $planned += @{ file = $f; action = "revert"; reason = "svn revert (estado '$code')" }
        }
    }
}

if ($DryRun) {
    @{ success = $true; vcs = $vcs; root = $root; dry_run = $true; planned = @($planned) } | ConvertTo-Json -Depth 5
    exit 0
}

foreach ($p in $planned) {
    $full = Resolve-Target $p.file
    try {
        switch ($p.action) {
            "revert" {
                if ($vcs -eq "git") { & git -C $root checkout HEAD -- "$full" 2>&1 | Out-Null }
                else                { & svn revert "$full" 2>&1 | Out-Null }
                $done += @{ file = $p.file; action = "reverted" }
            }
            "revert-add" {
                & svn revert "$full" 2>&1 | Out-Null
                if (Test-Path $full) { Remove-Item $full -Force -ErrorAction SilentlyContinue }
                $done += @{ file = $p.file; action = "reverted+deleted" }
            }
            "delete" {
                if ($vcs -eq "git" -and $full -ne $p.file) {
                    # 'A ' staged en git: quitar del índice antes de borrar
                    & git -C $root rm -f --cached --quiet -- "$full" 2>&1 | Out-Null
                }
                if (Test-Path $full) { Remove-Item $full -Force -ErrorAction SilentlyContinue }
                $done += @{ file = $p.file; action = "deleted" }
            }
            "skip" { $done += @{ file = $p.file; action = "skipped" } }
        }
    } catch {
        $errors += @{ file = $p.file; error = $_.Exception.Message }
    }
}

@{
    success  = ($errors.Count -eq 0)
    vcs      = $vcs
    root     = $root
    reverted = @($done)
    errors   = @($errors)
} | ConvertTo-Json -Depth 5
