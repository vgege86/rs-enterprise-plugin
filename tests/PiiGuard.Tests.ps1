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
        # El CLI ya NO busca el modelo con un glob de BD/*-model.json: la ruta se la pasa el
        # llamante (hooks/lib-dbconfig.ps1 Get-RsModelPath), que es la misma que resuelve
        # get-config.ps1 -> config["model_path"] para la tool MCP.
        $script:modelo = Join-Path $bd "Proyecto-model.json"
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
'@ | Set-Content $script:modelo -Encoding UTF8
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

        $salida = $entrada | python $script:cli $script:ws $script:modelo | ConvertFrom-Json
        $salida.rows[0][0] | Should -Be "1024"
        $salida.rows[0][1] | Should -Match "^pii:[0-9a-f]{12}$"
        $salida.pii.masked | Should -Contain "NOMBRE"
    }

    It "no toca nada si el workspace no tiene modelo configurado" {
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

    It "aplica la politica de un modelo cuyo nombre no casaria un glob *-model.json" {
        # La resolucion por glob de BD/*-model.json ignoraba el campo "model" de la conexion:
        # con "model": "BD/uCollect-v2.json" el glob no encontraba nada y el CLI devolvia
        # mode=off -- indistinguible de un workspace sin politica -- mientras la tool MCP,
        # que si usa model_path, enmascaraba.
        $bd2 = Join-Path $script:ws "BD"
        $raro = Join-Path $bd2 "uCollect-v2.json"
        Copy-Item $script:modelo $raro -Force

        $entrada = @{
            columns = @("NOMBRE")
            rows    = @(, @("Ana Lopez"))
            sql     = "SELECT NOMBRE FROM RDEUDORES"
        } | ConvertTo-Json -Depth 5 -Compress

        $salida = $entrada | python $script:cli $script:ws $raro | ConvertFrom-Json
        $salida.pii.mode   | Should -Be "enforce"
        $salida.rows[0][0] | Should -Match "^pii:[0-9a-f]{12}$"
    }

    It "sale con codigo de fallo interno si la entrada no es JSON (no emite datos)" {
        $salida = "no es json" | python $script:cli $script:ws $script:modelo 2>$null
        $LASTEXITCODE | Should -Not -Be 0
        $salida        | Should -BeNullOrEmpty
    }

    It "sale con error si el modelo configurado no existe (no lo trata como ausencia de modelo)" {
        # Una politica declarada que no se puede cargar NO puede reportarse como "no hay
        # politica": seria mode=off silencioso sobre un workspace que cree estar protegido.
        $entrada = @{
            columns = @("NOMBRE")
            rows    = @(, @("Ana Lopez"))
            sql     = "SELECT NOMBRE FROM RDEUDORES"
        } | ConvertTo-Json -Depth 5 -Compress

        $null = $entrada | python $script:cli $script:ws (Join-Path $script:ws "BD\no-existe.json") 2>$null
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

        $null = $entrada | python $script:cli $wsModeloRoto (Join-Path $bdRoto "Roto-model.json") 2>$null
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

        $null = $entrada | python $script:cli $wsModeloLista (Join-Path $bdLista "Lista-model.json") 2>$null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It "un modelo con tables en forma de LISTA se enmascara igual que en forma de dict" {
        # Las dos formas son reales en este codebase (rs-workspace-server.py las normaliza
        # en seis sitios). Antes reventaba con AttributeError: la tool MCP se caia y el hook
        # devolvia todas las filas en claro por su rama de fallo abierto.
        $wsLista = Join-Path $TestDrive "modelo-forma-lista"
        $bdL = Join-Path $wsLista "BD"
        New-Item -ItemType Directory -Path $bdL -Force | Out-Null
        $mL = Join-Path $bdL "Lista-model.json"
        @'
{
  "pii_policy": { "mode": "enforce" },
  "tables": [
    { "name": "RDEUDORES", "columns": [
      { "name": "IDDEUDOR", "type": "NUMBER(10)", "pk": true },
      { "name": "NOMBRE",   "type": "VARCHAR2(60)" }
    ]}
  ]
}
'@ | Set-Content $mL -Encoding UTF8

        $entrada = @{
            columns = @("IDDEUDOR", "NOMBRE")
            rows    = @(, @("1024", "Ana Lopez"))
            sql     = "SELECT IDDEUDOR, NOMBRE FROM RDEUDORES"
        } | ConvertTo-Json -Depth 5 -Compress

        $salida = $entrada | python $script:cli $wsLista $mL | ConvertFrom-Json
        $LASTEXITCODE      | Should -Be 0
        $salida.rows[0][0] | Should -Be "1024"
        $salida.rows[0][1] | Should -Match "^pii:[0-9a-f]{12}$"
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

    It "sin filas: el bloque pii tiene las mismas claves que el camino con filas" {
        # Emitia solo {mode, reason} con mode="off" fijo, asi que un workspace en enforce
        # reportaba "off" en cuanto una consulta no devolvia filas. Ahora el modo sale de
        # la misma politica que el camino con filas (pii_cli con resultset vacio).
        Mock -CommandName sqlplus -MockWith { $global:LASTEXITCODE = 0 }

        $out = & $script:hook -Workspace $script:ws2 -Sql "SELECT NOMBRE FROM RDEUDORES" | ConvertFrom-Json
        $claves = @($out.pii.PSObject.Properties.Name)
        foreach ($k in @("mode", "masked", "unresolved", "suspect", "predicate_warning", "tables")) {
            $claves | Should -Contain $k
        }
    }
}

Describe "db-query.ps1 camino CON filas (integracion PII)" {
    <#
        sqlplus mockeado emitiendo CSV real: cabecera + filas. Cubre lo que hasta ahora no
        tenia ninguna cobertura Pester -- extraccion de cabeceras, construccion de la matriz,
        invocacion de pii_cli con el model_path de la conexion SELECCIONADA, y las dos ramas
        de fallo (abierto vs cerrado).
    #>
    BeforeAll {
        $script:hook3 = Join-Path $PSScriptRoot ".." "hooks" "db-query.ps1"

        # Workspace con politica enforce y un modelo cuyo NOMBRE no casaria "*-model.json":
        # fija de paso que la resolucion va por el campo "model" de la conexion, no por glob.
        $script:ws3 = Join-Path $TestDrive "trunk-confilas"
        $docs3      = Join-Path $script:ws3 "docs"
        $bd3        = Join-Path $script:ws3 "BD"
        New-Item -ItemType Directory -Path $docs3 -Force | Out-Null
        New-Item -ItemType Directory -Path $bd3 -Force | Out-Null
        @'
{
  "proyecto": "Proyecto",
  "conexiones": [
    { "id": "desa", "motor": "ORACLE", "cadena": "Data Source=XE;User Id=u;Password=p" },
    { "id": "prod", "motor": "ORACLE", "cadena": "Data Source=XP;User Id=u;Password=p", "model": "BD/uCollect-v2.json" }
  ]
}
'@ | Set-Content (Join-Path $docs3 ".rs-databases.json") -Encoding UTF8
        @'
{
  "pii_policy": { "mode": "enforce" },
  "tables": {
    "RDEUDORES": { "columns": {
      "IDDEUDOR": { "type": "NUMBER(10)", "pk": true },
      "NOMBRE":   { "type": "VARCHAR2(60)" }
    }}
  }
}
'@ | Set-Content (Join-Path $bd3 "uCollect-v2.json") -Encoding UTF8

        # Workspace cuyo modelo declarado esta CORRUPTO: pii_cli corre y falla.
        $script:ws4 = Join-Path $TestDrive "trunk-modelo-roto"
        $docs4      = Join-Path $script:ws4 "docs"
        $bd4        = Join-Path $script:ws4 "BD"
        New-Item -ItemType Directory -Path $docs4 -Force | Out-Null
        New-Item -ItemType Directory -Path $bd4 -Force | Out-Null
        @'
{
  "proyecto": "Roto",
  "conexiones": [
    { "id": "principal", "motor": "ORACLE", "cadena": "Data Source=XE;User Id=u;Password=p", "model": "BD/Roto.json" }
  ]
}
'@ | Set-Content (Join-Path $docs4 ".rs-databases.json") -Encoding UTF8
        "{ esto no es json" | Set-Content (Join-Path $bd4 "Roto.json") -Encoding UTF8
    }

    It "enmascara las filas usando el modelo de la conexion seleccionada" {
        Mock -CommandName sqlplus -MockWith {
            $global:LASTEXITCODE = 0
            "IDDEUDOR,NOMBRE"
            "1024,`"Ana Lopez`""
            "1025,`"Luis Gomez`""
        }

        $out = & $script:hook3 -Workspace $script:ws3 -Conexion "prod" `
                    -Sql "SELECT IDDEUDOR, NOMBRE FROM RDEUDORES" | ConvertFrom-Json

        $out.success       | Should -Be $true
        $out.row_count     | Should -Be 2
        $out.columns       | Should -Contain "NOMBRE"
        $out.pii.mode      | Should -Be "enforce"
        $out.pii.masked    | Should -Contain "NOMBRE"
        $out.rows[0][0]    | Should -Be "1024"
        $out.rows[0][1]    | Should -Match "^pii:[0-9a-f]{12}$"
        $out.rows[1][1]    | Should -Match "^pii:[0-9a-f]{12}$"
        ($out | ConvertTo-Json -Depth 6) | Should -Not -Match "Ana Lopez"
    }

    It "si pii_cli corre y falla NO devuelve filas (fallo cerrado)" {
        # Antes cualquier salida != 0 de pii_cli caia en la rama de fallo abierto y devolvia
        # las filas EN CLARO con pii.mode = "error". El fallo abierto solo es legitimo cuando
        # el filtro no se puede ni ejecutar; si corrio y fallo, tenia los datos en la mano.
        Mock -CommandName sqlplus -MockWith {
            $global:LASTEXITCODE = 0
            "IDDEUDOR,NOMBRE"
            "1024,`"Ana Lopez`""
        }

        $out = & $script:hook3 -Workspace $script:ws4 -Sql "SELECT IDDEUDOR, NOMBRE FROM RDEUDORES" |
               ConvertFrom-Json

        $out.success   | Should -Be $false
        $out.row_count | Should -Be 0
        @($out.rows).Count | Should -Be 0
        $out.pii.error | Should -Not -BeNullOrEmpty
        ($out | ConvertTo-Json -Depth 6) | Should -Not -Match "Ana Lopez"
    }

    It "un error de sqlplus a mitad de volcado no devuelve las filas ya emitidas como error" {
        # sqlplus emite las filas segun las trae; un ORA- a mitad de fetch deja datos en lo
        # capturado. La rama de error NO pasa por el enmascarado, asi que volcar la salida
        # entera metia esas filas en el contexto en claro. Ademas el filtro anterior
        # ('ORA-|SP2-|ERROR', sin anclar) casaba con la palabra "error" DENTRO de los datos.
        Mock -CommandName sqlplus -MockWith {
            $global:LASTEXITCODE = 1
            "IDINCIDENCIA,DESCRIPCION,DNI"
            "1,`"error al cobrar`",12345678Z"
            "2,`"ERROR de conexion`",87654321X"
            "ORA-01555: snapshot too old"
        }

        $out = & $script:hook3 -Workspace $script:ws3 `
                    -Sql "SELECT IDINCIDENCIA, DESCRIPCION, DNI FROM RINCIDENCIAS" | ConvertFrom-Json

        $out.success | Should -Be $false
        $out.error   | Should -Match "ORA-01555"
        $out.error   | Should -Not -Match "12345678Z"
        $out.error   | Should -Not -Match "87654321X"
        $out.error   | Should -Not -Match "al cobrar"
    }

    It "un error sin lineas de diagnostico devuelve un mensaje fijo, no la salida capturada" {
        Mock -CommandName sqlplus -MockWith {
            $global:LASTEXITCODE = 1
            "IDDEUDOR,DNI"
            "1024,12345678Z"
        }

        $out = & $script:hook3 -Workspace $script:ws3 -Sql "SELECT IDDEUDOR, DNI FROM RDEUDORES" |
               ConvertFrom-Json

        $out.success | Should -Be $false
        $out.error   | Should -Match "sin lineas de diagnostico"
        $out.error   | Should -Not -Match "12345678Z"
    }
}

Describe "pii-guard-bash.ps1" {
    BeforeAll { $script:g = Join-Path $PSScriptRoot ".." "hooks" "pii-guard-bash.ps1" }

    It "bloquea sqlplus" {
        '{"tool_input":{"command":"sqlplus -S user/pass@DS @x.sql"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    It "bloquea sqlcmd" {
        '{"tool_input":{"command":"sqlcmd -S srv -Q \"SELECT 1\""}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    It "permite comandos normales" {
        '{"tool_input":{"command":"dotnet build MiSolucion.sln"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It "permite los scripts del propio plugin que usan sqlplus por dentro" {
        '{"tool_input":{"command":"python installer-inserts.py C:\\ws Proy out"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It "permite un evento no parseable (JSON invalido)" {
        'esto no es json' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It "el mensaje de bloqueo no contiene la contrasena del comando (solo nombra el cliente)" {
        # Pin explicito: si alguien "mejora" el diagnostico volviendo a incluir el
        # comando completo, esta comprobacion revienta. El comando de un cliente de BD
        # lleva casi siempre la credencial inline (sqlplus -S usuario/contrasena@ORCL),
        # y el mensaje de bloqueo es texto visible/logueable -- no debe llevarla.
        # Se inspecciona el ErrorRecord (2>&1) directamente, no via Out-String: el host
        # de PowerShell añade contexto "Line |" con la linea de codigo que invoco el
        # pipeline (aqui, la propia linea del test) al formatear para consola, que no
        # es el mensaje del guard y ensuciaria la comprobacion con el mismo secreto.
        $salida = '{"tool_input":{"command":"sqlplus -S usuario/contrasena@ORCL"}}' | & $script:g 2>&1
        $LASTEXITCODE | Should -Be 2
        $mensaje = [string]$salida
        $mensaje | Should -Not -Match "contrasena"
        $mensaje | Should -Match "sqlplus"
    }
}

Describe "pii-guard-write.ps1" {
    <#
        El brief original (task-7-brief.md) reutilizaba las 6 formas del detector de
        columnas (scripts/pii_detect.py), incluyendo telefono y tarjeta. Superseded por
        el dispatch de la Task 7: para una guarda de ESCRITURA esas dos formas son
        puramente numericas y disparan sobre cualquier importe en centimos o id largo,
        asi que se han retirado aqui (pii_detect.py sigue intacto, no se toca). DNI/NIE
        ademas exigen letra de control valida -- sin eso, cualquier fecha AAAAMMDD del
        repo (convencion Actualizador\<ENTORNO>_<AAAAMMDD>) dispara la guarda.
    #>
    BeforeAll { $script:g = Join-Path $PSScriptRoot ".." "hooks" "pii-guard-write.ps1" }

    It "bloquea contenido con DNI de letra de control valida" {
        # 12345678Z: 12345678 % 23 = 14 -> "TRWAGMYFPDXBNJZSQVHLCKE"[14] = "Z". Valido.
        '{"tool_input":{"file_path":"C:\\x\\a.md","content":"El deudor 12345678Z debe 300"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    It "NO bloquea el mismo numero de DNI con letra de control incorrecta" {
        # 12345678A: la letra correcta es Z, no A. Misma forma, checksum invalido.
        '{"tool_input":{"file_path":"C:\\x\\a.md","content":"El deudor 12345678A debe 300"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It "NO bloquea una fecha AAAAMMDD seguida de letra (falso positivo tipico del repo)" {
        # 20260803 % 23 = ... letra correcta es "B", no "A": no cuela como DNI valido.
        '{"tool_input":{"file_path":"C:\\x\\a.md","content":"Entrega 20260803A generada por el hook"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It "bloquea contenido con NIE de letra de control valida" {
        # X1234567L: X->0, 01234567 % 23 -> "L". Valido (ejemplo clasico de NIE).
        '{"tool_input":{"file_path":"C:\\x\\a.md","content":"Cliente extranjero X1234567L"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    It "NO bloquea un NIE con letra de control incorrecta" {
        '{"tool_input":{"file_path":"C:\\x\\a.md","content":"Cliente extranjero X1234567A"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It "bloquea contenido con IBAN" {
        '{"tool_input":{"file_path":"C:\\x\\a.md","content":"ES9121000418450200051332"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    It "bloquea contenido con correo electronico" {
        '{"tool_input":{"file_path":"C:\\x\\a.md","content":"Contacto: ana.lopez@example.com"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    It "permite contenido sin datos personales" {
        '{"tool_input":{"file_path":"C:\\x\\a.md","content":"SELECT COUNT(*) FROM RDEUDORES"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It "permite un importe largo sin forma de DNI/NIE/IBAN/correo (telefono y tarjeta fuera de esta guarda)" {
        '{"tool_input":{"file_path":"C:\\x\\a.md","content":"Total acumulado: 1234567890123456 centimos"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It "permite escribir en la carpeta del instalador" {
        '{"tool_input":{"file_path":"C:\\AIS\\Proy\\Instalador\\Scripts\\Inserts\\x.sql","content":"12345678Z"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It "permite escribir en la carpeta del actualizador" {
        '{"tool_input":{"file_path":"C:\\AIS\\Proy\\Actualizador\\DESA_20260803\\Scripts\\x.sql","content":"12345678Z"}}' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It "permite un evento no parseable (JSON invalido)" {
        'esto no es json' | & $script:g | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe "log-execution.ps1 saneado de PII" {
    <#
        Se conduce a traves del propio hook (no llamando a Remove-RsPii aislada) para
        cubrir el camino real: parseo de parametros, lectura/escritura de
        executions/history.json y la funcion compartida en conjunto. Cada It usa su
        propia subcarpeta de $TestDrive para que el history.json de una prueba no
        arrastre entradas de otra (ConvertTo-Json colapsa un array de 1 elemento a un
        objeto plano, asi que leer "el ultimo task" en un fichero compartido seria
        fragil).
    #>
    BeforeAll { $script:hookLog = Join-Path $PSScriptRoot ".." "hooks" "log-execution.ps1" }

    It "no persiste un DNI en el campo task" {
        $ws = Join-Path $TestDrive "wslog"
        New-Item -ItemType Directory -Path $ws -Force | Out-Null

        & $script:hookLog $ws "Mi.sln" "revisar el deudor 12345678Z" -Status success | Out-Null

        $historia = Get-Content (Join-Path $ws "executions" "history.json") -Raw
        $historia | Should -Not -Match "12345678Z"
        $historia | Should -Match "\[PII\]"
    }

    It "no altera una carpeta de entrega PROD_20260803A (falso positivo tipico del repo)" {
        # Motivo original de retirar el patron de telefono y exigir checksum: esta
        # convencion Actualizador\<ENTORNO>_<AAAAMMDD> no debe acabar enmascarada.
        $ws = Join-Path $TestDrive "wslog-entrega-prefijo"
        New-Item -ItemType Directory -Path $ws -Force | Out-Null
        $texto = "genera el paquete en PROD_20260803A y avisa"

        & $script:hookLog $ws "Mi.sln" $texto -Status success | Out-Null

        $entrada = Get-Content (Join-Path $ws "executions" "history.json") -Raw | ConvertFrom-Json
        $entrada.task | Should -Be $texto
    }

    It "no altera un 20260803A suelto sin prefijo (limite de palabra distinto)" {
        $ws = Join-Path $TestDrive "wslog-entrega-suelto"
        New-Item -ItemType Directory -Path $ws -Force | Out-Null
        $texto = "carpeta 20260803A generada"

        & $script:hookLog $ws "Mi.sln" $texto -Status success | Out-Null

        $entrada = Get-Content (Join-Path $ws "executions" "history.json") -Raw | ConvertFrom-Json
        $entrada.task | Should -Be $texto
    }

    It "no altera un numero de 8 digitos con letra de control incorrecta (el checksum descarta, no la forma)" {
        # 12345678A: la letra correcta es Z, no A (mismo caso que el guard de escritura).
        $ws = Join-Path $TestDrive "wslog-checksum-invalido"
        New-Item -ItemType Directory -Path $ws -Force | Out-Null
        $texto = "referencia 12345678A revisada, no coincide con ningun deudor"

        & $script:hookLog $ws "Mi.sln" $texto -Status success | Out-Null

        $entrada = Get-Content (Join-Path $ws "executions" "history.json") -Raw | ConvertFrom-Json
        $entrada.task | Should -Be $texto
    }

    It "no altera un numero de 9 digitos con forma de telefono/importe (patron retirado, no debe reaparecer)" {
        # 987654321 casaria con el patron de telefono retirado ('\b(?:+34)?[6789]\d{8}\b'):
        # empieza por 9 y tiene 8 digitos mas. Pin de que ese patron sigue fuera.
        $ws = Join-Path $TestDrive "wslog-importe"
        New-Item -ItemType Directory -Path $ws -Force | Out-Null
        $texto = "importe acumulado 987654321 centimos"

        & $script:hookLog $ws "Mi.sln" $texto -Status success | Out-Null

        $entrada = Get-Content (Join-Path $ws "executions" "history.json") -Raw | ConvertFrom-Json
        $entrada.task | Should -Be $texto
    }
}

Describe "check-env.ps1 verificacion de guardas" {
    It "informa del estado de las guardas PII" {
        $ws  = Join-Path $TestDrive "wsenv"
        New-Item -ItemType Directory -Path $ws -Force | Out-Null
        $out = & (Join-Path $PSScriptRoot ".." "hooks" "check-env.ps1") $ws "ProyectoPrueba" | ConvertFrom-Json
        $out.pii | Should -Not -BeNullOrEmpty
        $out.pii.PSObject.Properties.Name | Should -Contain "guards_registered"
    }
}
