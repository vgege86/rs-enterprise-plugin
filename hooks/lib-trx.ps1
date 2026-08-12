<#
.SYNOPSIS
    Lectura del resultado de `dotnet test` SIN depender del idioma del CLI.
    Compartido por test-runner-check.ps1 (y disponible para cualquier hook que ejecute tests).

      Get-TrxSummary            resultado autoritativo: lee el .trx (XML) que genera el logger
                                de VSTest. Los conteos viven en atributos (`passed`, `failed`,
                                `total`), no en frases, asi que son invariantes al idioma.

      Get-DotnetConsoleSummary  ultimo recurso: parsea el resumen impreso en consola. Reconoce
                                los rotulos en ingles Y en espanol, porque este camino solo se
                                usa cuando NO hay .trx (SDK viejo, build roto a mitad) y ahi ya
                                no se puede garantizar el idioma de la salida.

.NOTES
    POR QUE EXISTE ESTE FICHERO

    Hasta la 3.15.0 el hook parseaba unicamente la consola y unicamente en ingles:

        if ($line -match 'Passed:\s*(\d+)') { $passed = [int]$Matches[1] }

    En una maquina con el CLI localizado, `dotnet test` imprime "Pruebas totales: 84 /
    Correcto: 84". Ninguna de las tres expresiones encontraba numero, los contadores se
    quedaban en su valor inicial (0) y el hook devolvia `passed=0, failed=0, success=true`
    con `raw_summary` vacio.

    ⛔ El dano no es el numero mal: es que 0/0 se leia como VERDE. Toda etapa que se fiara de
    `run_tests` (el `tester` del pipeline, `/rs-test`, `/rs-validar-req`) concluia "los tests
    pasan" en un entorno donde el parseo no habia entendido nada. Un fallo de lectura se
    presentaba como exito de ejecucion, en silencio y sin una sola linea de aviso.

    De ahi las dos decisiones de diseno:

      1. La fuente primaria es el .trx, no el texto. El XML no se traduce.
      2. El hook llamante NUNCA convierte "no he podido contar" en exito: si estas funciones
         devuelven $null, eso es un fallo explicito (`parse_failed`), no un cero.

    El idioma se fuerza igualmente (DOTNET_CLI_UI_LANGUAGE/VSLANG en el hook) porque el .trx
    puede no llegar a escribirse si el build revienta antes; asi el fallback tambien acierta.
#>

# Rotulos del resumen por idioma. `dotnet test` ha usado varios formatos segun version
# ("Total tests: 84. Passed: 84." en los SDK antiguos, "Passed! - Failed: 0, Passed: 84, ..."
# en los actuales) y la traduccion tampoco es estable entre ellos, de ahi las alternativas.
$script:RsTrxPatronTotal   = '(?:Total\s+tests|Pruebas\s+totales|Total\s+de\s+pruebas|Total)\s*[:=]\s*(\d+)'
$script:RsTrxPatronPassed  = '(?:Passed|Correctas|Correcto|Superadas|Superado)\s*[:=]\s*(\d+)'
$script:RsTrxPatronFailed  = '(?:Failed|Con\s+error|Err[oó]neas|Err[oó]neo|Incorrecto)\s*[:=]\s*(\d+)'
$script:RsTrxPatronSkipped = '(?:Skipped|Omitidas|Omitido)\s*[:=]\s*(\d+)'

function Get-RsTrxTexto {
    <#
        Aplana un mensaje de error del .trx a una linea acotada: los saltos pasan a " | " y se
        corta a $Max. Un stack trace completo por test fallido inunda el contexto del agente.
    #>
    param([string]$Texto, [int]$Max = 600)

    if ([string]::IsNullOrWhiteSpace($Texto)) { return "" }
    $plano = ($Texto -replace '\s*\r?\n\s*', ' | ').Trim()
    if ($plano.Length -gt $Max) { $plano = $plano.Substring(0, $Max) + "..." }
    return $plano
}

function Get-TrxSummary {
    <#
        Lee uno o varios .trx y devuelve el agregado:
            @{ total; passed; failed; skipped; failures[]; source = "trx"; files }
        Devuelve $null si no hay ningun .trx legible con <Counters> — el llamante DEBE tratar
        ese $null como fallo de lectura, nunca como cero pruebas.

        -Path admite un fichero .trx o una carpeta (se recorren todos, un test project puede
        dejar el suyo: los contadores se suman).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    $ficheros = @()
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $ficheros = @(Get-ChildItem -LiteralPath $Path -Filter *.trx -File -Recurse -ErrorAction SilentlyContinue)
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        $ficheros = @(Get-Item -LiteralPath $Path)
    }
    if ($ficheros.Count -eq 0) { return $null }

    $total = 0; $passed = 0; $failed = 0; $skipped = 0
    $failures = @()
    $leidos = 0

    foreach ($f in $ficheros) {
        try {
            $xml = [xml](Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8)
        } catch {
            continue   # .trx truncado (el runner murio a mitad de escritura): no cuenta como leido
        }

        $contadores = $xml.TestRun.ResultSummary.Counters
        if (-not $contadores) { continue }
        $leidos++

        $total   += [int]$contadores.total
        $passed  += [int]$contadores.passed
        # error/timeout/aborted son fallos de ejecucion: si no se suman a failed, un test que
        # revienta el runner sale de la cuenta y el resto pasa por verde.
        $failed  += [int]$contadores.failed + [int]$contadores.error + [int]$contadores.timeout + [int]$contadores.aborted

        # Los saltados NO son fiables por atributo: VSTest escribe el resultado con
        # outcome="NotExecuted" y aun así deja `notExecuted="0"` en los contadores (visto con
        # xunit y [Fact(Skip=...)]). La diferencia total-executed sí los refleja, así que se toma
        # la mayor de las dos lecturas; si `executed` no viene, se queda con los atributos.
        $saltados = [int]$contadores.notExecuted + [int]$contadores.inconclusive
        if (-not [string]::IsNullOrWhiteSpace([string]$contadores.executed)) {
            $derivados = [int]$contadores.total - [int]$contadores.executed
            if ($derivados -gt $saltados) { $saltados = $derivados }
        }
        $skipped += $saltados

        foreach ($r in @($xml.TestRun.Results.UnitTestResult)) {
            if (-not $r) { continue }
            if ($r.outcome -notin @("Failed", "Error", "Timeout", "Aborted")) { continue }
            $failures += @{
                test    = [string]$r.testName
                message = Get-RsTrxTexto ([string]$r.Output.ErrorInfo.Message)
                stack   = Get-RsTrxTexto ([string]$r.Output.ErrorInfo.StackTrace)
            }
        }
    }

    if ($leidos -eq 0) { return $null }

    return @{
        total    = $total
        passed   = $passed
        failed   = $failed
        skipped  = $skipped
        failures = $failures
        source   = "trx"
        files    = $leidos
    }
}

function Get-DotnetConsoleSummary {
    <#
        Parsea el resumen de consola de `dotnet test` (ingles o espanol) y devuelve:
            @{ total; passed; failed; skipped; source = "console"; inconsistent }
        Devuelve $null si NO aparece ninguna linea de resumen — de nuevo, $null significa "no
        he podido contar", no "cero".

        Se acumula por linea porque con varios proyectos de test el runner imprime un resumen
        por proyecto; `inconsistent` avisa de que las cifras sumadas no cuadran con el total
        declarado (formato no previsto), para que el llamante no las presente como firmes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Lines)

    $total = 0; $passed = 0; $failed = 0; $skipped = 0
    $conResumen = 0

    foreach ($linea in $Lines) {
        $t = [string]$linea
        if ([string]::IsNullOrWhiteSpace($t)) { continue }

        $hit = $false
        # El orden importa: "Pruebas totales" contiene "totales", no "Total" suelto, y las
        # alternativas largas van primero dentro del propio patron.
        if ($t -match $script:RsTrxPatronTotal)   { $total   += [int]$Matches[1]; $hit = $true }
        if ($t -match $script:RsTrxPatronPassed)  { $passed  += [int]$Matches[1]; $hit = $true }
        if ($t -match $script:RsTrxPatronFailed)  { $failed  += [int]$Matches[1]; $hit = $true }
        if ($t -match $script:RsTrxPatronSkipped) { $skipped += [int]$Matches[1]; $hit = $true }
        if ($hit) { $conResumen++ }
    }

    if ($conResumen -eq 0) { return $null }

    return @{
        total        = $total
        passed       = $passed
        failed       = $failed
        skipped      = $skipped
        source       = "console"
        inconsistent = ($total -gt 0 -and ($passed + $failed + $skipped) -ne $total)
    }
}

function Get-RsLineasResumen {
    <#
        Lineas de la salida cruda que valen como resumen para el humano. Si ninguna casa (idioma
        o formato inesperado) devuelve la cola de la salida: preferible ruido a un array vacio,
        que fue justamente lo que dejo el fallo original sin evidencia ninguna.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Lines, [int]$Max = 40)

    # A texto ANTES de filtrar: `dotnet ... 2>&1` mezcla cadenas con ErrorRecord, y un ErrorRecord
    # sin convertir se serializa como un objeto entero (excepción, InvocationInfo, stack de
    # PowerShell) dentro del JSON. El agente recibiría media pantalla de ruido por cada línea.
    $texto = @($Lines | ForEach-Object { "$_" })

    $patron = 'Passed|Failed|Skipped|Test\s+Run|Total|Correcto|Correctas|Err[oó]ne|Con\s+error|Omitid|Pruebas'
    $utiles = @($texto | Where-Object { $_ -match $patron })
    if ($utiles.Count -eq 0) {
        $utiles = @($texto | Where-Object { $_ -match '\S' } | Select-Object -Last 15)
    }
    if ($utiles.Count -gt $Max) { $utiles = @($utiles | Select-Object -Last $Max) }
    return $utiles
}
