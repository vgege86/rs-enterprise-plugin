<#
.SYNOPSIS
    Detecta qué sistema de control de versiones hay bajo un workspace: SVN, Git o ninguno.
    Sube desde $Workspace comprobando .svn / .git en cada nivel (hasta 6 niveles) — cubre
    el caso normal (marca en la raíz del workspace) y el caso de subcarpetas dentro de un WC mayor.

.PARAMETER Workspace
    Ruta del workspace (carpeta raíz del proyecto, ej. ...\trunk\).

.EXAMPLE
    .\detect-vcs.ps1 "C:\SVN\RS\<Proyecto>\trunk"
    .\detect-vcs.ps1 "C:\Git\RS\<Proyecto>\trunk"
#>
param(
    [Parameter(Mandatory = $true)][string]$Workspace
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

if (-not (Test-Path $Workspace)) {
    @{ error = "Workspace no encontrado: $Workspace"; vcs = "none" } | ConvertTo-Json
    exit 1
}

$current = (Resolve-Path $Workspace).Path
$maxLevels = 6

for ($i = 0; $i -lt $maxLevels; $i++) {
    # .git puede ser carpeta (repo normal) o fichero (worktree, apunta al gitdir real)
    if (Test-Path (Join-Path $current ".git")) {
        @{ vcs = "git"; root = $current } | ConvertTo-Json
        exit 0
    }
    # .svn en checkouts modernos (>=1.7) solo vive en la raíz del WC, no en cada subcarpeta
    if (Test-Path (Join-Path $current ".svn")) {
        @{ vcs = "svn"; root = $current } | ConvertTo-Json
        exit 0
    }
    $parent = Split-Path $current -Parent
    if (-not $parent -or $parent -eq $current) { break }
    $current = $parent
}

@{ vcs = "none"; root = $null } | ConvertTo-Json
