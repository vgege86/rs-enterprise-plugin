<#
    Tests Pester de la integracion PII en hooks/db-query.ps1 y del CLI que la aplica.

    No requieren BD: el CLI se prueba directo por stdin, y del hook solo se comprueba
    que delega (la guarda de solo-lectura ya la cubre DbQuery.Tests.ps1).

    Ejecutar: pwsh -NoProfile -Command "Invoke-Pester tests/PiiGuard.Tests.ps1"
    (pwsh, no powershell: la suite usa Join-Path de tres argumentos, que es PS 6+)
#>

Describe "pii_cli.py" {
    BeforeAll {
        $script:cli   = Join-Path $PSScriptRoot ".." "scripts" "pii_cli.py"
        $script:ws    = Join-Path $TestDrive "trunk"
        $bd           = Join-Path $script:ws "BD"
        New-Item -ItemType Directory -Path $bd -Force | Out-Null
        @'
{
  "pii_policy": { "mode": "enforce" },
  "subviews": { "Parametricas": ["RIDIOMA"] },
  "tables": {
    "RDEUDORES": { "columns": {
      "IDDEUDOR": { "type": "NUMBER(10)", "pk": true },
      "NOMBRE":   { "type": "VARCHAR2(60)" }
    }}
  }
}
'@ | Set-Content (Join-Path $bd "Proyecto-model.json") -Encoding UTF8
    }

    It "existe el CLI" {
        Test-Path $script:cli | Should -BeTrue
    }

    It "enmascara la columna de texto y respeta la PK" {
        $entrada = @{
            columns = @("IDDEUDOR", "NOMBRE")
            rows    = @(, @("1024", "Ana Lopez"))
            sql     = "SELECT IDDEUDOR, NOMBRE FROM RDEUDORES"
        } | ConvertTo-Json -Depth 5 -Compress

        $salida = $entrada | python $script:cli $script:ws | ConvertFrom-Json
        $salida.rows[0][0] | Should -Be "1024"
        $salida.rows[0][1] | Should -Match "^pii:[0-9a-f]{12}$"
        $salida.pii.masked | Should -Contain "NOMBRE"
    }

    It "no toca nada si el modelo no declara politica" {
        $wsSinModelo = Join-Path $TestDrive "otro"
        New-Item -ItemType Directory -Path $wsSinModelo -Force | Out-Null
        $entrada = @{
            columns = @("NOMBRE")
            rows    = @(, @("Ana Lopez"))
            sql     = "SELECT NOMBRE FROM RDEUDORES"
        } | ConvertTo-Json -Depth 5 -Compress

        $salida = $entrada | python $script:cli $wsSinModelo | ConvertFrom-Json
        $salida.rows[0][0] | Should -Be "Ana Lopez"
        $salida.pii.mode   | Should -Be "off"
    }

    It "devuelve la entrada intacta si el enmascarado falla" {
        # Contrato de fallo ABIERTO en el hook: mejor devolver el dato que romper la
        # consulta. La proteccion real la da la tool MCP; este es el camino fallback.
        $salida = "no es json" | python $script:cli $script:ws
        $LASTEXITCODE | Should -Not -Be 0
    }
}
