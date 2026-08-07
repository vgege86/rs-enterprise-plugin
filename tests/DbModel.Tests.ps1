<#
    Tests Pester de hooks/lib-dbmodel.ps1 — lo que le falta a una columna de model.json
    cuando `sync-from-db.ps1` / `sync-model-tables.ps1` la reconstruyen desde la BD.

    ⛔ Por qué existe este fichero. Los dos hooks NO actualizan la columna: la tiran y la
    escriben entera con lo que devuelve el diccionario de la BD. Todo lo que la BD no sabe
    decir y no se copie explícitamente se pierde, sin error y sin diff que lo delate — el
    model.json sigue siendo válido, solo que con menos información que ayer.

    Lo que se perdía era la política PII. Una columna marcada a mano con `pii: true` volvía a
    salir EN CLARO en las consultas después de cualquier resincronización del modelo, sin que
    nadie tocara nada. Es una regresión de seguridad silenciosa y reversible en un `git diff`
    que nadie mira, así que necesita un gate ejecutable y no un comentario.

    El caso que más fácil es volver a romper es `safe: false`: según references/json-schema.md
    equivale a `pii: true`, o sea que es la marca MÁS restrictiva, y su valor es falso. Una
    comprobación por verdad (`if ($col.safe)`) la daría por ausente y la borraría. Por eso la
    preservación va por PRESENCIA de la propiedad, y por eso hay un test dedicado.

    Nada aquí abre una conexión: New-RsColumnaModelo es una función pura.

    Ejecutar: Invoke-Pester tests/DbModel.Tests.ps1
#>

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) "hooks\lib-dbmodel.ps1")

    # El modelo real llega SIEMPRE de ConvertFrom-Json, no de un [PSCustomObject] literal:
    # el fixture se construye igual para que las propiedades sean las mismas NoteProperty
    # dinámicas que ve el hook en producción.
    function New-ColumnaJson([string]$Json) {
        return ($Json | ConvertFrom-Json)
    }
}

Describe "New-RsColumnaModelo: conserva lo que la BD no puede volver a decir" {

    Context "marcas manuales de la política PII" {

        It "conserva pii:true" {
            $vieja = New-ColumnaJson '{ "type":"VARCHAR2(100)","nullable":false,"pk":false,"description":"Nombre","source":"db","pii":true }'
            $nueva = New-RsColumnaModelo -Tipo "VARCHAR2(120)" -Nullable $false -PkPosicion 0 -Existente $vieja
            $nueva.PSObject.Properties.Name | Should -Contain 'pii'
            $nueva.pii | Should -BeTrue
        }

        It "conserva safe:true" {
            $vieja = New-ColumnaJson '{ "type":"VARCHAR2(2)","nullable":true,"pk":false,"description":"","source":"db","safe":true }'
            $nueva = New-RsColumnaModelo -Tipo "VARCHAR2(2)" -Nullable $true -PkPosicion 0 -Existente $vieja
            $nueva.safe | Should -BeTrue
        }

        It "conserva safe:false, que es la marca MAS restrictiva pese a valer falso" {
            # safe:false equivale a pii:true. Una comprobacion por verdad la borraria, y la
            # columna pasaria de enmascarada a en claro.
            $vieja = New-ColumnaJson '{ "type":"VARCHAR2(400)","nullable":true,"pk":false,"description":"","source":"db","safe":false }'
            $nueva = New-RsColumnaModelo -Tipo "VARCHAR2(400)" -Nullable $true -PkPosicion 0 -Existente $vieja
            $nueva.PSObject.Properties.Name | Should -Contain 'safe'
            $nueva.safe | Should -BeFalse
        }

        It "conserva pii:false sin convertirlo en ausencia" {
            $vieja = New-ColumnaJson '{ "type":"NUMBER(10)","nullable":false,"pk":false,"description":"","source":"db","pii":false }'
            $nueva = New-RsColumnaModelo -Tipo "NUMBER(10)" -Nullable $false -PkPosicion 0 -Existente $vieja
            $nueva.PSObject.Properties.Name | Should -Contain 'pii'
            $nueva.pii | Should -BeFalse
        }

        It "no se inventa marcas donde no las habia" {
            $vieja = New-ColumnaJson '{ "type":"NUMBER(10)","nullable":false,"pk":true,"description":"Id","source":"db" }'
            $nueva = New-RsColumnaModelo -Tipo "NUMBER(10)" -Nullable $false -PkPosicion 1 -Existente $vieja
            $nueva.PSObject.Properties.Name | Should -Not -Contain 'pii'
            $nueva.PSObject.Properties.Name | Should -Not -Contain 'safe'
        }
    }

    Context "descripcion semantica" {

        It "conserva la description escrita a mano" {
            $vieja = New-ColumnaJson '{ "type":"VARCHAR2(100)","nullable":true,"pk":false,"description":"Razon social del cliente","source":"db" }'
            $nueva = New-RsColumnaModelo -Tipo "VARCHAR2(100)" -Nullable $true -PkPosicion 0 -Existente $vieja
            $nueva.description | Should -BeExactly "Razon social del cliente"
        }

        It "una columna que no estaba en el modelo entra con description vacia, no con null" {
            $nueva = New-RsColumnaModelo -Tipo "DATE" -Nullable $true -PkPosicion 0 -Existente $null
            $nueva.description | Should -BeExactly ""
            $nueva.source      | Should -BeExactly "db"
        }

        It "una columna vieja sin la clave description no revienta" {
            # Modelos antiguos escritos a mano pueden no traerla.
            $vieja = New-ColumnaJson '{ "type":"DATE","nullable":true,"pk":false }'
            { New-RsColumnaModelo -Tipo "DATE" -Nullable $true -PkPosicion 0 -Existente $vieja } | Should -Not -Throw
            (New-RsColumnaModelo -Tipo "DATE" -Nullable $true -PkPosicion 0 -Existente $vieja).description | Should -BeExactly ""
        }
    }

    Context "lo que SI manda la BD" {

        It "el tipo, el nullable y el pk se toman de la BD, no del modelo viejo" {
            # Si no, un ALTER TABLE aplicado en BD nunca llegaria al modelo.
            $vieja = New-ColumnaJson '{ "type":"VARCHAR2(100)","nullable":true,"pk":false,"description":"x","source":"db","pii":true }'
            $nueva = New-RsColumnaModelo -Tipo "VARCHAR2(250)" -Nullable $false -PkPosicion 1 -Existente $vieja
            $nueva.type     | Should -BeExactly "VARCHAR2(250)"
            $nueva.nullable | Should -BeFalse
            $nueva.pk       | Should -Be 1
            $nueva.pii      | Should -BeTrue   # la marca sobrevive al cambio de tipo
        }

        It "el campo default NO se arrastra del modelo viejo" {
            # Lo reescribe despues Get-RsColumnDefaults con lo que diga la BD: arrastrarlo aqui
            # dejaria un default fantasma cuando se hubiera quitado en BD.
            $vieja = New-ColumnaJson '{ "type":"CHAR(1)","nullable":false,"pk":false,"description":"","source":"db","default":"''A''" }'
            $nueva = New-RsColumnaModelo -Tipo "CHAR(1)" -Nullable $false -PkPosicion 0 -Existente $vieja
            $nueva.PSObject.Properties.Name | Should -Not -Contain 'default'
        }
    }

    Context "posicion dentro de la clave primaria" {

        It "escribe el ORDINAL, no un booleano, tambien con PK de una sola columna" {
            # Uniforme o nada: pk_columns solo ordena si detecta ordinales y trata `true` como
            # ordinal 0, asi que mezclar las dos formas dentro de una tabla ordena AL REVES.
            $nueva = New-RsColumnaModelo -Tipo "NUMBER(10)" -Nullable $false -PkPosicion 1 -Existente $null
            $nueva.pk | Should -Be 1
            $nueva.pk | Should -Not -BeOfType [bool]
        }

        It "conserva la posicion real cuando no coincide con el orden de la tabla" {
            # Es el caso que se perdia: la PK es (B, A) pero en la tabla A va antes que B.
            $a = New-RsColumnaModelo -Tipo "VARCHAR2(4)" -Nullable $false -PkPosicion 2 -Existente $null
            $b = New-RsColumnaModelo -Tipo "NUMBER(6)"   -Nullable $false -PkPosicion 1 -Existente $null
            $a.pk | Should -Be 2
            $b.pk | Should -Be 1
        }

        It "una columna que no es PK sale con false, no con 0" {
            # `0` es truthy en algunos consumidores del modelo (y en el HTML del ERD se
            # renderiza); false es lo que ya esperaban todos.
            $nueva = New-RsColumnaModelo -Tipo "DATE" -Nullable $true -PkPosicion 0 -Existente $null
            $nueva.pk | Should -BeFalse
            $nueva.pk | Should -BeOfType [bool]
        }

        It "la posicion la manda la BD: un ordinal viejo del modelo no se arrastra" {
            $vieja = New-ColumnaJson '{ "type":"NUMBER(10)","nullable":false,"pk":3,"description":"","source":"db" }'
            $nueva = New-RsColumnaModelo -Tipo "NUMBER(10)" -Nullable $false -PkPosicion 1 -Existente $vieja
            $nueva.pk | Should -Be 1
        }

        It "una columna que dejo de ser PK en BD pierde la marca" {
            $vieja = New-ColumnaJson '{ "type":"NUMBER(10)","nullable":false,"pk":2,"description":"","source":"db" }'
            $nueva = New-RsColumnaModelo -Tipo "NUMBER(10)" -Nullable $false -PkPosicion 0 -Existente $vieja
            $nueva.pk | Should -BeFalse
        }
    }

    Context "ConvertTo-RsPkPosicion" {

        It "convierte el texto que devuelve el SELECT" {
            ConvertTo-RsPkPosicion "1"    | Should -Be 1
            ConvertTo-RsPkPosicion "  2 " | Should -Be 2
        }

        It "0 y vacio son 'no es PK'" {
            ConvertTo-RsPkPosicion "0" | Should -Be 0
            ConvertTo-RsPkPosicion ""  | Should -Be 0
        }

        It "basura devuelve 0, nunca un ordinal inventado" {
            # Escribir un ordinal falso reordenaria el indice de la PK en el DDL entregado al
            # cliente. Perder la marca es menos malo y ademas se ve.
            ConvertTo-RsPkPosicion "N"    | Should -Be 0
            ConvertTo-RsPkPosicion "-1"   | Should -Be 0
            ConvertTo-RsPkPosicion "IS_PK"| Should -Be 0
        }
    }

    Context "aislamiento" {

        It "devuelve un objeto nuevo y no muta el anterior" {
            $vieja = New-ColumnaJson '{ "type":"VARCHAR2(100)","nullable":true,"pk":false,"description":"orig","source":"db","pii":true }'
            $nueva = New-RsColumnaModelo -Tipo "VARCHAR2(9)" -Nullable $false -PkPosicion 1 -Existente $vieja
            $vieja.type        | Should -BeExactly "VARCHAR2(100)"
            $vieja.nullable    | Should -BeTrue
            [object]::ReferenceEquals($vieja, $nueva) | Should -BeFalse
        }
    }
}

Describe "ConvertTo-RsDefaultsMap: parsea la salida marcada de los dos motores" {

    It "solo se queda con las lineas marcadas y descarta el banner y el ruido" {
        $m = ConvertTo-RsDefaultsMap -Lineas @(
            "SQL*Plus: Release 19.0.0.0.0 - Production",
            "##DEF##RCLIENTES|ESTADO|'A'",
            "",
            "PL/SQL procedure successfully completed."
        )
        $m.Count            | Should -Be 1
        $m["RCLIENTES.ESTADO"] | Should -BeExactly "'A'"
    }

    It "DEFAULT NULL no es un default: equivale a no tener ninguno" {
        $m = ConvertTo-RsDefaultsMap -Lineas @("##DEF##T|C|NULL")
        $m.Count | Should -Be 0
    }

    It "una expresion con '|' dentro no se trocea" {
        # El troceo es a 3 campos como maximo; el resto se queda entero en el ultimo.
        $m = ConvertTo-RsDefaultsMap -Lineas @("##DEF##T|C|'A|B'")
        $m["T.C"] | Should -BeExactly "'A|B'"
    }

    It "0 es un default real y no una ausencia" {
        $m = ConvertTo-RsDefaultsMap -Lineas @("##DEF##T|SALDO|0")
        $m["T.SALDO"] | Should -BeExactly "0"
    }
}
