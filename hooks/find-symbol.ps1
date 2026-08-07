<#
.SYNOPSIS
    Busca uno o VARIOS símbolos C# (clase, método, propiedad, interfaz, enum) dentro de los
    directorios de scope. Devuelve las coincidencias con archivo y número de línea.
    Elimina que el LLM haga múltiples Glob+Grep para localizar código.

.PARAMETER Symbol
    Nombre del símbolo a buscar. Modo de un símbolo — salida { symbol, type, found, matches }.

.PARAMETER Symbols
    Lista de símbolos separados por coma. Modo lote — salida { symbols, total_symbols }, con una
    entrada por símbolo. UNA sola pasada sobre el árbol para todos, que es la razón de existir de
    este parámetro: la tool MCP batch_find_symbols lanzaba un proceso PowerShell por símbolo y
    cada uno recorría el scope entero (10 símbolos = 10 arranques y 10 recorridos).

.PARAMETER ScopeDirs
    Directorios de búsqueda, separados por punto y coma.
    Usar output de parse-sln.ps1 (campo scope_dirs unido con ";")

.PARAMETER Type
    Tipo de símbolo: class|method|property|interface|enum|any (default: any)

.EXAMPLE
    .\find-symbol.ps1 "ProcesarCliente" "C:\...\RSProcIN;C:\...\RSProcIN.DAL"
    .\find-symbol.ps1 "RCLIENTES" "C:\...\RSProcIN" -Type class
    .\find-symbol.ps1 -Symbols "Cliente,Pedido,Factura" -ScopeDirs "C:\...\RSProcIN"
#>
param(
    [Parameter(Position=0)][string]$Symbol,
    [Parameter(Position=1)][string]$ScopeDirs,
    [string]$Type = "any",
    [string]$Symbols = ""
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib-buscar.ps1")

$listaSimbolos = if ($Symbols) {
    @($Symbols -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
} elseif ($Symbol) {
    @($Symbol)
} else {
    @()
}

if (-not $listaSimbolos) {
    @{ error = "Hay que indicar -Symbol o -Symbols" } | ConvertTo-Json -Compress
    exit 1
}
if (-not $ScopeDirs) {
    @{ error = "Falta -ScopeDirs" } | ConvertTo-Json -Compress
    exit 1
}

$dirs = @($ScopeDirs -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })

# Patrones de búsqueda según tipo. Los mismos de siempre, símbolo a símbolo.
# ⛔ El símbolo se interpola SIN escapar, igual que antes: un nombre con metacaracteres de regex
# se sigue interpretando como regex. Se mantiene a propósito para no cambiar en silencio lo que
# devuelven llamadas que hoy funcionan; un identificador C# válido no tiene ninguno.
function Get-RsPatronesSimbolo {
    param([string]$S, [string]$T)
    switch ($T.ToLower()) {
        "class"     { @("class\s+$S[\s:{<]", "class\s+$S$") }
        "method"    { @("\s+$S\s*\(", "void\s+$S\s*\(", "public\s+\w+\s+$S\s*\(") }
        "property"  { @("public\s+\w+\s+$S\s*[{;]") }
        "interface" { @("interface\s+$S[\s:{<]", "interface\s+$S$") }
        "enum"      { @("enum\s+$S[\s{]") }
        default     { @("class\s+$S[\s:{<]", "interface\s+$S[\s:{<]", "enum\s+$S[\s{]",
                        "\s+$S\s*\(", "public\s+\w+\s+$S\s*[{;(]", "$S\s*=") }
    }
}

$patronesPorSimbolo = @{}
$todos = New-Object System.Collections.ArrayList
foreach ($s in $listaSimbolos) {
    $p = @(Get-RsPatronesSimbolo -S $s -T $Type)
    $patronesPorSimbolo[$s] = $p
    foreach ($x in $p) { [void]$todos.Add($x) }
}

# UNA pasada para todos los símbolos y todos sus patrones. Lo que vuelve es el conjunto de líneas
# candidatas; la atribución a cada símbolo se hace abajo sobre ese conjunto, que es pequeño.
# Cualquier línea que case un patrón de un símbolo está aquí por construcción: se pasa la unión.
$candidatas = Invoke-RsBusqueda -Patrones $todos.ToArray() -Directorios $dirs `
                                -Globs @('*.cs') -CarpetasExcluidas @('bin', 'obj')

# La atribución se rehace por símbolo en vez de leer el `patron` que ya trae la candidata: con
# varios símbolos, una misma línea puede casar patrones de dos de ellos y tiene que aparecer bajo
# LOS DOS —es lo que pasaba cuando cada símbolo se buscaba por separado—, cada uno con su propio
# primer patrón. Se recorre en el orden de los patrones y se corta en el primero, como el `break`
# del recorrido original, para que el campo `match` no cambie de valor.
function Get-RsCoincidenciasDe {
    param($Candidatas, [string[]]$Patrones)
    $res = New-Object System.Collections.ArrayList
    foreach ($c in $Candidatas) {
        foreach ($pat in $Patrones) {
            if ($c.texto -match $pat) {
                [void]$res.Add(@{
                    file    = $c.file
                    line    = $c.line
                    content = $c.texto.Trim()
                    match   = $pat
                })
                break
            }
        }
    }
    # ⛔ El @() es obligatorio. Sort-Object -Unique con UN solo elemento devuelve el objeto, no un
    # array de uno, y entonces `.Count` sobre el hashtable cuenta sus CLAVES: la versión anterior
    # respondía found=4 y `matches` como objeto cuando había exactamente una coincidencia.
    return @($res.ToArray() | Sort-Object { "$($_.file):$($_.line)" } -Unique)
}

if ($Symbols) {
    $porSimbolo = @{}
    foreach ($s in $listaSimbolos) {
        $m = @(Get-RsCoincidenciasDe -Candidatas $candidatas -Patrones $patronesPorSimbolo[$s])
        $porSimbolo[$s] = @{
            found   = ($m.Count -gt 0)
            count   = $m.Count
            matches = $m
        }
    }
    @{
        symbols       = $porSimbolo
        total_symbols = $listaSimbolos.Count
    } | ConvertTo-Json -Depth 6
}
else {
    $m = @(Get-RsCoincidenciasDe -Candidatas $candidatas -Patrones $patronesPorSimbolo[$Symbol])
    @{
        symbol  = $Symbol
        type    = $Type
        found   = $m.Count
        matches = $m
    } | ConvertTo-Json -Depth 4
}
