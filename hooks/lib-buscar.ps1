<#
.SYNOPSIS
    Búsqueda de texto en el árbol de una solución, compartida por find-symbol.ps1,
    search-code.ps1 y security-scan.ps1. Dot-sourcear desde quien la necesite.

.DESCRIPTION
    Los tres hooks recorrían el árbol con Get-ChildItem y abrían CADA fichero con Get-Content
    para comparar línea a línea con -match. Es la forma más cara de hacerlo en PowerShell: se
    paga un objeto por línea y una recompilación del regex por comparación.

    Medido sobre 3200 ficheros .cs de 65 líneas (buscando un símbolo, 6 patrones):

        Get-ChildItem + Get-Content + -match          6650 ms   ← lo que había
        EnumerateFiles + ReadAllLines + regex compil. 2836 ms
        EnumerateFiles + ReadAllText + Matches        2969 ms
        Select-String multi-patrón                    1480 ms   ← lo que hace esto

    Suelo de la operación: 121 ms enumerar + 468 ms leer los 3200 ficheros.

    Select-String gana porque el bucle por líneas y el motor de regex viven dentro del cmdlet,
    en C#, en vez de en el intérprete. Y acepta N patrones en una llamada, que es lo que hace
    barata la búsqueda de varios símbolos a la vez.

.NOTES
    ⛔ NO se usa ripgrep. `rg` está disponible dentro de la herramienta Bash del agente, pero como
    función del shell, no como `rg.exe` en el PATH del sistema: los hooks PowerShell —que es como
    Claude Code ejecuta esto— no lo alcanzan. Se comprobó recorriendo el PATH y buscando el
    binario en el árbol: no existe. Un camino "usa rg si está" sería código muerto que nadie
    ejecuta y que ninguna prueba cubre.

    ⛔ Sensibilidad a mayúsculas: el operador -match de PowerShell es case-INSENSITIVE por
    defecto, y los tres hooks se escribieron contando con eso. Select-String también lo es, así
    que la paridad sale sola; -DistinguirMayusculas está para pedir lo contrario a propósito.
    Cambiar el defecto rompería la paridad en silencio: 'CLASS foo' deja de casar con
    'class\s+foo'.
#>

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8


function Get-RsFicherosDeScope {
    <# Ficheros bajo $Directorios que casan alguno de los $Globs, excluyendo los que cuelgan de
       una de las $CarpetasExcluidas. Devuelve rutas completas, sin duplicados.

       Usa [IO.Directory]::EnumerateFiles en vez de Get-ChildItem: devuelve cadenas en lugar de
       FileInfo y es perezoso, así que no construye un objeto por fichero para tirarlo después. #>
    param(
        [string[]]$Directorios,
        [string[]]$Globs             = @('*.cs'),
        [string[]]$CarpetasExcluidas = @('bin', 'obj')
    )

    $regexExcluir = if ($CarpetasExcluidas) {
        '\\(' + (($CarpetasExcluidas | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\\'
    } else { $null }

    $vistos    = @{}
    $ficheros  = New-Object System.Collections.ArrayList

    foreach ($dir in $Directorios) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($glob in $Globs) {
            try {
                $enum = [IO.Directory]::EnumerateFiles($dir, $glob, [IO.SearchOption]::AllDirectories)
            } catch {
                continue   # directorio ilegible: se salta, no se inventa un resultado vacío global
            }
            foreach ($f in $enum) {
                if ($regexExcluir -and $f -match $regexExcluir) { continue }
                if ($vistos.ContainsKey($f)) { continue }
                $vistos[$f] = $true
                [void]$ficheros.Add($f)
            }
        }
    }
    return $ficheros.ToArray()
}


function Invoke-RsBusqueda {
    <# Busca $Patrones (regex) y devuelve [{file, line, texto, patron}].

       UNA entrada por línea coincidente: si varios patrones casan la misma línea, gana el
       PRIMERO del array. Es exactamente lo que hacía el `break` del recorrido original, y lo que
       hace Select-String con -Pattern múltiple —comprobado: emite un MatchInfo por línea y su
       .Pattern es el primero que casó—, así que el campo `patron` sale sin trabajo extra.

       ⚠️ Quien necesite TODOS los patrones que casan una línea (security-scan.ps1, que emite un
       hallazgo por patrón) tiene que llamar una vez por patrón, reutilizando $Ficheros para no
       volver a enumerar el árbol.

       $Ficheros permite pasar una lista ya enumerada; si no, se enumera aquí. #>
    param(
        [Parameter(Mandatory=$true)][string[]]$Patrones,
        [string[]]$Directorios,
        [string[]]$Globs             = @('*.cs'),
        [string[]]$CarpetasExcluidas = @('bin', 'obj'),
        [string[]]$Ficheros,
        [switch]$DistinguirMayusculas
    )

    if (-not $Ficheros) {
        $Ficheros = Get-RsFicherosDeScope -Directorios $Directorios -Globs $Globs `
                                          -CarpetasExcluidas $CarpetasExcluidas
    }
    # Select-String -LiteralPath con una lista vacía es un error, no un resultado vacío.
    if (-not $Ficheros -or $Ficheros.Count -eq 0) { return @() }

    $parametros = @{
        LiteralPath = $Ficheros
        Pattern     = $Patrones
        Encoding    = 'UTF8'      # mismo criterio que el `Get-Content -Encoding UTF8` de antes
        ErrorAction = 'SilentlyContinue'
    }
    if ($DistinguirMayusculas) { $parametros['CaseSensitive'] = $true }

    $salida = New-Object System.Collections.ArrayList
    foreach ($m in @(Select-String @parametros)) {
        [void]$salida.Add([PSCustomObject]@{
            file   = $m.Path
            line   = $m.LineNumber
            texto  = $m.Line
            patron = $m.Pattern
        })
    }
    return $salida.ToArray()
}
