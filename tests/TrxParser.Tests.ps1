<#
    Tests Pester de la lectura de resultados de `dotnet test` (hooks/lib-trx.ps1).

    ⛔ Por qué existe este fichero: hasta la 3.15.0 el hook parseaba la consola SOLO en inglés.
    En una máquina con el CLI localizado ("Pruebas totales: 84 / Correcto: 84") no encontraba
    ningún número, dejaba los contadores en 0 y devolvía `success=true`. El pipeline entero leía
    ese 0/0 como "los tests pasan" sin que se hubiera verificado nada.

    Un fallo así no lo detecta ninguna revisión de código posterior: la salida es sintácticamente
    correcta y el JSON parece sano. Lo único que lo caza es un test que le dé al parser una salida
    localizada y exija un número. Eso es lo que hay aquí, junto con la otra mitad del arreglo: que
    "no he podido contar" devuelva $null (y no cero), para que el hook lo convierta en
    `parse_failed` en vez de en un éxito.

    Sin dependencia de dotnet: se le pasan líneas y ficheros .trx fabricados.

    Ejecutar: Invoke-Pester tests/TrxParser.Tests.ps1
#>

BeforeAll {
    . (Join-Path $PSScriptRoot "../hooks/lib-trx.ps1")

    $script:TrxOk = @'
<?xml version="1.0" encoding="UTF-8"?>
<TestRun id="00000000-0000-0000-0000-000000000001" xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
  <Results>
    <UnitTestResult testName="Suma_DevuelveTotal" outcome="Passed" />
  </Results>
  <ResultSummary outcome="Completed">
    <Counters total="84" executed="84" passed="84" failed="0" error="0" timeout="0" aborted="0" inconclusive="0" notExecuted="0" />
  </ResultSummary>
</TestRun>
'@

    $script:TrxConFallos = @'
<?xml version="1.0" encoding="UTF-8"?>
<TestRun id="00000000-0000-0000-0000-000000000002" xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
  <Results>
    <UnitTestResult testName="Resta_Negativa" outcome="Failed">
      <Output>
        <ErrorInfo>
          <Message>Assert.Equal() Failure
Expected: 3
Actual:   4</Message>
          <StackTrace>   at Tests.Resta_Negativa() in C:\x\Tests.cs:line 20</StackTrace>
        </ErrorInfo>
      </Output>
    </UnitTestResult>
  </Results>
  <ResultSummary outcome="Failed">
    <Counters total="10" executed="9" passed="8" failed="1" error="0" timeout="0" aborted="0" inconclusive="0" notExecuted="1" />
  </ResultSummary>
</TestRun>
'@
}

Describe "Get-TrxSummary — el .trx manda sobre el texto" {

    It "lee los contadores de un .trx en verde" {
        $f = Join-Path $TestDrive "ok.trx"
        Set-Content -LiteralPath $f -Value $script:TrxOk -Encoding UTF8
        $r = Get-TrxSummary -Path $f
        $r.total   | Should -Be 84
        $r.passed  | Should -Be 84
        $r.failed  | Should -Be 0
        $r.source  | Should -Be "trx"
    }

    It "extrae los tests fallidos con su mensaje" {
        $f = Join-Path $TestDrive "fallos.trx"
        Set-Content -LiteralPath $f -Value $script:TrxConFallos -Encoding UTF8
        $r = Get-TrxSummary -Path $f
        $r.failed            | Should -Be 1
        $r.skipped           | Should -Be 1
        $r.failures.Count    | Should -Be 1
        $r.failures[0].test  | Should -Be "Resta_Negativa"
        # El mensaje multilínea se aplana: si llegara con saltos rompería el JSON de una línea.
        $r.failures[0].message | Should -Match "Expected: 3"
        $r.failures[0].message | Should -Not -Match "`n"
    }

    It "suma los .trx de una carpeta (varios proyectos de test)" {
        $d = Join-Path $TestDrive "varios"
        New-Item -ItemType Directory -Path $d | Out-Null
        Set-Content -LiteralPath (Join-Path $d "a.trx") -Value $script:TrxOk -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $d "b.trx") -Value $script:TrxConFallos -Encoding UTF8
        $r = Get-TrxSummary -Path $d
        $r.total  | Should -Be 94
        $r.passed | Should -Be 92
        $r.failed | Should -Be 1
        $r.files  | Should -Be 2
    }

    It "cuenta los saltados por diferencia cuando notExecuted miente" {
        # VSTest deja notExecuted="0" aunque haya resultados con outcome="NotExecuted" (xunit +
        # [Fact(Skip=...)]): total-executed es la única lectura que los ve.
        $trx = @'
<?xml version="1.0" encoding="UTF-8"?>
<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
  <ResultSummary outcome="Failed">
    <Counters total="4" executed="3" passed="2" failed="1" error="0" timeout="0" aborted="0" inconclusive="0" notExecuted="0" />
  </ResultSummary>
</TestRun>
'@
        $f = Join-Path $TestDrive "saltados.trx"
        Set-Content -LiteralPath $f -Value $trx -Encoding UTF8
        $r = Get-TrxSummary -Path $f
        $r.skipped | Should -Be 1
        $r.passed  | Should -Be 2
        $r.failed  | Should -Be 1
    }

    It "devuelve `$null (no cero) si no hay .trx" {
        $d = Join-Path $TestDrive "vacia"
        New-Item -ItemType Directory -Path $d | Out-Null
        Get-TrxSummary -Path $d | Should -BeNullOrEmpty
    }

    It "devuelve `$null si el .trx está truncado" {
        $f = Join-Path $TestDrive "roto.trx"
        Set-Content -LiteralPath $f -Value "<TestRun><ResultSummary>" -Encoding UTF8
        Get-TrxSummary -Path $f | Should -BeNullOrEmpty
    }
}

Describe "Get-DotnetConsoleSummary — el fallback entiende el CLI localizado" {

    It "REGRESIÓN 3.16.0: un resumen en español da 84, no 0" {
        # Ésta es la salida real que devolvía 0/0/success=true.
        $lineas = @(
            "Pruebas totales: 84",
            "     Correcto: 84",
            "Tiempo total de ejecución de la prueba: 3,2 segundos"
        )
        $r = Get-DotnetConsoleSummary -Lines $lineas
        $r.total  | Should -Be 84
        $r.passed | Should -Be 84
        $r.failed | Should -Be 0
    }

    It "entiende el formato en línea en español (¡Correcto! - Con error: 2, ...)" {
        $lineas = @("¡Correcto! - Con error:     2, Correcto:    82, Omitido:     1, Total:    85, Duración: 3 s")
        $r = Get-DotnetConsoleSummary -Lines $lineas
        $r.passed  | Should -Be 82
        $r.failed  | Should -Be 2
        $r.skipped | Should -Be 1
        $r.total   | Should -Be 85
    }

    It "sigue entendiendo el formato en inglés" {
        $lineas = @("Passed!  - Failed:     0, Passed:    12, Skipped:     0, Total:    12, Duration: 1 s")
        $r = Get-DotnetConsoleSummary -Lines $lineas
        $r.passed | Should -Be 12
        $r.total  | Should -Be 12
    }

    It "devuelve `$null (no cero) cuando NO hay resumen que leer" {
        # El caso que debe acabar en parse_failed: sin esto, el hook inventaba un 0/0 en verde.
        $r = Get-DotnetConsoleSummary -Lines @("Restore complete", "Build succeeded")
        $r | Should -BeNullOrEmpty
    }

    It "marca inconsistent si las cifras no cuadran con el total" {
        $r = Get-DotnetConsoleSummary -Lines @("Total tests: 50", "Passed: 3")
        $r.inconsistent | Should -BeTrue
    }
}

Describe "Get-RsLineasResumen — nunca deja al agente sin evidencia" {

    It "recoge las líneas de resumen en español" {
        $r = Get-RsLineasResumen -Lines @("compilando...", "Pruebas totales: 84", "Correcto: 84")
        $r.Count | Should -Be 2
    }

    It "cae a la cola de la salida si ninguna línea casa" {
        $r = Get-RsLineasResumen -Lines @("aaa", "bbb", "ccc")
        $r.Count | Should -BeGreaterThan 0
    }

    It "convierte los ErrorRecord a texto (si no, el JSON se llena del objeto entero)" {
        $er = New-Object System.Management.Automation.ErrorRecord(
            (New-Object System.Exception("Test Run Failed.")), "RuntimeException",
            [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        $r = Get-RsLineasResumen -Lines @("Passed: 3", $er)
        $r | ForEach-Object { $_ | Should -BeOfType [string] }
    }
}

Describe "test-runner-check.ps1 — contrato de no-falso-verde" {

    BeforeAll {
        $script:hook = Join-Path $PSScriptRoot "../hooks/test-runner-check.ps1"
        $script:texto = Get-Content -LiteralPath $script:hook -Raw
    }

    It "existe el hook" {
        Test-Path $script:hook | Should -BeTrue
    }

    It "fuerza el idioma del CLI a inglés" {
        $script:texto | Should -Match 'DOTNET_CLI_UI_LANGUAGE\s*=\s*"en"'
        $script:texto | Should -Match 'VSLANG\s*=\s*"1033"'
    }

    It "pide el logger trx (fuente autoritativa)" {
        $script:texto | Should -Match '"--logger",\s*"trx"'
    }

    It "no declara success=true en el camino de parseo fallido" {
        $script:texto | Should -Match 'parse_failed\s*=\s*\$true'
        $script:texto | Should -Match 'no_tests_ran\s*=\s*\$true'
    }
}
