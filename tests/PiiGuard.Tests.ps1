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

    It "sale con error si el modelo BD no es JSON valido (no lo trata como ausencia de modelo)" {
        # Un modelo roto (a medio escribir, merge sin terminar) NO es lo mismo que "no hay
        # modelo": si se tratara igual, un modelo corrupto apagaria el enmascarado en
        # silencio. Debe fallar visible (exit != 0), no degradar a mode=off.
        $wsModeloRoto = Join-Path $TestDrive "modelo-roto"
        $bdRoto = Join-Path $wsModeloRoto "BD"
        New-Item -ItemType Directory -Path $bdRoto -Force | Out-Null
        "{ esto no es json" | Set-Content (Join-Path $bdRoto "Roto-model.json") -Encoding UTF8

        $entrada = @{
            columns = @("NOMBRE")
            rows    = @(, @("Ana Lopez"))
            sql     = "SELECT NOMBRE FROM RDEUDORES"
        } | ConvertTo-Json -Depth 5 -Compress

        $null = $entrada | python $script:cli $wsModeloRoto 2>$null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It "sale con error si la raiz del modelo BD es una lista en vez de un objeto" {
        # Mismo caso que el anterior via otra forma de corrupcion: JSON valido pero con
        # forma equivocada. Sin esta guarda, pii_policy.cargar_politica revienta con
        # AttributeError al intentar ".get" sobre una lista.
        $wsModeloLista = Join-Path $TestDrive "modelo-lista"
        $bdLista = Join-Path $wsModeloLista "BD"
        New-Item -ItemType Directory -Path $bdLista -Force | Out-Null
        '["esto", "es", "una", "lista"]' | Set-Content (Join-Path $bdLista "Lista-model.json") -Encoding UTF8

        $entrada = @{
            columns = @("NOMBRE")
            rows    = @(, @("Ana Lopez"))
            sql     = "SELECT NOMBRE FROM RDEUDORES"
        } | ConvertTo-Json -Depth 5 -Compress

        $null = $entrada | python $script:cli $wsModeloLista 2>$null
        $LASTEXITCODE | Should -Not -Be 0
    }
}

Describe "db-query.ps1 camino sin filas" {
    <#
        sqlplus mockeado: sin BD real no se puede provocar un resultset vacio de otra
        forma. Cubre el hallazgo de revision: el camino sin filas (y el de error de
        sqlplus) se saltaban tanto la forma nueva de respuesta (columns/pii) como el
        saneado del eco de SQL, asi que una consulta que no encuentra filas -la forma
        tipica de una busqueda dirigida a una persona concreta- devolvia el literal
        (ej. un DNI) intacto.
    #>
    BeforeAll {
        $script:hook = Join-Path $PSScriptRoot ".." "hooks" "db-query.ps1"
        $script:ws2  = Join-Path $TestDrive "trunk-sinfilas"
        $docs2       = Join-Path $script:ws2 "docs"
        New-Item -ItemType Directory -Path $docs2 -Force | Out-Null
        @'
{
  "conexiones": [
    { "id": "principal", "motor": "ORACLE", "cadena": "Data Source=XE;User Id=u;Password=p" }
  ]
}
'@ | Set-Content (Join-Path $docs2 ".rs-databases.json") -Encoding UTF8
    }

    It "sin filas: columns/rows/pii presentes y el eco de SQL sanea el literal (ej. un DNI)" {
        # sqlplus real no emite nada -ni cabecera- cuando la consulta no devuelve filas.
        Mock -CommandName sqlplus -MockWith { $global:LASTEXITCODE = 0 }

        $sql = "SELECT * FROM RDEUDORES WHERE DNI = '12345678Z'"
        $out = & $script:hook -Workspace $script:ws2 -Sql $sql | ConvertFrom-Json

        $out.success                          | Should -Be $true
        $out.row_count                        | Should -Be 0
        $out.PSObject.Properties.Name          | Should -Contain "columns"
        $out.PSObject.Properties.Name          | Should -Contain "rows"
        $out.PSObject.Properties.Name          | Should -Contain "pii"
        $out.pii.mode                          | Should -Be "off"
        $out.sql                               | Should -Match "'\?'"
        $out.sql                               | Should -Not -Match "12345678Z"
    }

    It "sin filas pero con cabecera: extrae los nombres de columna sin partir la linea por comas" {
        # Caso defensivo (Count -le 1 con Count -eq 1): sqlplus llega a emitir la cabecera
        # pero ninguna fila de datos.
        Mock -CommandName sqlplus -MockWith {
            $global:LASTEXITCODE = 0
            "IDDEUDOR,NOMBRE"
        }

        $out = & $script:hook -Workspace $script:ws2 -Sql "SELECT IDDEUDOR, NOMBRE FROM RDEUDORES WHERE 1=0" |
               ConvertFrom-Json

        $out.row_count | Should -Be 0
        $out.columns   | Should -Contain "IDDEUDOR"
        $out.columns   | Should -Contain "NOMBRE"
    }
}
