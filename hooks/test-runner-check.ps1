<#
.SYNOPSIS
    Ejecuta los tests de la solución y devuelve resultados como JSON estructurado.
    Sustituye la simulación mental del LLM por ejecución real de tests.

    El runner se AUTODETECTA con el mismo criterio que compile-check.ps1 (hooks\lib-msbuild.ps1):
    `dotnet test` si todos los proyectos son SDK-style modernos, y MSBuild + `vstest.console.exe`
    si la solución tiene proyectos .NET Framework / web / COM, donde `dotnet test` no llega a
    ejecutar ni una prueba.

.PARAMETER SlnPath
    Ruta completa al archivo .sln

.PARAMETER NoBuild
    Si se especifica, omite build previo (usar cuando compile-check ya pasó)

.EXAMPLE
    .\test-runner-check.ps1 "C:\...\RSProcIN.sln" -NoBuild

.NOTES
    El resultado se lee del .trx (XML, invariante al idioma), NO del texto de consola: ver
    hooks/lib-trx.ps1 para el fallo que motivó el cambio (un CLI localizado devolvía 0/0 en
    verde). Aquí viven las dos consecuencias operativas de aquello:

      - se fuerza el idioma del CLI a inglés antes de invocar a dotnet, y
      - "no he podido contar" (`parse_failed`) y "no se ejecutó ninguna prueba"
        (`no_tests_ran`) salen SIEMPRE con success=false. Un conteo vacío nunca es un éxito.
#>
param(
    [Parameter(Mandatory=$true)][string]$SlnPath,
    [switch]$NoBuild
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib-trx.ps1")
. (Join-Path $PSScriptRoot "lib-msbuild.ps1")

if (-not (Test-Path $SlnPath)) {
    @{ success = $false; error = "Archivo no encontrado: $SlnPath" } | ConvertTo-Json
    exit 1
}

# Detectar proyectos de test en la solución
$slnDir = Split-Path $SlnPath -Parent
$slnContent = Get-Content $SlnPath -Encoding UTF8
$testProjects = @()
foreach ($line in $slnContent) {
    if ($line -match '"([^"]+\.csproj)"') {
        $csprojRel = $Matches[1].Replace('/', '\')
        $csprojAbs = Join-Path $slnDir $csprojRel
        if (Test-Path $csprojAbs) {
            $csprojContent = Get-Content $csprojAbs -Encoding UTF8 -Raw
            if ($csprojContent -match 'Microsoft\.NET\.Test\.Sdk|xunit|NUnit|MSTest') {
                $testProjects += $csprojAbs
            }
        }
    }
}

if ($testProjects.Count -eq 0) {
    @{ has_test_project = $false; reason = "No se encontraron proyectos de test en la solución" } | ConvertTo-Json
    exit 0
}

# Qué toolchain toca. Con proyectos .NET Framework, `dotnet test` no ejecuta nada (el mismo MSB4019
# de compile-check) y el resultado era "0 tests" — que este hook ya sabe NO tratar como verde, pero
# tampoco aportaba evidencia. Ver lib-msbuild.ps1.
#
# Se resuelve DESPUÉS de saber que hay algo que ejecutar: una solución sin proyecto de test no
# necesita runner, y exigirlo antes convertía "aquí no hay tests" en "falta Visual Studio".
$toolchain = Get-RsBuildToolchain -SlnPath $SlnPath
$vstest    = $null

if ($toolchain.error) {
    @{ success = $false; has_test_project = $true; runner_error = $toolchain.error; builder = $toolchain.builder } |
        ConvertTo-Json -Depth 4
    exit 1
}

if ($toolchain.builder -eq 'msbuild') {
    $vstest = Find-RsVsTestConsole
    if (-not $vstest) {
        @{
            success          = $false
            has_test_project = $true
            builder          = 'msbuild'
            runner_error     = "Esta solución tiene proyectos .NET Framework, cuyos tests ejecuta " +
                               "vstest.console.exe, y no se ha encontrado en esta máquina (ni por vswhere ni en el " +
                               "PATH). Instala Visual Studio o Build Tools con la carga de trabajo de pruebas. " +
                               "⛔ Los tests NO se han ejecutado: es un problema de entorno, NO tests en rojo."
        } | ConvertTo-Json -Depth 4
        exit 1
    }
}

# Carpeta temporal para los .trx del logger. Una por ejecución (GUID) para no mezclar el
# resultado de esta corrida con el de otra que siga en curso en la misma máquina.
$trxDir = Join-Path ([System.IO.Path]::GetTempPath()) ("rs-trx-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $trxDir -Force | Out-Null

# Idioma del CLI: dotnet/VSTest imprimen el resumen traducido al idioma del sistema y cualquier
# lectura por texto en inglés devolvería cero sin error. El .trx ya es inmune, pero si el build
# revienta antes de escribirlo el único resto es la consola: se fuerza inglés para que también
# ese camino acierte. Se restaura al salir por higiene (el hook puede correr dot-sourced).
$idiomaPrevio = $env:DOTNET_CLI_UI_LANGUAGE
$vslangPrevio = $env:VSLANG

try {
    $env:DOTNET_CLI_UI_LANGUAGE = "en"
    $env:VSLANG = "1033"

    # ⛔ `$ErrorActionPreference = "Stop"` (arriba) convierte el stderr de un comando NATIVO en error
    # terminante: en cuanto un test fallaba, el runner escribía "[FAIL]" por stderr y el hook moría
    # ahí mismo, sin emitir JSON. Es decir, el único caso que de verdad importa —hay tests rojos—
    # era el que no se podía reportar. Se baja la preferencia solo para esta llamada: el resultado
    # se juzga por $LASTEXITCODE y el .trx, no por si el proceso escribió en stderr.
    $eapPrevio = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    if ($toolchain.builder -eq 'msbuild') {
        # Camino .NET Framework: MSBuild compila, vstest.console ejecuta. `dotnet test` no sirve
        # aquí ni para una cosa ni para la otra.
        if (-not $NoBuild) {
            $buildArgs = @("-restore", $SlnPath, "-t:Build", "-v:minimal", "-nologo", "-nodeReuse:false")
            $buildRaw  = & $toolchain.builder_path @buildArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                $ErrorActionPreference = $eapPrevio
                @{
                    success          = $false
                    has_test_project = $true
                    builder          = 'msbuild'
                    build_failed     = $true
                    error            = "La solución no compiló con MSBuild, así que no se ejecutó ningún test. No interpretar como tests en verde."
                    raw_summary      = Get-RsLineasResumen -Lines @($buildRaw)
                } | ConvertTo-Json -Depth 4
                exit 0
            }
        }

        # vstest.console recibe .dll, no .csproj: hay que localizar el ensamblado ya compilado.
        $dlls = @()
        foreach ($proj in $testProjects) {
            $dll = Get-RsTestAssembly -ProjectPath $proj
            if ($dll) { $dlls += $dll }
        }

        if ($dlls.Count -eq 0) {
            $ErrorActionPreference = $eapPrevio
            @{
                success          = $false
                has_test_project = $true
                builder          = 'msbuild'
                parse_failed     = $true
                total = 0; passed = 0; failed = 0; skipped = 0; failures = @(); source = "none"
                error            = "Hay proyecto(s) de test pero no se encontró ningún ensamblado compilado en bin\. Con -NoBuild, compilar antes. No interpretar como tests en verde."
            } | ConvertTo-Json -Depth 4
            exit 0
        }

        $raw      = & $vstest @($dlls + @("/Logger:trx", "/ResultsDirectory:$trxDir")) 2>&1
        $exitCode = $LASTEXITCODE
    }
    else {
        # Operador de llamada con array de argumentos (no Invoke-Expression sobre una cadena): $SlnPath
        # va como UN argumento literal, evitando inyección de comandos vía una ruta con comillas/`;`.
        # Ver PSScriptAnalyzer PSAvoidUsingInvokeExpression (gate en CI).
        # Sin LogFileName a propósito: con varios proyectos de test todos escribirían el mismo fichero
        # y solo sobreviviría el último; el nombre por defecto es único por proyecto y corrida.
        $dotnetArgs = @("test", $SlnPath, "--nologo", "-v", "normal", "--results-directory", $trxDir, "--logger", "trx")
        if ($NoBuild) { $dotnetArgs += "--no-build" }
        $raw      = & $toolchain.builder_path @dotnetArgs 2>&1
        $exitCode = $LASTEXITCODE
    }

    $ErrorActionPreference = $eapPrevio

    # Fuente autoritativa: el .trx. La consola solo si no hay .trx legible.
    $resumen = Get-TrxSummary -Path $trxDir
    if (-not $resumen) { $resumen = Get-DotnetConsoleSummary -Lines @($raw) }

    $salida = [ordered]@{
        success          = $false
        has_test_project = $true
        exit_code        = $exitCode
        test_projects    = $testProjects.Count
        runner           = if ($toolchain.builder -eq 'msbuild') { "vstest.console" } else { "dotnet test" }
        runner_reason    = $toolchain.reason
    }

    if (-not $resumen) {
        # Ni .trx ni resumen en consola: NO se sabe qué ha pasado. Se reporta como fallo con la
        # salida cruda; degradar esto a 0/0/success=true es el bug que originó todo esto.
        $salida.total        = 0
        $salida.passed       = 0
        $salida.failed       = 0
        $salida.skipped      = 0
        $salida.failures     = @()
        $salida.source       = "none"
        $salida.parse_failed = $true
        $salida.error        = "No se pudo determinar el resultado de los tests: no se generó .trx y la salida de consola no contiene resumen. Revisar raw_summary; no interpretar como tests en verde."
        $salida.raw_summary  = Get-RsLineasResumen -Lines @($raw)
        $salida | ConvertTo-Json -Depth 4
        exit 0
    }

    $passed  = [int]$resumen.passed
    $failed  = [int]$resumen.failed
    $skipped = [int]$resumen.skipped
    $total   = [int]$resumen.total
    if ($total -eq 0) { $total = $passed + $failed + $skipped }

    $failures = @()
    if ($resumen.failures) { $failures = @($resumen.failures) }
    else {
        # Fallback de consola: el detalle de cada fallo solo está en el texto.
        # "  Failed  NombreTest [12 ms]" seguido de "Error Message:" / "Stack Trace:".
        $currentFail = $null
        foreach ($line in $raw) {
            if ($line -match '^\s+(?:Failed|Err[oó]neo)\s+(.+?)\s+\[') {
                if ($currentFail) { $failures += $currentFail }
                $currentFail = @{ test = $Matches[1].Trim(); message = ""; stack = "" }
            }
            elseif ($currentFail -and $line -match '^\s+(?:Error Message|Mensaje de error):\s+(.+)') {
                $currentFail.message = $Matches[1].Trim()
            }
            elseif ($currentFail -and $line -match '^\s+(?:Stack Trace|Seguimiento de la pila):\s+(.+)') {
                $currentFail.stack = $Matches[1].Trim()
            }
        }
        if ($currentFail) { $failures += $currentFail }
    }

    $salida.total    = $total
    $salida.passed   = $passed
    $salida.failed   = $failed
    $salida.skipped  = $skipped
    $salida.failures = $failures
    $salida.source   = $resumen.source

    if ($total -eq 0) {
        # El proyecto de test existe pero no corrió ni una prueba (filtro, build parcial, dll sin
        # tests descubiertos). Sin ejecución no hay evidencia: tampoco es verde.
        $salida.success      = $false
        $salida.no_tests_ran = $true
        $salida.error        = "El proyecto de test existe pero no se ejecutó ninguna prueba (0 tests). No interpretar como tests en verde."
    }
    else {
        $salida.success = ($exitCode -eq 0 -and $failed -eq 0)
    }

    if ($resumen.inconsistent) {
        $salida.counts_inconsistent = $true
        $salida.warning = "El resumen de consola no cuadra (passed+failed+skipped != total). Cifras aproximadas: no se generó .trx."
    }

    $salida.raw_summary = Get-RsLineasResumen -Lines @($raw)
    $salida | ConvertTo-Json -Depth 4
}
finally {
    $env:DOTNET_CLI_UI_LANGUAGE = $idiomaPrevio
    $env:VSLANG = $vslangPrevio
    Remove-Item -LiteralPath $trxDir -Recurse -Force -ErrorAction SilentlyContinue
}
