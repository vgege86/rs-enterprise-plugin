<#
    Tests Pester de la utilidad de vaciado de esquema (assets/utilidades/Purgar-Esquema.ps1) y
    de la coherencia de la declaracion de conexion que el paquete copia al cliente
    (hooks/instalacion-paquete.ps1).

    Los dos scripts se cargan con -DotSourceOnly, que devuelve el control justo despues de
    definir las funciones puras y antes de tocar nada: asi se ejercitan los caminos de decision
    sin base de datos delante.

    ⛔ POR QUE ESTE FICHERO PESA MAS QUE LA UTILIDAD QUE PRUEBA

    Purgar-Esquema.ps1 borra todos los objetos de un esquema y no tiene vuelta atras. Sus tres
    salvaguardas -leer USER_* siendo el dueno, ensenar cuantas tablas tienen datos, y exigir que
    se teclee el nombre- solo valen si funcionan; una salvaguarda que nadie comprueba es una
    promesa. Lo unico que se puede probar sin una BD delante es la DECISION, y la decision es
    justamente donde estan los fallos que importan aqui.

    Cada bloque corresponde a una cicatriz real, no a una hipotesis:
      - "sin declaracion -> wallet"      -> el bug de Ejecutar-Scripts.ps1 (ORA-01017 sin ofrecer
                                            nunca usuario/contrasena), que esta utilidad habia
                                            reintroducido tal cual en su resolucion de modo
      - inventario que no se lee         -> "el esquema ya esta vacio" sobre un esquema del que
                                            no llego una sola fila
      - indices sumados al total         -> "se van a borrar 900 objetos" sobre 300 tablas
      - 'BIN$' interpolado por PowerShell -> el patron de la papelera llegaba roto a Oracle
      - wallet + usuario en rutas.json   -> declaracion contradictoria que solo se descubria en
                                            el servidor del cliente

    Ejecutar: Invoke-Pester tests/PurgarEsquema.Tests.ps1
#>

BeforeAll {
    $script:Raiz    = Split-Path -Parent $PSScriptRoot
    $script:Purga   = Join-Path $script:Raiz "assets\utilidades\Purgar-Esquema.ps1"
    $script:Paquete = Join-Path $script:Raiz "hooks\instalacion-paquete.ps1"

    . $script:Purga -DotSourceOnly
    # instalacion-paquete.ps1 declara workspace/destino/modo como obligatorios, asi que hay que
    # darles algo aunque -DotSourceOnly devuelva el control antes de mirarlos: sin valor,
    # PowerShell los pediria por consola y el test se colgaria en vez de fallar.
    . $script:Paquete -workspace 'x' -destino 'x' -modo 'Instalacion' -DotSourceOnly

    # ConvertTo-SecureString depende de Microsoft.PowerShell.Security, que no siempre autocarga
    # en una sesion restringida. Construirla a mano no depende de ningun modulo.
    function New-SecureStringPrueba([string]$Texto) {
        $s = New-Object Security.SecureString
        foreach ($c in $Texto.ToCharArray()) { $s.AppendChar($c) }
        $s.MakeReadOnly()
        return $s
    }

    function New-BdPrueba([hashtable]$Campos) { return [pscustomobject]$Campos }
}

Describe "Get-RsModoAuthPurga: no supone wallet sin haberlo mirado" {

    It "sin 'autenticacion' y sin 'usuario' devuelve indeterminado, NO externa" {
        # ⛔ La regresion que este test fija. Devolver 'externa' aqui es afirmar que hay wallet
        # sin evidencia: el connect sale como '/@alias', Oracle contesta ORA-01017 y el operador
        # lee "no se ha podido conectar" en la utilidad que borra el esquema, que parece un
        # problema de permisos y no lo es.
        Get-RsModoAuthPurga -Declarado '' -UsuarioParam '' -UsuarioJson '' | Should -Be 'indeterminado'
    }

    It "solo con espacios en blanco tambien es indeterminado" {
        Get-RsModoAuthPurga -Declarado '   ' -UsuarioParam '' -UsuarioJson "`t" | Should -Be 'indeterminado'
    }

    It "'wallet' declarado es externa" {
        Get-RsModoAuthPurga -Declarado 'wallet' -UsuarioParam '' -UsuarioJson '' | Should -Be 'externa'
    }

    It "'externa' e 'integrada' tambien son externa, sin distinguir mayusculas" {
        Get-RsModoAuthPurga -Declarado 'EXTERNA'   -UsuarioParam '' -UsuarioJson '' | Should -Be 'externa'
        Get-RsModoAuthPurga -Declarado 'Integrada' -UsuarioParam '' -UsuarioJson '' | Should -Be 'externa'
    }

    It "un valor declarado que no se reconoce cae a usuario, no a externa" {
        # Fallar hacia 'usuario' es lo seguro: pide credenciales. Fallar hacia 'externa' seria
        # volver a intentar un wallet que nadie ha dicho que exista.
        Get-RsModoAuthPurga -Declarado 'kerberos' -UsuarioParam '' -UsuarioJson '' | Should -Be 'usuario'
    }

    It "-Usuario en linea de comandos manda sobre lo declarado en rutas.json" {
        Get-RsModoAuthPurga -Declarado 'wallet' -UsuarioParam 'RSX' -UsuarioJson '' | Should -Be 'usuario'
    }

    It "sin 'autenticacion' pero con 'usuario' en rutas.json es usuario" {
        Get-RsModoAuthPurga -Declarado '' -UsuarioParam '' -UsuarioJson 'RSX' | Should -Be 'usuario'
    }
}

Describe "Test-RsEsquemaProhibido: cortafuegos contra el dedo torpe" {

    BeforeAll {
        $script:Prohibidos = @('SYS','SYSTEM','SYSAUX','DBSNMP','XDB')
    }

    It "rechaza SYS" { Test-RsEsquemaProhibido -Esquema 'SYS' -Prohibidos $Prohibidos | Should -BeTrue }

    It "rechaza aunque venga en minusculas y con espacios" {
        Test-RsEsquemaProhibido -Esquema '  system  ' -Prohibidos $Prohibidos | Should -BeTrue
    }

    It "deja pasar un esquema de proyecto" {
        Test-RsEsquemaProhibido -Esquema 'RSPROYECTO' -Prohibidos $Prohibidos | Should -BeFalse
    }

    It "un esquema vacio se trata como prohibido (falla cerrado)" {
        # Sin nombre no hay nada contra que contrastar. Dejarlo pasar seria seguir adelante sin
        # saber contra que se apunta, que es justo lo que esta utilidad no puede permitirse.
        Test-RsEsquemaProhibido -Esquema ''    -Prohibidos $Prohibidos | Should -BeTrue
        Test-RsEsquemaProhibido -Esquema '   ' -Prohibidos $Prohibidos | Should -BeTrue
    }
}

Describe "Test-RsIdentidadPurga: los tres nombres tienen que ser el mismo" {

    It "acepta cuando usuario, CURRENT_SCHEMA y declarado coinciden" {
        (Test-RsIdentidadPurga -UsuarioReal 'RSX' -SchemaReal 'RSX' -SchemaDeclarado 'RSX').ok | Should -BeTrue
    }

    It "no distingue mayusculas ni espacios sobrantes" {
        (Test-RsIdentidadPurga -UsuarioReal ' rsx ' -SchemaReal 'RSX' -SchemaDeclarado 'Rsx').ok | Should -BeTrue
    }

    It "rechaza si CURRENT_SCHEMA no es el esquema declarado" {
        # El caso real: conectado como dueno pero con la sesion apuntando a otro esquema.
        $r = Test-RsIdentidadPurga -UsuarioReal 'RSX' -SchemaReal 'OTRO' -SchemaDeclarado 'RSX'
        $r.ok | Should -BeFalse
        $r.motivo | Should -Match 'CURRENT_SCHEMA'
    }

    It "rechaza si el usuario conectado no es el dueno del esquema" {
        # Lo que hace que la utilidad no pueda alcanzar a otro esquema: el .sql recorre USER_*,
        # el diccionario del usuario CONECTADO. Si el usuario no es el dueno, USER_* no es el
        # esquema que se cree estar purgando.
        $r = Test-RsIdentidadPurga -UsuarioReal 'CONSULTA' -SchemaReal 'RSX' -SchemaDeclarado 'RSX'
        $r.ok | Should -BeFalse
        $r.motivo | Should -Match 'NO es el dueno'
    }

    It "rechaza si algun nombre viene vacio" {
        (Test-RsIdentidadPurga -UsuarioReal ''    -SchemaReal 'RSX' -SchemaDeclarado 'RSX').ok | Should -BeFalse
        (Test-RsIdentidadPurga -UsuarioReal 'RSX' -SchemaReal ''    -SchemaDeclarado 'RSX').ok | Should -BeFalse
        (Test-RsIdentidadPurga -UsuarioReal 'RSX' -SchemaReal 'RSX' -SchemaDeclarado '').ok    | Should -BeFalse
    }
}

Describe "Read-RsInventarioPurga: el recuento que se ensena antes de borrar" {

    BeforeAll {
        $script:SalidaTipica = @(
            'INV|TABLAS|300', 'INV|VISTAS|12', 'INV|VISTAS_MAT|1', 'INV|SECUENCIAS|8',
            'INV|SINONIMOS|3', 'INV|PROCEDIMIENTOS|5', 'INV|FUNCIONES|2', 'INV|PAQUETES|1',
            'INV|TIPOS|0', 'INV|TRIGGERS|4', 'INV|INDICES|612', 'INV|PAPELERA|7',
            'DATOS|41|259|0'
        )
    }

    It "el total NO suma los indices" {
        # Casi todos respaldan una PK o una UNIQUE y caen con su tabla. Sumarlos anunciaba
        # "se van a borrar 955 objetos" sobre un esquema de 300 tablas, y el numero grande
        # es justo el que el operador usa para decidir si para.
        $i = Read-RsInventarioPurga -Salida $SalidaTipica
        $i.total   | Should -Be 336
        $i.indices | Should -Be 612
    }

    It "el total NO suma la papelera, pero la papelera se conserva aparte" {
        $i = Read-RsInventarioPurga -Salida $SalidaTipica
        $i.papelera | Should -Be 7
        $i.total    | Should -Not -Be 343
    }

    It "extrae el recuento de tablas con datos, vacias e ilegibles" {
        $i = Read-RsInventarioPurga -Salida $SalidaTipica
        $i.conDatos  | Should -Be 41
        $i.vacias    | Should -Be 259
        $i.ilegibles | Should -Be 0
    }

    It "propaga el numero de tablas que no se han podido comprobar" {
        # El recuento de "tablas con datos" cuenta los errores en vez de tragarselos: si fallara
        # en masa diria "0 tablas con datos" justo antes de vaciar un esquema lleno.
        $i = Read-RsInventarioPurga -Salida @('INV|TABLAS|300', 'DATOS|0|0|300')
        $i.ilegibles | Should -Be 300
        $i.conDatos  | Should -Be 0
    }

    It "marca leido=false si no llego ninguna linea INV|" {
        # ⛔ Sin esto, una consulta que falla y no devuelve nada se lee como "esquema vacio" y
        # el script anuncia que no hay nada que purgar sobre un esquema del que no leyo nada.
        $i = Read-RsInventarioPurga -Salida @('ORA-00942: table or view does not exist')
        $i.leido | Should -BeFalse
        $i.total | Should -Be 0
    }

    It "marca leido=true en cuanto llega una sola linea INV|" {
        (Read-RsInventarioPurga -Salida @('INV|TABLAS|0')).leido | Should -BeTrue
    }

    It "tolera el relleno por la izquierda que mete sqlplus" {
        $i = Read-RsInventarioPurga -Salida @('    INV|TABLAS|5', '   DATOS|1|4|0')
        $i.total    | Should -Be 5
        $i.conDatos | Should -Be 1
    }
}

Describe "Test-RsConfirmacionPurga: hay que teclear el nombre del esquema" {

    It "acepta el nombre exacto" {
        Test-RsConfirmacionPurga -Tecleado 'RSPROYECTO' -Esquema 'RSPROYECTO' | Should -BeTrue
    }

    It "acepta con otra caja y espacios sobrantes" {
        Test-RsConfirmacionPurga -Tecleado '  rsproyecto ' -Esquema 'RSPROYECTO' | Should -BeTrue
    }

    It "rechaza un 's' de inercia" {
        # La razon de ser de la salvaguarda: un s/N se contesta sin mirar.
        Test-RsConfirmacionPurga -Tecleado 's' -Esquema 'RSPROYECTO' | Should -BeFalse
    }

    It "rechaza el vacio (Enter directo)" {
        Test-RsConfirmacionPurga -Tecleado ''  -Esquema 'RSPROYECTO' | Should -BeFalse
        Test-RsConfirmacionPurga -Tecleado '  ' -Esquema 'RSPROYECTO' | Should -BeFalse
    }

    It "rechaza un nombre parecido" {
        Test-RsConfirmacionPurga -Tecleado 'RSPROYECTO2' -Esquema 'RSPROYECTO' | Should -BeFalse
    }

    It "no confirma nada si el esquema esperado viene vacio" {
        Test-RsConfirmacionPurga -Tecleado '' -Esquema '' | Should -BeFalse
    }
}

Describe "New-RsSqlPurga: el .sql que sobrevive al script que lo genero" {

    BeforeAll {
        $script:PatPapelera = "'BIN' || CHR(36) || '%'"
        $script:Sql = New-RsSqlPurga -Esquema 'RSPROYECTO' -EntornoNombre 'PROD' -Db 'ORCL' `
                                     -Servidor 'srv01' -Generado '2026-08-13 10:00:00' `
                                     -PatronPapelera $script:PatPapelera
    }

    It "lleva la guarda de esquema DENTRO del propio fichero" {
        # El .sql se queda en disco y alguien lo abrira suelto dentro de seis meses, desde otra
        # sesion. La guarda del .ps1 no viaja con el; esta si.
        $Sql | Should -Match "IF USER <> 'RSPROYECTO' THEN"
        $Sql | Should -Match 'RAISE_APPLICATION_ERROR'
    }

    It "el patron de la papelera llega a Oracle sin depender de la interpolacion de PowerShell" {
        # 'BIN$' con un dolar suelto se lo come el here-string y el patron llegaba roto.
        $Sql | Should -BeLike "*'BIN' || CHR(36) || '%'*"
    }

    It "no queda ni un 'BIN\$' crudo en el SQL generado" {
        $Sql | Should -Not -Match 'BIN\$'
    }

    It "borra las vistas materializadas ANTES que las tablas" {
        # Una vista materializada se lleva su tabla contenedora: al reves, el DROP TABLE falla.
        $iMv = $Sql.IndexOf('DROP MATERIALIZED VIEW')
        $iTb = $Sql.IndexOf('DROP TABLE')
        $iMv | Should -BeGreaterThan -1
        $iTb | Should -BeGreaterThan $iMv
    }

    It "las tablas caen con CASCADE CONSTRAINTS PURGE" {
        # CASCADE se lleva las FK que las apuntan; PURGE evita que queden en la papelera y
        # vuelvan a contarse como objetos del esquema.
        $Sql | Should -Match 'DROP TABLE.*CASCADE CONSTRAINTS PURGE'
    }

    It "recorre los nueve tipos de objeto" {
        foreach ($t in @('DROP MATERIALIZED VIEW','DROP TABLE','DROP VIEW','DROP SEQUENCE',
                         'DROP SYNONYM','DROP TYPE','DROP TRIGGER','DROP INDEX')) {
            $Sql | Should -Match ([regex]::Escape($t))
        }
        $Sql | Should -Match "object_type IN \('PROCEDURE','FUNCTION','PACKAGE'\)"
    }

    It "termina con PURGE RECYCLEBIN y un inventario final" {
        # Cualquier fila del inventario final es algo que NO se ha podido borrar.
        $Sql | Should -Match 'PURGE RECYCLEBIN;'
        $Sql | Should -Match 'SELECT object_type, COUNT\(\*\) AS quedan'
    }

    It "no aborta al primer objeto que no se deja borrar" {
        # Un objeto puede haber caido ya en cascada con otro. Se deja constancia y se sigue;
        # manda el inventario final.
        $Sql | Should -Match 'EXCEPTION WHEN OTHERS THEN'
    }

    It "lee siempre del diccionario del usuario conectado, nunca de ALL_* con un filtro" {
        # Es la salvaguarda estructural: sin nombre de esquema que filtrar, no hay filtro que
        # escribir mal. Un ALL_*/DBA_* aqui abriria la puerta a alcanzar otro esquema.
        $Sql | Should -Not -Match '(?i)\ball_(tables|views|objects|indexes|sequences)\b'
        $Sql | Should -Not -Match '(?i)\bdba_(tables|views|objects|indexes|sequences)\b'
        $Sql | Should -Match '(?i)\buser_tables\b'
    }

    It "identifica en la cabecera contra que BD y entorno se genero" {
        $Sql | Should -Match 'RSPROYECTO'
        $Sql | Should -Match 'PROD'
        $Sql | Should -Match 'ORCL'
        $Sql | Should -Match 'srv01'
    }
}

Describe "ConvertFrom-RsSecureString: la contrasena no se queda en memoria no gestionada" {

    It "devuelve el texto original" {
        ConvertFrom-RsSecureString -Segura (New-SecureStringPrueba 'Contrasena123') | Should -Be 'Contrasena123'
    }

    It "una cadena vacia devuelve \$null, no cadena vacia" {
        # "el operador pulso Enter" es una respuesta legitima, y el llamante la distingue de una
        # contrasena real para no intentar conectar con credenciales inventadas.
        ConvertFrom-RsSecureString -Segura (New-SecureStringPrueba '') | Should -BeNullOrEmpty
    }

    It "un SecureString nulo devuelve \$null sin reventar" {
        ConvertFrom-RsSecureString -Segura $null | Should -BeNullOrEmpty
    }

    It "conserva los caracteres que suelen romper el quoting" {
        ConvertFrom-RsSecureString -Segura (New-SecureStringPrueba 'a"b$c/d@e') | Should -Be 'a"b$c/d@e'
    }
}

Describe "Test-RsAuthEntornoCoherente: avisar al GENERAR, no en el servidor del cliente" {

    It "detecta 'wallet' y 'usuario' declarados a la vez" {
        # La contradiccion real que dejo una instalacion sin salida: el bloque viaja literal a
        # rutas.json y nadie puede adivinar cual de las dos declaraciones es la verdad.
        $a = @(Test-RsAuthEntornoCoherente -Entorno 'PROD' -Bd (New-BdPrueba @{
            motor='ORACLE'; autenticacion='wallet'; usuario='RSPROYECTO'; conexion='ALIASPROD' }))
        $a.Count | Should -Be 1
        $a[0] | Should -Match 'Y usuario'
    }

    It "no se queja de un wallet declarado sin usuario" {
        $a = @(Test-RsAuthEntornoCoherente -Entorno 'PROD' -Bd (New-BdPrueba @{
            motor='ORACLE'; autenticacion='wallet'; usuario=''; conexion='ALIASPROD' }))
        $a.Count | Should -Be 0
    }

    It "no se queja de usuario/contrasena declarado sin autenticacion externa" {
        $a = @(Test-RsAuthEntornoCoherente -Entorno 'DESA' -Bd (New-BdPrueba @{
            motor='ORACLE'; autenticacion='usuario'; usuario='RSPROYECTO'; conexion='ALIASDESA' }))
        $a.Count | Should -Be 0
    }

    It "detecta wallet declarado con una cadena de conexion en vez de un alias" {
        # El wallet indexa la credencial por el texto EXACTO del alias: un descriptor o un
        # host:puerto/servicio dan un ORA-12154 que parece un problema de red y no lo es.
        $a = @(Test-RsAuthEntornoCoherente -Entorno 'PROD' -Bd (New-BdPrueba @{
            motor='ORACLE'; autenticacion='wallet'; usuario=''; conexion='srv01:1521/ORCL' }))
        ($a -join ' ') | Should -Match 'no es un alias'
    }

    It "detecta wallet declarado con un descriptor completo" {
        $a = @(Test-RsAuthEntornoCoherente -Entorno 'PROD' -Bd (New-BdPrueba @{
            motor='ORACLE'; autenticacion='wallet'; usuario=''
            conexion='(DESCRIPTION=(ADDRESS=(PROTOCOL=TCPS)(HOST=h)(PORT=2484)))' }))
        ($a -join ' ') | Should -Match 'no es un alias'
    }

    It "avisa cuando no se declara ni 'autenticacion' ni 'usuario'" {
        $a = @(Test-RsAuthEntornoCoherente -Entorno 'TEST' -Bd (New-BdPrueba @{
            motor='ORACLE'; autenticacion=''; usuario=''; conexion='ALIASTEST' }))
        ($a -join ' ') | Should -Match 'tendra que teclear el usuario'
    }

    It "un entorno sin bloque bd no genera avisos ni revienta" {
        @(Test-RsAuthEntornoCoherente -Entorno 'PROD' -Bd $null).Count | Should -Be 0
    }

    It "acumula los dos avisos cuando concurren" {
        $a = @(Test-RsAuthEntornoCoherente -Entorno 'PROD' -Bd (New-BdPrueba @{
            motor='ORACLE'; autenticacion='wallet'; usuario='RSPROYECTO'; conexion='srv01:1521/ORCL' }))
        $a.Count | Should -Be 2
    }
}

Describe "La utilidad de purga vive FUERA del paquete que se copia al cliente" {

    # ⛔ Esto no es una comprobacion de estilo: es la decision de diseno que hace seguro al
    # instalador. El Instalador\ se copia al servidor del cliente y se queda ahi para siempre.
    # El DDL del proyecto usa CREATE pelado con fail-fast a proposito, de forma que un ORA-00955
    # significa "este esquema NO esta vacio, para". Una herramienta de vaciado conviviendo con
    # Instalar.ps1 anula esa proteccion: convierte "para" en "vacialo y sigue".

    It "Purgar-Esquema.ps1 esta en assets\utilidades, no en assets\instalacion" {
        Join-Path $Raiz "assets\utilidades\Purgar-Esquema.ps1" | Should -Exist
        Join-Path $Raiz "assets\instalacion\Purgar-Esquema.ps1" | Should -Not -Exist
    }

    It "el hook del paquete solo copia plantillas de assets\instalacion" {
        # Si alguien cambiara $assets a la raiz de assets\, la utilidad de purga empezaria a
        # viajar al cliente sin que nadie lo notara.
        $txt = Get-Content $Paquete -Raw
        $txt | Should -Match 'assets\\+instalacion'
        $txt | Should -Not -Match 'Purgar-Esquema'
    }

    It "ningun fichero del paquete de instalacion menciona la utilidad de purga" {
        $ficheros = Get-ChildItem (Join-Path $Raiz "assets\instalacion") -File
        $ficheros.Count | Should -BeGreaterThan 0
        foreach ($f in $ficheros) {
            (Get-Content $f.FullName -Raw) | Should -Not -Match 'Purgar-Esquema'
        }
    }
}
