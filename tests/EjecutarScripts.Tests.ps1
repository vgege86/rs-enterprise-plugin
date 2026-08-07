<#
    Tests Pester de la plantilla de ejecucion de scripts SQL
    (assets/instalacion/Ejecutar-Scripts.ps1), la que viaja al cliente en el paquete de
    /rs-instalador y /rs-actualizador.

    El script se carga con -DotSourceOnly, que devuelve el control justo despues de definir
    las funciones puras y antes de tocar nada: asi se ejercitan los caminos de decision sin
    base de datos delante, que es donde han estado los fallos caros.

    Cada bloque corresponde a una cicatriz real, no a una hipotesis:
      - alias vs cadena de conexion  -> ORA-12154 que parece de red y no lo es
      - precedencia de NLS_LANG      -> acentos corruptos SIN error de Oracle
      - '?' en WALLET_LOCATION       -> ArgumentException que abortaba el pre-vuelo entero
      - manifiesto incompleto        -> entrega a medias detectada antes de conectar

    Ejecutar: Invoke-Pester tests/EjecutarScripts.Tests.ps1
#>

BeforeAll {
    $script:Plantilla = Join-Path (Split-Path -Parent $PSScriptRoot) "assets\instalacion\Ejecutar-Scripts.ps1"
    . $script:Plantilla -DotSourceOnly

    # Las helper van aqui y no en el cuerpo de los Describe: lo que se define en el cuerpo de
    # un Describe corre en la fase de Discovery y no existe cuando el It se ejecuta.
    function New-SqlPrueba([string]$Dir, [string]$Nombre) {
        $p = Join-Path $Dir $Nombre
        $padre = Split-Path $p -Parent
        if (!(Test-Path $padre)) { New-Item -ItemType Directory -Path $padre -Force | Out-Null }
        Set-Content -LiteralPath $p -Value "SELECT 1;" -Encoding UTF8
        return $p
    }

    function New-ManifiestoPrueba([string]$Dir, [string]$Json) {
        $p = Join-Path $Dir "scripts.json"
        Set-Content -LiteralPath $p -Value $Json -Encoding UTF8
        return $p
    }

    function New-DirPrueba([string]$Prefijo) {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefijo + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $d | Out-Null
        return $d
    }
}

Describe "Test-RsAliasTns: distingue un alias de una cadena de conexion" {

    It "acepta un alias normal de tnsnames.ora" {
        Test-RsAliasTns -Valor "RSALIAS" | Should -BeTrue
    }

    It "acepta un alias con punto (dominio TNS)" {
        Test-RsAliasTns -Valor "RSALIAS.MUNDO" | Should -BeTrue
    }

    It "rechaza un descriptor (DESCRIPTION=...)" {
        # Se parte por '/' y '@' en cuanto algo lo trocea -> ORA-12154 con pinta de fallo de red.
        Test-RsAliasTns -Valor "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCPS)(HOST=h)(PORT=2484)))" | Should -BeFalse
    }

    It "rechaza un EZConnect host:puerto/servicio" {
        Test-RsAliasTns -Valor "servidor:1521/SERVICIO" | Should -BeFalse
    }

    It "rechaza //host:puerto/servicio (la forma que trae hoy rutas.json por defecto)" {
        Test-RsAliasTns -Valor "//servidor:1521/SID" | Should -BeFalse
    }

    It "rechaza un valor con espacios o vacio" {
        Test-RsAliasTns -Valor "RS ALIAS" | Should -BeFalse
        Test-RsAliasTns -Valor ""         | Should -BeFalse
        Test-RsAliasTns -Valor "   "      | Should -BeFalse
    }
}

Describe "Resolve-RsNlsLang: precedencia -NlsLang > entorno > default" {

    It "el parametro gana sobre la variable de entorno" {
        $r = Resolve-RsNlsLang -Parametro "SPANISH_SPAIN.WE8MSWIN1252" -Entorno "AMERICAN_AMERICA.AL32UTF8"
        $r.valor  | Should -BeExactly "SPANISH_SPAIN.WE8MSWIN1252"
        $r.origen | Should -BeExactly "-NlsLang"
    }

    It "sin parametro, respeta el NLS_LANG del entorno en vez de pisarlo" {
        # El bug era justo este: se forzaba AL32UTF8 ignorando lo que el usuario tuviera puesto.
        $r = Resolve-RsNlsLang -Parametro "" -Entorno "SPANISH_SPAIN.WE8ISO8859P15"
        $r.valor  | Should -BeExactly "SPANISH_SPAIN.WE8ISO8859P15"
        $r.origen | Should -BeExactly "entorno"
    }

    It "sin parametro ni entorno, cae al default UTF-8" {
        $r = Resolve-RsNlsLang -Parametro "" -Entorno ""
        $r.valor  | Should -BeExactly "AMERICAN_AMERICA.AL32UTF8"
        $r.origen | Should -BeExactly "default del script"
    }

    It "reconoce como UTF-8 los valores que lo son, y solo esos" {
        Test-RsNlsUtf8 -Valor "AMERICAN_AMERICA.AL32UTF8"    | Should -BeTrue
        Test-RsNlsUtf8 -Valor "SPANISH_SPAIN.UTF8"           | Should -BeTrue
        Test-RsNlsUtf8 -Valor "SPANISH_SPAIN.WE8MSWIN1252"   | Should -BeFalse
    }
}

Describe "Resolve-RsWalletDir: el '?' de ORACLE_HOME no puede reventar el pre-vuelo" {

    It "expande '?' con ORACLE_HOME y deja la ruta comprobable" {
        $r = Resolve-RsWalletDir -Directory "?/network/admin" -OracleHome "C:\oracle\client"
        $r.ruta        | Should -BeExactly "C:\oracle\client\network\admin"
        $r.comprobable | Should -BeTrue
    }

    It "sin ORACLE_HOME, marca la ruta como NO comprobable en vez de lanzar" {
        # Test-Path sobre una ruta con '?' no devuelve $false: lanza ArgumentException y
        # abortaba el pre-vuelo entero. Aqui se degrada a aviso.
        $r = Resolve-RsWalletDir -Directory "?/network/admin" -OracleHome ""
        $r.comprobable | Should -BeFalse
    }

    It "una ruta con '?' sin expandir nunca llega a Test-Path" {
        $r = Resolve-RsWalletDir -Directory "?/network/admin" -OracleHome ""
        { if ($r.comprobable) { Test-Path $r.ruta } } | Should -Not -Throw
    }

    It "quita las comillas del valor de sqlnet.ora" {
        $r = Resolve-RsWalletDir -Directory '"C:\oracle\wallet"' -OracleHome ""
        $r.ruta        | Should -BeExactly "C:\oracle\wallet"
        $r.comprobable | Should -BeTrue
    }

    It "normaliza las barras a separador de Windows" {
        $r = Resolve-RsWalletDir -Directory "C:/oracle/wallet" -OracleHome ""
        $r.ruta | Should -BeExactly "C:\oracle\wallet"
    }

    It "un DIRECTORY vacio no revienta" {
        $r = Resolve-RsWalletDir -Directory "" -OracleHome ""
        $r.comprobable | Should -BeFalse
    }
}

Describe "Get-RsModoAutenticacion: como se decide wallet vs usuario" {

    It "-Usuario en linea de comandos manda sobre lo que diga rutas.json" {
        Get-RsModoAutenticacion -Declarado "wallet" -UsuarioParam "RSUSER" -UsuarioJson "" | Should -BeExactly "usuario"
    }

    It "reconoce las tres formas de declarar autenticacion externa" {
        foreach ($d in @("wallet", "externa", "integrada", "WALLET")) {
            Get-RsModoAutenticacion -Declarado $d -UsuarioParam "" -UsuarioJson "" | Should -BeExactly "externa"
        }
    }

    It "sin declarar y con usuario en rutas.json -> usuario (retrocompatible)" {
        # Los rutas.json ya entregados no tienen el campo 'autenticacion'.
        Get-RsModoAutenticacion -Declarado "" -UsuarioParam "" -UsuarioJson "RSUSER" | Should -BeExactly "usuario"
    }

    It "sin declarar y sin usuario -> externa" {
        Get-RsModoAutenticacion -Declarado "" -UsuarioParam "" -UsuarioJson "" | Should -BeExactly "externa"
    }
}

Describe "New-RsTempSql: el temporal va sin BOM" {

    It "no escribe BOM (con BOM sqlplus se come la primera sentencia)" {
        $f = New-RsTempSql -Lineas @("SELECT 1 FROM DUAL;")
        try {
            $bytes = [System.IO.File]::ReadAllBytes($f)
            $tieneBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            $tieneBom | Should -BeFalse
        } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
}

Describe "Get-RsCabeceraSqlPlus: los SET que evitan fallos silenciosos" {

    It "lleva WHENEVER SQLERROR y OSERROR EXIT FAILURE" {
        # Sin esto sqlplus devuelve 0 aunque el script falle, y la instalacion se da por buena.
        $c = Get-RsCabeceraSqlPlus
        $c | Should -Contain "WHENEVER SQLERROR EXIT FAILURE"
        $c | Should -Contain "WHENEVER OSERROR EXIT FAILURE"
    }

    It "lleva SET DEFINE OFF y SET SQLBLANKLINES ON" {
        $c = Get-RsCabeceraSqlPlus
        $c | Should -Contain "SET DEFINE OFF"        # un '&' en un texto no es una variable
        $c | Should -Contain "SET SQLBLANKLINES ON"  # un literal con lineas en blanco no se corta
    }
}

Describe "Get-RsScriptsManifiesto: el manifiesto manda, y avisa de lo que no cuadra" {

    BeforeEach {
        $script:dir = New-DirPrueba "rsman_"
    }
    AfterEach {
        if (Test-Path $script:dir) { Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "respeta el orden declarado, no el alfabetico" {
        New-SqlPrueba $script:dir "b.sql" | Out-Null
        New-SqlPrueba $script:dir "a.sql" | Out-Null
        $m = New-ManifiestoPrueba $script:dir '{ "scripts": [ { "ruta": "b.sql" }, { "ruta": "a.sql" } ] }'
        $r = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        $r.errores.Count | Should -Be 0
        @($r.scripts)[0].Name | Should -BeExactly "b.sql"
        @($r.scripts)[1].Name | Should -BeExactly "a.sql"
    }

    It "un script obligatorio ausente es ERROR, no un aviso" {
        # Una entrega incompleta no se empieza: mejor no conectar que dejar la BD a medias.
        $m = New-ManifiestoPrueba $script:dir '{ "scripts": [ { "ruta": "noexiste.sql" } ] }'
        $r = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        $r.errores.Count | Should -BeGreaterThan 0
        ($r.errores -join ' ') | Should -Match 'noexiste\.sql'
    }

    It "un script opcional ausente solo avisa y no bloquea" {
        $m = New-ManifiestoPrueba $script:dir '{ "scripts": [ { "ruta": "falta.sql", "opcional": true } ] }'
        $r = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        $r.errores.Count | Should -Be 0
        ($r.avisos -join ' ') | Should -Match 'falta\.sql'
    }

    It "un .sql en disco no declarado se avisa y NO se ejecuta" {
        New-SqlPrueba $script:dir "declarado.sql" | Out-Null
        New-SqlPrueba $script:dir "colado.sql"    | Out-Null
        $m = New-ManifiestoPrueba $script:dir '{ "scripts": [ { "ruta": "declarado.sql" } ] }'
        $r = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        @($r.scripts).Count | Should -Be 1
        @($r.scripts)[0].Name | Should -BeExactly "declarado.sql"
        ($r.avisos -join ' ') | Should -Match 'colado\.sql'
    }

    It "el filtro por entorno deja fuera la fila base de los demas entornos" {
        New-SqlPrueba $script:dir "99-RVERSIONES-PROD.sql" | Out-Null
        New-SqlPrueba $script:dir "99-RVERSIONES-TEST.sql" | Out-Null
        $m = New-ManifiestoPrueba $script:dir @'
{ "scripts": [
    { "ruta": "99-RVERSIONES-PROD.sql", "entorno": "PROD" },
    { "ruta": "99-RVERSIONES-TEST.sql", "entorno": "TEST" }
] }
'@
        $r = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        @($r.scripts).Count   | Should -Be 1
        @($r.scripts)[0].Name | Should -BeExactly "99-RVERSIONES-PROD.sql"
    }

    It "un declarado para otro entorno y ausente en disco no es error" {
        # Se filtra ANTES de comprobar la existencia: el paquete solo trae el del entorno.
        New-SqlPrueba $script:dir "99-RVERSIONES-PROD.sql" | Out-Null
        $m = New-ManifiestoPrueba $script:dir @'
{ "scripts": [
    { "ruta": "99-RVERSIONES-PROD.sql", "entorno": "PROD" },
    { "ruta": "99-RVERSIONES-TEST.sql", "entorno": "TEST" }
] }
'@
        $r = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        $r.errores.Count | Should -Be 0
    }

    It "la purga solo entra con -Recargar, y va la primera" {
        New-SqlPrueba $script:dir "datos.sql" | Out-Null
        New-SqlPrueba $script:dir "_PURGA.sql" | Out-Null
        $m = New-ManifiestoPrueba $script:dir '{ "scripts": [ { "ruta": "datos.sql" }, { "ruta": "_PURGA.sql", "purga": true } ] }'

        $sin = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        @($sin.scripts).Count   | Should -Be 1
        @($sin.scripts)[0].Name | Should -BeExactly "datos.sql"

        $con = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $true
        @($con.scripts).Count   | Should -Be 2
        @($con.scripts)[0].Name | Should -BeExactly "_PURGA.sql"
    }

    It "admite rutas con / en subcarpeta" {
        New-SqlPrueba $script:dir "Inserts\10-PARAM.sql" | Out-Null
        $m = New-ManifiestoPrueba $script:dir '{ "scripts": [ { "ruta": "Inserts/10-PARAM.sql" } ] }'
        $r = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        $r.errores.Count      | Should -Be 0
        @($r.scripts)[0].Name | Should -BeExactly "10-PARAM.sql"
    }

    It "ejecutar:false declara el fichero pero NO lo ejecuta, y no lo da por colado" {
        # Los maestros (<Proyecto>-CreacionObjetos.sql, Inserts\_run_all.sql) encadenan a los
        # demas: viajan en el paquete para poder lanzarlo todo a mano, pero ejecutarlos ADEMAS
        # crearia cada objeto y cada fila dos veces.
        New-SqlPrueba $script:dir "a.sql"       | Out-Null
        New-SqlPrueba $script:dir "maestro.sql" | Out-Null
        $m = New-ManifiestoPrueba $script:dir '{ "scripts": [ { "ruta": "a.sql" }, { "ruta": "maestro.sql", "ejecutar": false } ] }'
        $r = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        $r.errores.Count      | Should -Be 0
        @($r.scripts).Count   | Should -Be 1
        @($r.scripts)[0].Name | Should -BeExactly "a.sql"
        # Declarado => no puede salir como "presente en disco y NO declarado"
        ($r.avisos -join ' ') | Should -Not -Match 'maestro\.sql'
    }

    It "ejecutar:false ausente en disco no es una entrega incompleta" {
        # Nadie lo iba a lanzar, asi que su ausencia no puede abortar la instalacion.
        New-SqlPrueba $script:dir "a.sql" | Out-Null
        $m = New-ManifiestoPrueba $script:dir '{ "scripts": [ { "ruta": "a.sql" }, { "ruta": "nohay.sql", "ejecutar": false } ] }'
        $r = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        $r.errores.Count    | Should -Be 0
        @($r.scripts).Count | Should -Be 1
    }

    It "un declarado en subcarpeta no se avisa como no declarado" {
        # Regresion: las rutas declaradas se normalizan a '\' y las de disco traen el separador
        # del sistema. Sin normalizar los dos lados, TODA ruta con subcarpeta (Inserts\...,
        # PorEntorno\...) salia como "presente en disco y NO declarado" fuera de Windows —
        # justo las que genera el manifiesto de una instalacion limpia.
        New-SqlPrueba $script:dir "Inserts\RIDIOMAS.sql" | Out-Null
        $m = New-ManifiestoPrueba $script:dir '{ "scripts": [ { "ruta": "Inserts/RIDIOMAS.sql" } ] }'
        $r = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        @($r.scripts).Count   | Should -Be 1
        ($r.avisos -join ' ') | Should -Not -Match 'RIDIOMAS'
    }

    It "un scripts.json que no parsea es error, no una lista vacia silenciosa" {
        $m = New-ManifiestoPrueba $script:dir '{ esto no es json'
        $r = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        $r.errores.Count | Should -BeGreaterThan 0
    }

    It "un scripts.json sin la clave 'scripts' es error" {
        $m = New-ManifiestoPrueba $script:dir '{ "otra": [] }'
        $r = Get-RsScriptsManifiesto -RutaManifiesto $m -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        $r.errores.Count | Should -BeGreaterThan 0
    }
}

Describe "Get-RsScriptsConvencion: el comportamiento historico sigue intacto" {

    BeforeEach {
        $script:dir = New-DirPrueba "rsconv_"
    }
    AfterEach {
        if (Test-Path $script:dir) { Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "ordena raiz alfabeticamente, luego Inserts, luego la fila base del entorno" {
        New-SqlPrueba $script:dir "20-B.sql"
        New-SqlPrueba $script:dir "10-A.sql"
        New-SqlPrueba $script:dir "Inserts\30-PARAM.sql"
        New-SqlPrueba $script:dir "PorEntorno\99-RVERSIONES-PROD.sql"
        New-SqlPrueba $script:dir "PorEntorno\99-RVERSIONES-TEST.sql"

        $r = Get-RsScriptsConvencion -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        @($r.scripts | ForEach-Object { $_.Name }) | Should -Be @("10-A.sql","20-B.sql","30-PARAM.sql","99-RVERSIONES-PROD.sql")
    }

    It "ignora los ficheros que empiezan por '_' salvo _PURGA con -Recargar" {
        New-SqlPrueba $script:dir "10-A.sql"
        New-SqlPrueba $script:dir "_notas.sql"
        New-SqlPrueba $script:dir "_PURGA-TODO.sql"

        $sin = Get-RsScriptsConvencion -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        @($sin.scripts | ForEach-Object { $_.Name }) | Should -Be @("10-A.sql")

        $con = Get-RsScriptsConvencion -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $true
        @($con.scripts | ForEach-Object { $_.Name }) | Should -Be @("_PURGA-TODO.sql","10-A.sql")
    }

    It "avisa si falta la fila base de RVERSIONES del entorno" {
        New-SqlPrueba $script:dir "10-A.sql"
        New-SqlPrueba $script:dir "PorEntorno\99-RVERSIONES-TEST.sql"
        $r = Get-RsScriptsConvencion -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        ($r.avisos -join ' ') | Should -Match 'RVERSIONES'
    }

    It "una carpeta sin .sql devuelve lista vacia sin romper" {
        $r = Get-RsScriptsConvencion -DirScripts $script:dir -Entorno "PROD" -IncluirPurga $false
        @($r.scripts).Count | Should -Be 0
    }
}
