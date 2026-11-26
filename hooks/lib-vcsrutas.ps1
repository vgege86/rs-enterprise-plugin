<#
.SYNOPSIS
    Validacion de las listas EXPLICITAS de rutas que reciben svn-add.ps1, git-add.ps1 y
    vcs-revert.ps1. Libreria: dot-sourcear, no se invoca sola.

.DESCRIPTION
    ⛔ POR QUE EXISTE. Hasta la 3.30.0, svn-add.ps1 y git-add.ps1 interpretaban una lista vacia
    como "anade todo lo no versionado del workspace". En una instalacion de cliente, una llamada
    con el parametro mal escrito llego sin ficheros y programo para alta 57 elementos que se
    expandieron a 1925 ficheros (binarios, logs, configuracion y trabajo de otros
    desarrolladores del mismo working copy), con success:true. Y vcs-revert.ps1 aceptaba una
    carpeta, que en Git revierte el arbol entero.

    Una sola regla para los tres: la lista se valida ENTERA antes de tocar nada, y cualquier
    entrada invalida rechaza la llamada completa. Nunca se degrada a "todo".
#>

function Resolve-RsRutasExplicitas {
    <#
    .SYNOPSIS
        Valida y resuelve a ruta absoluta una lista de rutas separadas por ';' (o ',').
    .PARAMETER Files
        Lista tal cual llega del llamador.
    .PARAMETER Raiz
        Carpeta de la que cuelgan las rutas relativas y fuera de la cual no se acepta ninguna.
    .OUTPUTS
        @{ ok; rutas = @(rutas absolutas, sin duplicados); errores = @(@{ ruta; error }) }.
        ok = $false si la lista esta vacia o alguna entrada es invalida.
    #>
    param([AllowEmptyString()][string]$Files, [Parameter(Mandatory = $true)][string]$Raiz)

    $sep = [IO.Path]::DirectorySeparatorChar
    $raizAbs = [IO.Path]::GetFullPath(($Raiz -replace '[\\/]', $sep)).TrimEnd($sep)
    $entradas = @("$Files" -split '[;,]' | ForEach-Object { $_.Trim().Trim('"').Trim() } | Where-Object { $_ -ne "" })

    if ($entradas.Count -eq 0) {
        return @{ ok = $false; rutas = @(); errores = @(@{ ruta = ""; error = "lista de ficheros vacia: hay que indicar las rutas una a una" }) }
    }

    $rutas = @(); $errores = @()
    foreach ($e in $entradas) {
        if ($e -match '[\*\?\[\]]') {
            $errores += @{ ruta = $e; error = "comodines no admitidos: indicar cada fichero" }; continue
        }
        $normal = $e -replace '[\\/]', $sep
        $abs = if ([IO.Path]::IsPathRooted($normal)) { $normal } else { Join-Path $raizAbs $normal }
        $abs = [IO.Path]::GetFullPath($abs).TrimEnd($sep)

        if ($abs -ieq $raizAbs) {
            $errores += @{ ruta = $e; error = "es la raiz del workspace: equivaldria a 'todo'" }; continue
        }
        if (-not $abs.StartsWith($raizAbs + $sep, [StringComparison]::OrdinalIgnoreCase)) {
            $errores += @{ ruta = $e; error = "fuera del workspace ($raizAbs)" }; continue
        }
        if ($rutas -notcontains $abs) { $rutas += $abs }
    }

    return @{ ok = ($errores.Count -eq 0); rutas = @($rutas); errores = @($errores) }
}

function Get-RsRutaRelativa {
    <#
    .SYNOPSIS
        Ruta relativa a la raiz, para que la salida no repita la ruta absoluta del workspace.
    .PARAMETER Ruta
        Ruta absoluta o tal como la escribe svn/git.
    .PARAMETER Raiz
        Raiz del workspace.
    .OUTPUTS
        Cadena relativa; la ruta tal cual si no cuelga de la raiz.
    #>
    param([string]$Ruta, [string]$Raiz)
    $sep = [IO.Path]::DirectorySeparatorChar
    $r = ($Ruta -replace '[\\/]', $sep)
    $base = [IO.Path]::GetFullPath(($Raiz -replace '[\\/]', $sep)).TrimEnd($sep) + $sep
    if ($r.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $r.Substring($base.Length) }
    return $r
}
