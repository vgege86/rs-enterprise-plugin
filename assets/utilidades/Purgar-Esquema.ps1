<#
.SYNOPSIS
    Vacia por completo un esquema Oracle: borra TODOS sus objetos para poder relanzar una
    instalacion limpia desde cero.

    ⛔ ESTO DESTRUYE DATOS Y NO TIENE VUELTA ATRAS. No forma parte del paquete que se copia al
    servidor del cliente: es una utilidad del equipo de entrega. Ver la nota del final.

.DESCRIPTION
    POR QUE EXISTE

    El paquete de instalacion limpia crea los objetos con CREATE pelado y se para al primer
    error. Eso es deliberado: un ORA-00955 significa "este esquema NO esta vacio, para", y es
    una proteccion, no un defecto. Pero cuando una instalacion aborta a medias -o cuando se
    quiere repetir de cero sobre un entorno recien montado- hay que dejar el esquema como
    estaba antes de empezar. Hacerlo a mano con 300+ tablas es donde la gente se equivoca de
    sesion y vacia el esquema que no era.

    LAS TRES SALVAGUARDAS

    1. NO PUEDE tocar otro esquema. No filtra por nombre: lee USER_* -el diccionario del
       usuario CONECTADO- y ademas exige que USER, CURRENT_SCHEMA y el esquema declarado en
       rutas.json sean LOS TRES el mismo. Si el usuario de conexion no es el dueno, aborta.
       Un filtro se puede escribir mal; leer USER_* siendo el dueno no deja margen.
    2. Ensena el inventario ANTES: cuantos objetos de cada tipo y, sobre todo, CUANTAS TABLAS
       CONTIENEN DATOS. Si el esquema tiene filas, lo dice en grande.
    3. Pide que se TECLEE el nombre del esquema. Un s/N se contesta por inercia; escribir
       RSPROYECTO obliga a mirar contra que se esta apuntando.

    Y ademas -Simular, que hace el inventario y ESCRIBE el .sql de borrado sin ejecutarlo,
    para poder leerlo entero antes de decidir.

    QUE BORRA

    Vistas materializadas, tablas (CASCADE CONSTRAINTS PURGE), vistas, secuencias, sinonimos
    privados, procedimientos, funciones, paquetes, tipos (FORCE), triggers sueltos, indices
    que hayan quedado huerfanos y, al final, PURGE RECYCLEBIN. En ese orden.

    El .sql que ejecuta se genera del diccionario en el momento (no hay lista fija) y lleva su
    propia guarda incorporada: si alguien lo relanza a mano desde otra sesion, se niega.

    NOTA SOBRE EL NOMBRE DE LOS OBJETOS DE LA PAPELERA

    Los objetos borrados sin PURGE se llaman BIN$... El simbolo del dolar es el caracter de
    interpolacion de PowerShell, y dentro de un here-string entrecomillado se lo come. Por eso
    en el SQL generado ese patron se escribe 'BIN' || CHR(36) || '%': asi el texto que llega a
    Oracle no depende de como PowerShell haya interpretado un dolar suelto.

.PARAMETER Entorno      DESA | TEST | PROD. Debe existir en rutas.json.
.PARAMETER RutasJson    rutas.json con los datos de conexion. Default: junto a este script,
                        y si no, el del paquete de instalacion hermano.
.PARAMETER Usuario      Fuerza usuario/contrasena (ignora 'autenticacion' de rutas.json).
.PARAMETER Password     Contrasena. Si hace falta y no se pasa, se pide por consola.
.PARAMETER TnsAdmin     Carpeta con sqlnet.ora / tnsnames.ora / wallet.
.PARAMETER Simular      Inventario + generar el .sql de borrado. NO ejecuta nada. Recomendado
                        SIEMPRE antes de la ejecucion real.
.PARAMETER Salida       Donde dejar el .sql generado. Default: junto a este script.
.PARAMETER DotSourceOnly  Uso interno de los tests: carga las funciones puras y no ejecuta nada.

.EXAMPLE
    .\Purgar-Esquema.ps1 -Entorno PROD -Simular
.EXAMPLE
    .\Purgar-Esquema.ps1 -Entorno PROD
#>
param(
    [ValidateSet('DESA','TEST','PROD','')][string]$Entorno = "",
    [string]$RutasJson = "",
    [string]$Usuario = "",
    [string]$Password = "",
    [string]$TnsAdmin = "",
    [switch]$Simular,
    [string]$Salida = "",
    [switch]$DotSourceOnly
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

function Write-RsSeccion([string]$t) { Write-Host ""; Write-Host "== $t ==" }

# Patron de los objetos de la papelera, sin un solo '$' en el fuente PowerShell.
$RS_PAT_PAPELERA = "'BIN' || CHR(36) || '%'"

# Esquemas que no se tocan ni por error. No es la salvaguarda seria -esa es USER_* mas la
# triple coincidencia-, es un ultimo cortafuegos contra el dedo torpe.
$RS_ESQUEMAS_PROHIBIDOS = @(
    'SYS','SYSTEM','SYSAUX','DBSNMP','OUTLN','XDB','CTXSYS','MDSYS','ORDSYS','WMSYS',
    'OLAPSYS','EXFSYS','APPQOSSYS','AUDSYS','GSMADMIN_INTERNAL','LBACSYS','DVSYS','ORACLE_OCM'
)

function New-RsTempSql {
    param([string[]]$Lineas)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("rspurga_" + [Guid]::NewGuid().ToString("N") + ".sql")
    $sinBom = New-Object Text.UTF8Encoding($false)   # con BOM, sqlplus se come la primera sentencia
    [System.IO.File]::WriteAllText($p, (($Lineas -join "`r`n") + "`r`n"), $sinBom)
    return $p
}

# ===========================================================================
#  Funciones puras (sin BD, sin consola, sin disco)
#  Se cargan con -DotSourceOnly desde tests\PurgarEsquema.Tests.ps1. Todo lo que decide si
#  esto borra o no borra vive aqui: una salvaguarda que no se puede probar es una promesa.
# ===========================================================================

function ConvertFrom-RsSecureString {
    <#  SecureString -> texto plano liberando el buffer intermedio.

        SecureStringToBSTR reserva memoria NO gestionada que el recolector no toca: sin
        ZeroFreeBSTR la contrasena se queda en claro en el proceso hasta que termina.

        ⛔ Duplicada a proposito respecto a assets\instalacion\Ejecutar-Scripts.ps1. Los dos
        son scripts SUELTOS que se copian a maquinas distintas -aquel al servidor del cliente
        dentro del paquete, este a la carpeta de utilidades del equipo- y ninguno puede
        importar un modulo comun sin arrastrarlo consigo. La copia es el precio de que cada
        uno se ejecute solo.  #>
    param([Security.SecureString]$Segura)
    if (-not $Segura) { return $null }
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Segura)
        $txt  = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if ([string]::IsNullOrEmpty($txt)) { return $null }
    return $txt
}

function Get-RsModoAuthPurga {
    <#  Resuelve si se conecta por autenticacion externa (wallet) o por usuario/contrasena.

        ⛔ Devuelve "indeterminado" cuando rutas.json no declara ni 'autenticacion' ni
        'usuario'. NO devuelve "externa": eso seria afirmar que hay wallet sin haber mirado
        si existe, y es exactamente el fallo que se arreglo en Ejecutar-Scripts.ps1 -el
        connect salia como '/@alias', Oracle contestaba ORA-01017 y el script moria listando
        pistas de wallet sin haber ofrecido nunca usuario y contrasena-. Aqui el sintoma
        habria sido mas confuso todavia: un "no se ha podido conectar" en la utilidad que
        borra el esquema se lee como un problema de permisos.

        El llamante resuelve el indeterminado pidiendo credenciales, que es la via que
        siempre esta disponible.  #>
    param([string]$Declarado, [string]$UsuarioParam, [string]$UsuarioJson)
    if (-not [string]::IsNullOrWhiteSpace($UsuarioParam)) { return "usuario" }
    if (-not [string]::IsNullOrWhiteSpace($Declarado)) {
        if ($Declarado -match '(?i)^(wallet|externa|integrada)$') { return "externa" }
        return "usuario"
    }
    if ([string]::IsNullOrWhiteSpace($UsuarioJson)) { return "indeterminado" }
    return "usuario"
}

function Test-RsEsquemaProhibido {
    <#  Ultimo cortafuegos contra el dedo torpe. NO es la salvaguarda seria -esa es leer
        USER_* siendo el dueno-, es que un 'SYS' tecleado por inercia no llegue ni a conectar.  #>
    param([string]$Esquema, [string[]]$Prohibidos)
    if ([string]::IsNullOrWhiteSpace($Esquema)) { return $true }
    return ($Prohibidos -contains $Esquema.Trim().ToUpper())
}

function Test-RsIdentidadPurga {
    <#  Los TRES tienen que coincidir: usuario conectado, CURRENT_SCHEMA y el esquema
        declarado en rutas.json. Devuelve @{ ok; motivo }.

        Es lo que convierte "borra el esquema X" en una operacion que NO PUEDE alcanzar a
        otro: el .sql de borrado recorre USER_*, el diccionario del usuario conectado, asi
        que si el usuario es el dueno del esquema declarado no hay nombre que filtrar mal.
        Un filtro por nombre se puede escribir mal; esto no.  #>
    param([string]$UsuarioReal, [string]$SchemaReal, [string]$SchemaDeclarado)
    $u = "$UsuarioReal".Trim().ToUpper()
    $s = "$SchemaReal".Trim().ToUpper()
    $d = "$SchemaDeclarado".Trim().ToUpper()
    if (-not $u -or -not $s -or -not $d) {
        return @{ ok = $false; motivo = "no se ha podido leer la identidad de la sesion (usuario '$u', CURRENT_SCHEMA '$s', declarado '$d')." }
    }
    if ($s -ne $d) {
        return @{ ok = $false; motivo = "CURRENT_SCHEMA ($s) no coincide con el esquema declarado ($d)." }
    }
    if ($u -ne $d) {
        return @{ ok = $false; motivo = "el usuario conectado ($u) NO es el dueno del esquema ($d)." }
    }
    return @{ ok = $true; motivo = "usuario, CURRENT_SCHEMA y esquema declarado coinciden ($d)." }
}

function Read-RsInventarioPurga {
    <#  Parsea las lineas INV|<TIPO>|<n> y DATOS|<con>|<vacias>|<error> que emite el bloque de
        inventario. Devuelve @{ objetos; conDatos; vacias; ilegibles; total; indices; papelera;
        leido }.

        `total` cuenta SOLO lo que el .sql de borrado va a soltar con un DROP explicito. Los
        INDICES quedan fuera a proposito: casi todos respaldan una PK o una UNIQUE y caen con
        su tabla, asi que sumarlos anunciaba "se van a borrar 900 objetos" sobre un esquema de
        300 tablas. Se informan aparte. La PAPELERA tampoco suma -no son objetos vivos-, pero
        cuenta para decidir si queda algo que hacer: un esquema cuyo unico contenido es la
        papelera todavia necesita el PURGE RECYCLEBIN.

        `leido` es $false si no llego ninguna linea INV|: sin eso, una consulta que falla y no
        devuelve nada se leeria como "esquema vacio" justo antes de purgar.  #>
    param([string[]]$Salida)
    $objetos = @{}
    $conDatos = 0; $vacias = 0; $ilegibles = 0; $leido = $false
    foreach ($l in $Salida) {
        if ($l -match '^\s*INV\|([A-Z_]+)\|(\d+)') {
            $objetos[$matches[1]] = [int]$matches[2]
            $leido = $true
        } elseif ($l -match '^\s*DATOS\|(\d+)\|(\d+)\|(\d+)') {
            $conDatos = [int]$matches[1]; $vacias = [int]$matches[2]; $ilegibles = [int]$matches[3]
        }
    }
    # Los tipos que el .sql recorre con un DROP explicito, en el mismo orden en que los borra.
    $borrables = @('VISTAS_MAT','TABLAS','VISTAS','SECUENCIAS','SINONIMOS',
                   'PROCEDIMIENTOS','FUNCIONES','PAQUETES','TIPOS','TRIGGERS')
    $total = 0
    foreach ($k in $borrables) { if ($objetos.ContainsKey($k)) { $total += $objetos[$k] } }
    return @{
        objetos   = $objetos
        conDatos  = $conDatos
        vacias    = $vacias
        ilegibles = $ilegibles
        total     = $total
        indices   = [int]($objetos['INDICES'])
        papelera  = [int]($objetos['PAPELERA'])
        leido     = $leido
    }
}

function Test-RsConfirmacionPurga {
    <#  Lo tecleado tiene que ser el nombre del esquema. Un s/N se contesta por inercia;
        escribir el nombre obliga a mirar contra que se esta apuntando.  #>
    param([string]$Tecleado, [string]$Esquema)
    if ([string]::IsNullOrWhiteSpace($Esquema)) { return $false }
    return ("$Tecleado".Trim().ToUpper() -eq $Esquema.Trim().ToUpper())
}

function New-RsSqlPurga {
    <#  El .sql de borrado, generado del diccionario en el momento (no hay lista fija).

        Lleva su propia guarda DENTRO: este fichero sobrevive al script que lo genero y
        alguien lo abrira suelto dentro de seis meses, en otra sesion.  #>
    param([string]$Esquema, [string]$EntornoNombre, [string]$Db, [string]$Servidor,
          [string]$Generado, [string]$PatronPapelera)
    return @"
-- =====================================================================================
-- PURGA COMPLETA DEL ESQUEMA $Esquema  ($EntornoNombre)
-- Generado: $Generado  contra la BD $Db ($Servidor)
--
-- DESTRUCTIVO E IRREVERSIBLE. Borra TODOS los objetos del usuario que lo ejecuta.
--
-- La guarda de abajo va DENTRO de este fichero a proposito, no solo en el .ps1 que lo genero:
-- este .sql sobrevive al script y alguien lo abrira suelto dentro de seis meses.
-- =====================================================================================
WHENEVER SQLERROR EXIT FAILURE
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
    IF USER <> '$Esquema' THEN
        RAISE_APPLICATION_ERROR(-20001,
            'Este script purga el esquema $Esquema y esta sesion es de ' || USER || '. Abortado.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Purgando el esquema ' || USER || ' ...');
END;
/

DECLARE
    PROCEDURE borra(p_sql VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
        DBMS_OUTPUT.PUT_LINE('  OK  ' || p_sql);
    EXCEPTION WHEN OTHERS THEN
        -- No se aborta: un objeto puede haber caido ya en cascada con otro (una tabla se lleva
        -- sus triggers y sus indices). Se deja constancia y se sigue; lo que quede sin borrar
        -- sale en el inventario final, que es quien manda.
        DBMS_OUTPUT.PUT_LINE('  --  ' || p_sql || '  [' || SQLERRM || ']');
    END;
BEGIN
    -- Vistas materializadas ANTES que las tablas: se llevan su tabla contenedora.
    FOR r IN (SELECT mview_name n FROM user_mviews) LOOP
        borra('DROP MATERIALIZED VIEW "' || r.n || '"');
    END LOOP;

    -- Tablas. CASCADE CONSTRAINTS se lleva las FK que las apuntan; PURGE evita que queden en
    -- la papelera y vuelvan a contarse como objetos del esquema.
    FOR r IN (SELECT table_name n FROM user_tables
               WHERE nested = 'NO' AND secondary = 'N'
                 AND table_name NOT LIKE $PatronPapelera) LOOP
        borra('DROP TABLE "' || r.n || '" CASCADE CONSTRAINTS PURGE');
    END LOOP;

    FOR r IN (SELECT view_name n FROM user_views) LOOP
        borra('DROP VIEW "' || r.n || '"');
    END LOOP;

    FOR r IN (SELECT sequence_name n FROM user_sequences) LOOP
        borra('DROP SEQUENCE "' || r.n || '"');
    END LOOP;

    FOR r IN (SELECT synonym_name n FROM user_synonyms) LOOP
        borra('DROP SYNONYM "' || r.n || '"');
    END LOOP;

    FOR r IN (SELECT object_name n, object_type t FROM user_objects
               WHERE object_type IN ('PROCEDURE','FUNCTION','PACKAGE')
                 AND object_name NOT LIKE $PatronPapelera) LOOP
        borra('DROP ' || r.t || ' "' || r.n || '"');
    END LOOP;

    -- FORCE: un tipo con dependientes no se deja borrar de otra forma.
    FOR r IN (SELECT type_name n FROM user_types) LOOP
        borra('DROP TYPE "' || r.n || '" FORCE');
    END LOOP;

    -- Triggers sueltos (los de tabla ya cayeron con ella).
    FOR r IN (SELECT trigger_name n FROM user_triggers) LOOP
        borra('DROP TRIGGER "' || r.n || '"');
    END LOOP;

    -- Indices que no dependieran de una tabla ya borrada.
    FOR r IN (SELECT index_name n FROM user_indexes
               WHERE index_type <> 'LOB' AND index_name NOT LIKE $PatronPapelera) LOOP
        borra('DROP INDEX "' || r.n || '"');
    END LOOP;
END;
/

PURGE RECYCLEBIN;

-- Inventario final: cualquier fila aqui es algo que NO se ha podido borrar.
SET PAGESIZE 100
SET HEADING ON
SELECT object_type, COUNT(*) AS quedan
  FROM user_objects
 WHERE object_name NOT LIKE $PatronPapelera
 GROUP BY object_type
 ORDER BY object_type;
"@
}

if ($DotSourceOnly) { return }

if (-not $Entorno) { Write-Host "ERROR: falta -Entorno (DESA | TEST | PROD)."; exit 1 }

# --- rutas.json -----------------------------------------------------------
$aqui = $PSScriptRoot
if (-not $RutasJson) {
    foreach ($cand in @((Join-Path $aqui "rutas.json"),
                        (Join-Path (Split-Path $aqui -Parent) "Instalador\rutas.json"))) {
        if (Test-Path $cand) { $RutasJson = $cand; break }
    }
}
if (-not $RutasJson -or !(Test-Path $RutasJson)) {
    Write-Host "ERROR: no se encuentra rutas.json. Pasalo con -RutasJson."; exit 1
}

$cfg = Get-Content $RutasJson -Raw -Encoding UTF8 | ConvertFrom-Json
$ent = $cfg.entornos.$Entorno
if (-not $ent -or -not $ent.bd) { Write-Host "ERROR: entorno '$Entorno' sin bloque 'bd' en $RutasJson"; exit 1 }

$motor = ("$($ent.bd.motor)").ToUpper()
if ($motor -ne 'ORACLE') {
    Write-Host "ERROR: esta utilidad es solo para ORACLE (rutas.json declara '$motor')."
    Write-Host "       En SQL Server el borrado de esquema es otro juego de sentencias."
    exit 1
}

$conexion    = "$($ent.bd.conexion)"
$usuarioJson = "$($ent.bd.usuario)"
$authJson    = "$($ent.bd.autenticacion)"
$schemaDecl  = "$($ent.bd.schema)"
if (-not $schemaDecl) { $schemaDecl = $usuarioJson }
if (-not $schemaDecl) {
    Write-Host "ERROR: rutas.json no declara 'schema' ni 'usuario' para $Entorno."
    Write-Host "       Sin esquema declarado no hay contra que contrastar, y sin eso esto no se ejecuta."
    exit 1
}
$schemaDecl = $schemaDecl.ToUpper()

if (Test-RsEsquemaProhibido -Esquema $schemaDecl -Prohibidos $RS_ESQUEMAS_PROHIBIDOS) {
    Write-Host "ERROR: '$schemaDecl' es un esquema del propio Oracle. No se toca."; exit 1
}

$usuarioEfectivo = if ($Usuario) { $Usuario } else { $usuarioJson }
$modoAuth = Get-RsModoAuthPurga -Declarado $authJson -UsuarioParam $Usuario -UsuarioJson $usuarioJson

if (-not (Get-Command sqlplus -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: sqlplus no esta en el PATH."; exit 1
}

if (-not $TnsAdmin -and $ent.bd.tnsAdmin) { $TnsAdmin = "$($ent.bd.tnsAdmin)" }
if ($TnsAdmin) {
    if (!(Test-Path $TnsAdmin)) { Write-Host "ERROR: no existe TNS_ADMIN: $TnsAdmin"; exit 1 }
    $env:TNS_ADMIN = (Resolve-Path $TnsAdmin).Path
}
if (-not $env:NLS_LANG) { $env:NLS_LANG = "AMERICAN_AMERICA.AL32UTF8" }

# rutas.json no declara ni 'autenticacion' ni 'usuario'. No se supone wallet -eso es lo que
# dejaba a Ejecutar-Scripts.ps1 lanzando '/@alias' contra un servidor sin wallet y muriendo con
# un ORA-01017 sin ofrecer nunca otra via-: se pide usuario, que siempre esta disponible.
if ($modoAuth -eq 'indeterminado') {
    Write-Host ""
    Write-Host "AVISO: rutas.json no declara 'autenticacion' ni 'usuario' para $Entorno."
    Write-Host "       No se da por supuesto que haya wallet: se conecta con usuario y contrasena."
    $usuarioEfectivo = (Read-Host "Usuario dueno de $schemaDecl en $conexion").Trim()
    if (-not $usuarioEfectivo) {
        Write-Host "ERROR: hace falta un usuario para conectar. No se ha tocado nada."; exit 1
    }
    $modoAuth = 'usuario'
}

if ($modoAuth -eq 'usuario' -and -not $usuarioEfectivo) {
    Write-Host "ERROR: modo usuario sin 'usuario'. Pasa -Usuario, o declaralo en rutas.json."; exit 1
}

if ($modoAuth -eq 'usuario' -and -not $Password) {
    $sec = Read-Host "Password de $usuarioEfectivo@$conexion" -AsSecureString
    $Password = ConvertFrom-RsSecureString -Segura $sec
    if (-not $Password) { Write-Host "ERROR: hace falta contrasena."; exit 1 }
}

$connectArg  = if ($modoAuth -eq 'externa') { "/@$conexion" } else { "/nolog" }
$connectLine = if ($modoAuth -eq 'externa') { "" } else { "CONNECT $usuarioEfectivo/$Password@$conexion" }

function Invoke-RsOracle {
    param([string[]]$Lineas)
    $tmp = New-RsTempSql -Lineas $Lineas
    try {
        $salida = & sqlplus -L -S $connectArg "@$tmp" 2>&1
        $script:ultimoCodigo = $LASTEXITCODE
        return $salida
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

$cab = @("WHENEVER SQLERROR EXIT FAILURE", "WHENEVER OSERROR EXIT FAILURE",
         "SET DEFINE OFF", "SET SQLBLANKLINES ON", "SET FEEDBACK OFF", "SET PAGESIZE 0",
         "SET HEADING OFF", "SET LINESIZE 32767", "SET TRIMSPOOL ON", "SET VERIFY OFF")

# --- SALVAGUARDA 1: quien soy y donde estoy -------------------------------
Write-RsSeccion "Identidad de la sesion"
$out = Invoke-RsOracle -Lineas ($cab + @(
    $connectLine,
    "SELECT 'IDENT|'||USER||'|'||SYS_CONTEXT('USERENV','CURRENT_SCHEMA')||'|'||SYS_CONTEXT('USERENV','DB_NAME')||'|'||SYS_CONTEXT('USERENV','SERVER_HOST') FROM DUAL;",
    "EXIT SUCCESS") | Where-Object { $_ -ne "" })
if ($script:ultimoCodigo -ne 0 -or ($out -join "`n") -notmatch 'IDENT\|') {
    Write-Host "ERROR: no se ha podido conectar."
    $out | ForEach-Object { Write-Host "  $_" }
    exit 1
}
$campos = (($out | Where-Object { $_ -match 'IDENT\|' } | Select-Object -First 1).Trim() -split '\|')
$userReal   = $campos[1].Trim().ToUpper()
$schemaReal = $campos[2].Trim().ToUpper()
$dbName     = $campos[3].Trim()
$servidor   = $campos[4].Trim()      # $host es variable automatica de PowerShell: no usarla

Write-Host "Entorno declarado : $Entorno"
Write-Host "BD                : $dbName en $servidor"
Write-Host "Usuario conectado : $userReal"
Write-Host "CURRENT_SCHEMA    : $schemaReal"
Write-Host "Esquema declarado : $schemaDecl  (rutas.json)"

# Los TRES tienen que coincidir. Es lo que convierte "borra el esquema X" en una operacion que
# no puede alcanzar a otro: leyendo USER_* siendo el dueno no hay nombre que filtrar mal.
$ident = Test-RsIdentidadPurga -UsuarioReal $userReal -SchemaReal $schemaReal -SchemaDeclarado $schemaDecl
if (-not $ident.ok) {
    Write-Host ""
    Write-Host "ERROR: $($ident.motivo)"
    Write-Host "       Esta utilidad solo borra leyendo USER_*, el diccionario del usuario conectado:"
    Write-Host "       asi no hay forma de que alcance a otro esquema por un filtro mal escrito."
    Write-Host "       Conectate como $schemaDecl para purgarlo. Se aborta sin tocar nada."
    exit 1
}
Write-Host "OK: usuario, CURRENT_SCHEMA y esquema declarado coinciden."

# --- SALVAGUARDA 2: inventario, y sobre todo si hay DATOS -----------------
# SERVEROUTPUT se activa ANTES del bloque: encenderlo despues deja el DBMS_OUTPUT sin recoger
# y el recuento de tablas con datos se pierde en silencio.
Write-RsSeccion "Inventario de $schemaDecl"
$sqlInventario = @(
    "SET SERVEROUTPUT ON SIZE UNLIMITED",
    "DECLARE",
    "    v_con_datos NUMBER := 0;",
    "    v_vacias    NUMBER := 0;",
    "    v_error     NUMBER := 0;",
    "    v_hay       NUMBER;",
    "BEGIN",
    "    FOR t IN (SELECT table_name FROM user_tables",
    "               WHERE nested = 'NO' AND secondary = 'N'",
    "                 AND table_name NOT LIKE $RS_PAT_PAPELERA",
    "                 AND table_name NOT IN (SELECT mview_name FROM user_mviews)) LOOP",
    "        BEGIN",
    # ENQUOTE_NAME entrecomilla y VALIDA el identificador: evita meter comillas dobles en el
    # fuente PowerShell (donde no se escapan con barra) y de paso cierra la inyeccion por
    # nombre de tabla trucado.
    "            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM (SELECT 1 FROM ' || DBMS_ASSERT.ENQUOTE_NAME(t.table_name) || ' WHERE ROWNUM = 1)' INTO v_hay;",
    "            IF v_hay > 0 THEN v_con_datos := v_con_datos + 1; ELSE v_vacias := v_vacias + 1; END IF;",
    # Contadas, NO ignoradas: si esto se tragara los errores en silencio, un fallo generalizado
    # (por ejemplo sin EXECUTE sobre DBMS_ASSERT) daria 0 tablas con datos y el script diria
    # "esquema vacio" justo antes de borrar un esquema lleno.
    "        EXCEPTION WHEN OTHERS THEN v_error := v_error + 1;",
    "        END;",
    "    END LOOP;",
    "    DBMS_OUTPUT.PUT_LINE('DATOS|' || v_con_datos || '|' || v_vacias || '|' || v_error);",
    "END;",
    "/",
    "SELECT 'INV|TABLAS|'||COUNT(*) FROM user_tables WHERE nested='NO' AND secondary='N' AND table_name NOT LIKE $RS_PAT_PAPELERA;",
    "SELECT 'INV|VISTAS|'||COUNT(*) FROM user_views;",
    "SELECT 'INV|VISTAS_MAT|'||COUNT(*) FROM user_mviews;",
    "SELECT 'INV|SECUENCIAS|'||COUNT(*) FROM user_sequences;",
    "SELECT 'INV|SINONIMOS|'||COUNT(*) FROM user_synonyms;",
    "SELECT 'INV|PROCEDIMIENTOS|'||COUNT(*) FROM user_objects WHERE object_type='PROCEDURE';",
    "SELECT 'INV|FUNCIONES|'||COUNT(*) FROM user_objects WHERE object_type='FUNCTION';",
    "SELECT 'INV|PAQUETES|'||COUNT(*) FROM user_objects WHERE object_type='PACKAGE';",
    "SELECT 'INV|TIPOS|'||COUNT(*) FROM user_types;",
    "SELECT 'INV|TRIGGERS|'||COUNT(*) FROM user_triggers;",
    "SELECT 'INV|INDICES|'||COUNT(*) FROM user_indexes WHERE index_type <> 'LOB';",
    "SELECT 'INV|PAPELERA|'||COUNT(*) FROM user_recyclebin;",
    "EXIT SUCCESS"
)
$out = Invoke-RsOracle -Lineas ($cab + @($connectLine) + $sqlInventario | Where-Object { $_ -ne "" })

if ($script:ultimoCodigo -ne 0) {
    Write-Host "ERROR: fallo al inventariar. No se ha tocado nada."
    $out | ForEach-Object { Write-Host "  $_" }
    exit 1
}

$inv = Read-RsInventarioPurga -Salida $out
foreach ($k in ($inv.objetos.Keys | Sort-Object)) {
    Write-Host ("  {0,-16} {1,6}" -f $k, $inv.objetos[$k])
}
$total     = $inv.total
$conDatos  = $inv.conDatos
$vacias    = $inv.vacias
$ilegibles = $inv.ilegibles

# El inventario no devolvio una sola linea INV|. sqlplus dio exit 0 -pudo conectar-, asi que lo
# que ha fallado es la consulta. Sin esta guarda el flujo seguiria con total=0 y anunciaria "el
# esquema ya esta vacio" sobre un esquema del que no se ha leido nada.
if (-not $inv.leido) {
    Write-Host "ERROR: el inventario no devolvio ninguna linea. No se ha tocado nada."
    $out | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host ""
if ($conDatos -gt 0) {
    Write-Host "  ####################################################################"
    Write-Host ("  #  {0} TABLA(S) DE ESTE ESQUEMA CONTIENEN DATOS  (vacias: {1})" -f $conDatos, $vacias)
    Write-Host "  #  Si esperabas un esquema recien creado y vacio, PARA AQUI:"
    Write-Host "  #  te has equivocado de entorno, o alguien ya ha cargado informacion."
    Write-Host "  ####################################################################"
} else {
    Write-Host ("  Ninguna tabla contiene datos ({0} tablas, todas vacias)." -f $vacias)
}

if ($ilegibles -gt 0) {
    Write-Host ""
    Write-Host "  ####################################################################"
    Write-Host ("  #  {0} TABLA(S) NO SE HAN PODIDO COMPROBAR." -f $ilegibles)
    Write-Host "  #  El recuento de 'tablas con datos' de arriba NO es fiable: puede haber"
    Write-Host "  #  informacion en las tablas que no se han podido leer."
    Write-Host "  ####################################################################"
}

# La papelera cuenta para decidir si hay algo que hacer aunque no sume en `total`: un esquema
# cuyo unico contenido son objetos borrados sin PURGE sigue necesitando el PURGE RECYCLEBIN,
# y hasta entonces el CREATE de la reinstalacion puede chocar con ellos.
if ($total -eq 0 -and $inv.papelera -eq 0 -and $inv.indices -eq 0) {
    Write-Host ""
    Write-Host "El esquema ya esta vacio: no hay nada que purgar."
    exit 0
}

# --- Generar el .sql de borrado (se genera SIEMPRE; ejecutarlo es otra cosa) ----
if (-not $Salida) { $Salida = Join-Path $aqui ("purga-$schemaDecl-$Entorno.sql") }

$guardaSql = New-RsSqlPurga -Esquema $schemaDecl -EntornoNombre $Entorno -Db $dbName `
                             -Servidor $servidor -PatronPapelera $RS_PAT_PAPELERA `
                             -Generado (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

$dirSalida = Split-Path $Salida -Parent
if ($dirSalida -and !(Test-Path $dirSalida)) { New-Item -ItemType Directory -Path $dirSalida -Force | Out-Null }
$sinBom = New-Object Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Salida, $guardaSql, $sinBom)

Write-RsSeccion "Script de borrado"
Write-Host "Generado: $Salida"
# `total` son los DROP explicitos. Los indices se informan aparte porque casi todos respaldan
# una PK o una UNIQUE y caen con su tabla: sumarlos anunciaba "900 objetos" sobre 300 tablas.
Write-Host "Objetos que se van a borrar: $total  (mas $($inv.indices) indice(s), la mayoria caen con su tabla, y $($inv.papelera) en la papelera)"

if ($Simular) {
    Write-Host ""
    Write-Host "(-Simular: NO se ha borrado nada. Lee el .sql de arriba y, si estas de acuerdo,"
    Write-Host " vuelve a lanzar esto mismo sin -Simular.)"
    exit 0
}

# --- SALVAGUARDA 3: teclear el nombre del esquema -------------------------
Write-RsSeccion "Confirmacion"
Write-Host "Se van a BORRAR los $total objetos del esquema $schemaDecl"
Write-Host "en la BD $dbName ($servidor), entorno $Entorno."
if ($conDatos -gt 0) { Write-Host "$conDatos de esas tablas TIENEN DATOS." }
Write-Host "Esto no se puede deshacer."
Write-Host ""
$tecleado = Read-Host "Escribe el nombre del esquema para confirmar ($schemaDecl)"
if (-not (Test-RsConfirmacionPurga -Tecleado $tecleado -Esquema $schemaDecl)) {
    Write-Host "Lo tecleado no coincide con '$schemaDecl'. Cancelado, no se ha borrado nada."
    exit 1
}

Write-RsSeccion "Ejecutando la purga"
$out = Invoke-RsOracle -Lineas ($cab + @($connectLine, "SET SERVEROUTPUT ON SIZE UNLIMITED",
                                         "@`"$Salida`"", "EXIT SUCCESS") | Where-Object { $_ -ne "" })
$code = $script:ultimoCodigo
$out | ForEach-Object { Write-Host "  $_" }

$log = [IO.Path]::ChangeExtension($Salida, ".log")
$out | Out-File $log -Encoding UTF8
Write-Host ""
Write-Host "Log: $log"

if ($code -ne 0) {
    Write-Host "ERROR: la purga termino con codigo $code. Revisa el log y el inventario final."
    exit $code
}
Write-Host "Purga terminada. Comprueba que el inventario final esta a cero antes de reinstalar."
