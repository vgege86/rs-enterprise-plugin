<#
.SYNOPSIS
    Ejecuta, con parada al primer error, los scripts SQL que acompanan a este paquete
    (carpeta Scripts\ en instalacion limpia, scripts\ en un actualizador).

    Es el segundo paso de la instalacion: Instalar.ps1 copia ficheros y NO toca la BD;
    este script es el unico que escribe en la base de datos.

.DESCRIPTION
    QUE SCRIPTS SE EJECUTAN Y EN QUE ORDEN

    Si existe scripts.json junto a los .sql, MANDA EL MANIFIESTO: se ejecuta exactamente lo
    que declara, en el orden que declara. Si no existe, se descubren por convencion:

      1. <carpeta>\*.sql              DDL: RVERSIONES, creacion de tablas, scripts de tareas
      2. <carpeta>\Inserts\*.sql      tablas parametricas (instalacion limpia)
      3. <carpeta>\PorEntorno\99-RVERSIONES-<Entorno>.sql   fila base, solo la del -Entorno dado

    Las tandas 2 y 3 se saltan si su carpeta no existe (un actualizador solo trae la 1).
    Los ficheros que empiezan por "_" se ignoran, salvo "_PURGA-*.sql", que se ejecutan los
    primeros y SOLO con -Recargar.

    Formato de scripts.json:

      {
        "scripts": [
          { "ruta": "00-RVERSIONES.sql" },
          { "ruta": "Inserts/10-PARAMETRICAS.sql", "opcional": true },
          { "ruta": "PorEntorno/99-RVERSIONES-PROD.sql", "entorno": "PROD" },
          { "ruta": "_PURGA-IDIOMAS.sql", "purga": true }
        ]
      }

      ruta      relativa a la carpeta de scripts (admite / o \)
      opcional  si falta en disco, se avisa y se continua. Por defecto false: si un script
                obligatorio no esta, se aborta ANTES de conectar (una entrega incompleta no
                se empieza a medias)
      entorno   solo se ejecuta si coincide con -Entorno
      purga     solo se ejecuta con -Recargar, y va antes que el resto
      ejecutar  false = el fichero viaja en el paquete y NO se ejecuta. Es para los maestros
                que encadenan a otros (<Proyecto>-CreacionObjetos.sql, Inserts\_run_all.sql):
                sirven para lanzarlo todo a mano desde una sesion, pero ejecutarlos ADEMAS
                crearia cada objeto y cada fila dos veces. Declararlos asi evita tambien el
                aviso de "presente en disco y no declarado", que en su caso seria ruido

    Un .sql presente en disco pero NO declarado en el manifiesto se avisa y NO se ejecuta:
    lanzar SQL no declarado contra la BD de un cliente es peor que omitirlo, y el aviso
    destapa el olvido.

    CONEXION

    Datos en rutas.json -> entornos.<ENTORNO>.bd (motor, conexion, usuario, autenticacion).
    La contrasena NUNCA esta en el JSON ni en la linea de comandos: se pide por consola o se
    pasa con -Password, y viaja a la herramienta por fichero temporal (Oracle) o por variable
    de entorno (SQL Server). En la lista de procesos no aparece.

      ORACLE, autenticacion externa (wallet)  -> sqlplus /@<alias>, un unico argumento literal
      ORACLE, usuario/contrasena              -> sqlplus /nolog + CONNECT en fichero temporal
      SQLSERVER, autenticacion integrada      -> sqlcmd -E
      SQLSERVER, usuario/contrasena           -> sqlcmd -U + SQLCMDPASSWORD

    LOS DOS MODOS ESTAN SIEMPRE DISPONIBLES. Lo que dice rutas.json es una DECLARACION de
    quien preparo la entrega, no un hecho del servidor del cliente, asi que:

      - "autenticacion: wallet" se CONTRASTA con la maquina antes de conectar (TNS_ADMIN,
        sqlnet.ora, WALLET_LOCATION, cwallet.sso). Si hay constancia de que no hay wallet, no
        se intenta /@alias: se dice por que y se ofrece usuario/contrasena.
      - si rutas.json no declara ni 'autenticacion' ni 'usuario', el modo NO se supone: se
        resuelve por la evidencia de la maquina y se deja escrito cual se eligio.
      - si la conexion falla por credencial (ORA-01017 / ORA-12578 / "Login failed"), se
        ofrece reintentar con usuario y contrasena en vez de terminar. Sin consola
        (-SinConfirmar) no se pregunta: se sale con instrucciones para -Usuario / -Password.

    En Oracle con wallet, "conexion" es un ALIAS de tnsnames.ora, NO una cadena de conexion.
    El wallet indexa la credencial por el texto exacto del alias. Un descriptor
    "(DESCRIPTION=...)" o un EZConnect "host:puerto/servicio" ademas de no existir como
    credencial se parten por '/' y '@' en cuanto algo los trocea, y producen un ORA-12154 que
    parece un problema de red y no lo es. El script los rechaza antes de intentar conectar.

    Todo el output se guarda en <carpeta>\_ejecucion_<timestamp>.log.

.PARAMETER Entorno      DESA | TEST | PROD. Debe existir en rutas.json.
.PARAMETER Carpeta      Carpeta con los .sql. Default: Scripts\ o scripts\ junto a este script.
.PARAMETER RutasJson    Ruta del rutas.json. Default: el que acompana a este script.
.PARAMETER Manifiesto   Ruta del scripts.json. Default: el que haya en la carpeta de scripts.
.PARAMETER Usuario      Fuerza modo usuario/contrasena, ignorando lo que diga rutas.json.
.PARAMETER Password     Contrasena. Si se omite y hace falta, se pide por consola.
.PARAMETER TnsAdmin     Oracle: carpeta con sqlnet.ora / tnsnames.ora / wallet. Si se omite,
                        se usa el valor de rutas.json y, en su defecto, %TNS_ADMIN%.
.PARAMETER Schema       ALTER SESSION SET CURRENT_SCHEMA. El usuario del wallet muchas veces
                        no es el dueno de las tablas.
.PARAMETER NlsLang      Oracle: NLS_LANG a usar. Describe el encoding del FICHERO .sql, no el
                        de la BD. Precedencia: -NlsLang > %NLS_LANG% > AMERICAN_AMERICA.AL32UTF8.
.PARAMETER Recargar     Ejecuta tambien los scripts de purga (borrado previo). Opt-in.
.PARAMETER Simular      Comprueba entorno y conexion, lista lo que haria, y no escribe en la BD.
.PARAMETER SinConfirmar No pide confirmacion interactiva (ejecucion desatendida).
.PARAMETER DotSourceOnly  Uso interno de los tests: carga las funciones y no ejecuta nada.

.EXAMPLE
    .\Ejecutar-Scripts.ps1 -Entorno TEST -Simular
.EXAMPLE
    .\Ejecutar-Scripts.ps1 -Entorno PROD -TnsAdmin C:\oracle\wallet
.EXAMPLE
    # El servidor no tiene wallet aunque rutas.json diga que si: conexion por usuario.
    .\Ejecutar-Scripts.ps1 -Entorno PROD -Usuario RSPROYECTO
.EXAMPLE
    .\Ejecutar-Scripts.ps1 -Entorno PROD -Recargar -Schema RSPROYECTO -SinConfirmar
#>
param(
    [ValidateSet('DESA','TEST','PROD','')][string]$Entorno = "",
    [string]$Carpeta = "",
    [string]$RutasJson = "",
    [string]$Manifiesto = "",
    [string]$Usuario = "",
    [string]$Password = "",
    [string]$TnsAdmin = "",
    [string]$Schema = "",
    [string]$NlsLang = "",
    [switch]$Recargar,
    [switch]$Simular,
    [switch]$SinConfirmar,
    [switch]$DotSourceOnly
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# ===========================================================================
# Funciones puras. Estan arriba y sin efectos para que los tests puedan
# cargarlas con -DotSourceOnly y ejercitar los caminos de decision sin BD.
# ===========================================================================

function Write-RsSeccion([string]$t) { Write-Host ""; Write-Host "== $t ==" }

function Test-RsAliasTns {
    <#  Rechaza como alias lo que en realidad es una cadena de conexion.
        Devuelve $true si el valor sirve como alias de tnsnames.ora.  #>
    param([string]$Valor)
    if ([string]::IsNullOrWhiteSpace($Valor)) { return $false }
    $v = $Valor.Trim()
    if ($v.StartsWith('(')) { return $false }   # descriptor (DESCRIPTION=...)
    if ($v -match '[\s/@]')  { return $false }   # EZConnect u host/servicio
    if ($v -match ':\d')     { return $false }   # host:puerto
    return $true
}

function Resolve-RsNlsLang {
    <#  Precedencia: -NlsLang > %NLS_LANG% del entorno > default AL32UTF8.
        Nunca pisa incondicionalmente lo que el usuario tenga puesto.  #>
    param([string]$Parametro, [string]$Entorno)
    if (-not [string]::IsNullOrWhiteSpace($Parametro)) {
        return @{ valor = $Parametro.Trim(); origen = "-NlsLang" }
    }
    if (-not [string]::IsNullOrWhiteSpace($Entorno)) {
        return @{ valor = $Entorno.Trim(); origen = "entorno" }
    }
    return @{ valor = "AMERICAN_AMERICA.AL32UTF8"; origen = "default del script" }
}

function Test-RsNlsUtf8 {
    param([string]$Valor)
    return ($Valor -match '(?i)(AL32UTF8|UTF8)$')
}

function Resolve-RsWalletDir {
    <#  Normaliza el DIRECTORY de WALLET_LOCATION de sqlnet.ora.

        Oracle admite '?' como abreviatura de ORACLE_HOME. En Windows '?' es un caracter
        ILEGAL en rutas: sin expandirlo, Test-Path no devuelve $false, lanza
        ArgumentException y aborta el pre-vuelo entero. Por eso aqui se quitan comillas,
        se expande '?' si hay ORACLE_HOME, y si la ruta sigue sin ser comprobable se marca
        como tal para avisar y seguir, nunca reventar.  #>
    param([string]$Directory, [string]$OracleHome = "")
    $r = @{ ruta = ""; comprobable = $false }
    if ([string]::IsNullOrWhiteSpace($Directory)) { return $r }

    $d = $Directory.Trim().Trim('"').Trim("'").Trim()
    if ($d -match '\?' -and -not [string]::IsNullOrWhiteSpace($OracleHome)) {
        $d = $d.Replace('?', $OracleHome)
    }
    $d = $d.Replace('/', '\')
    $r.ruta = $d

    $ilegales = [System.IO.Path]::GetInvalidPathChars()
    $tieneIlegal = @($d.ToCharArray() | Where-Object { $ilegales -contains $_ }).Count -gt 0
    $r.comprobable = (-not $tieneIlegal) -and ($d -notmatch '\?|\*')
    return $r
}

function Get-RsScriptsManifiesto {
    <#  Resuelve la lista de scripts a partir del manifiesto.
        Devuelve @{ scripts = <FileInfo[]>; errores = <string[]>; avisos = <string[]> }.
        Un obligatorio ausente es ERROR (aborta antes de conectar); un opcional ausente,
        aviso. Un .sql en disco no declarado se avisa y no se ejecuta.  #>
    param([string]$RutaManifiesto, [string]$DirScripts, [string]$Entorno, [bool]$IncluirPurga)

    $res = @{ scripts = @(); errores = @(); avisos = @() }

    try {
        $json = Get-Content $RutaManifiesto -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $res.errores += "scripts.json no se puede leer o no es JSON valido: $($_.Exception.Message)"
        return $res
    }
    if (-not $json.scripts) {
        $res.errores += "scripts.json no declara ningun script (falta la clave 'scripts')."
        return $res
    }

    $declaradas = @()
    $purgas = @()
    $normales = @()

    foreach ($item in @($json.scripts)) {
        if (-not $item.ruta) { $res.avisos += "entrada del manifiesto sin 'ruta': se ignora."; continue }

        $rel = ([string]$item.ruta).Replace('/', '\').TrimStart('\')
        $abs = Join-Path $DirScripts $rel
        $declaradas += $rel.ToLowerInvariant()

        # ejecutar:false -> declarado (no sale como "no declarado") pero no se ejecuta. Va
        # ANTES del Test-Path a proposito: un maestro ausente no es una entrega incompleta,
        # porque nadie lo iba a lanzar.
        if ($item.PSObject.Properties.Name -contains 'ejecutar' -and $item.ejecutar -eq $false) { continue }

        # Filtro por entorno: la fila base de RVERSIONES solo se aplica a su entorno.
        if ($item.entorno -and ("$($item.entorno)").ToUpperInvariant() -ne $Entorno.ToUpperInvariant()) { continue }

        $esPurga = ($item.purga -eq $true)
        if ($esPurga -and -not $IncluirPurga) { continue }

        if (!(Test-Path $abs)) {
            if ($item.opcional -eq $true) {
                $res.avisos += "opcional declarado y ausente, se omite: $rel"
            } else {
                $res.errores += "declarado en scripts.json y AUSENTE en disco: $rel"
            }
            continue
        }

        if ($esPurga) { $purgas += (Get-Item $abs) } else { $normales += (Get-Item $abs) }
    }

    # Un .sql que viaja en el paquete pero nadie declaro: no se ejecuta, pero se dice.
    # La ruta se normaliza a '\' en los DOS lados: las declaradas ya vienen convertidas, y
    # aqui el separador lo pone el sistema de ficheros. Sin normalizar, toda ruta con
    # subcarpeta (Inserts\..., PorEntorno\...) se daba por no declarada fuera de Windows.
    foreach ($f in @(Get-ChildItem $DirScripts -Filter *.sql -File -Recurse -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($DirScripts.Length).TrimStart('\','/').Replace('/', '\')
        if ($declaradas -notcontains $rel.ToLowerInvariant()) {
            $res.avisos += "presente en disco y NO declarado en scripts.json, no se ejecuta: $rel"
        }
    }

    $res.scripts = @($purgas) + @($normales)
    return $res
}

function Get-RsScriptsConvencion {
    <#  Descubrimiento por convencion, el comportamiento historico: raiz, Inserts\ y la fila
        base de RVERSIONES del entorno pedido. Los "_" se ignoran salvo "_PURGA-*".  #>
    param([string]$DirScripts, [string]$Entorno, [bool]$IncluirPurga)

    $res = @{ scripts = @(); errores = @(); avisos = @() }

    function Get-Sql([string]$dir) {
        if (!(Test-Path $dir)) { return @() }
        return @(Get-ChildItem $dir -Filter *.sql -File |
                 Where-Object { -not $_.Name.StartsWith('_') } | Sort-Object Name)
    }

    $lista = @()

    if ($IncluirPurga) {
        $lista += @(Get-ChildItem $DirScripts -Filter '_PURGA-*.sql' -File -ErrorAction SilentlyContinue |
                    Sort-Object Name)
    }

    $lista += @(Get-Sql $DirScripts)
    $lista += @(Get-Sql (Join-Path $DirScripts "Inserts"))

    $porEntDir = Join-Path $DirScripts "PorEntorno"
    if (Test-Path $porEntDir) {
        $fEnt = Join-Path $porEntDir "99-RVERSIONES-$Entorno.sql"
        if (Test-Path $fEnt) { $lista += @(Get-Item $fEnt) }
        else {
            $res.avisos += "no hay 99-RVERSIONES-$Entorno.sql en PorEntorno: la instalacion quedara sin fila base en RVERSIONES y el primer actualizador de $Entorno no tendra fecha de partida para el delta."
        }
    }

    $res.scripts = $lista
    return $res
}

function New-RsTempSql {
    <#  Fichero temporal .sql SIN BOM: con BOM, sqlplus se come la primera sentencia.  #>
    param([string[]]$Lineas)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("rssql_" + [Guid]::NewGuid().ToString("N") + ".sql")
    $sinBom = New-Object Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($p, (($Lineas -join "`r`n") + "`r`n"), $sinBom)
    return $p
}

function Get-RsCabeceraSqlPlus {
    <#  WHENEVER SQLERROR/OSERROR EXIT FAILURE -> sin esto sqlplus devuelve 0 aunque falle.
        SET DEFINE OFF        -> un '&' dentro de un texto no es variable de sustitucion.
        SET SQLBLANKLINES ON  -> un literal con lineas en blanco, sin esto, corta la
                                 sentencia y da SP2-0042 o inserta el texto truncado.  #>
    return @(
        "WHENEVER SQLERROR EXIT FAILURE",
        "WHENEVER OSERROR EXIT FAILURE",
        "SET DEFINE OFF",
        "SET SQLBLANKLINES ON",
        "SET FEEDBACK OFF",
        "SET TRIMSPOOL ON"
    )
}

function Get-RsModoAutenticacion {
    <#  Resuelve si la conexion es externa (wallet / integrada) o usuario/contrasena.
        -Usuario en linea de comandos manda sobre rutas.json.

        Si rutas.json no declara NADA y ademas no hay usuario, NO se elige aqui: se devuelve
        "indeterminado" y lo resuelve el llamante contrastando la maquina. Devolver "externa"
        en ese caso -como se hacia antes- es afirmar que hay wallet sin haber mirado si
        existe: el connect salia como '/@alias', Oracle contestaba ORA-01017 y el script moria
        listando pistas de wallet sin haber ofrecido nunca usuario/contrasena.  #>
    param([string]$Declarado, [string]$UsuarioParam, [string]$UsuarioJson)
    if (-not [string]::IsNullOrWhiteSpace($UsuarioParam)) { return "usuario" }
    if (-not [string]::IsNullOrWhiteSpace($Declarado)) {
        if ($Declarado -match '(?i)^(wallet|externa|integrada)$') { return "externa" }
        return "usuario"
    }
    if ([string]::IsNullOrWhiteSpace($UsuarioJson)) { return "indeterminado" }
    return "usuario"
}

function Test-RsWalletDisponible {
    <#  Hay en ESTA maquina un wallet de auto-login utilizable?

        Recibe hechos ya comprobados por el pre-vuelo y no toca disco, para poder probarse sin
        Oracle. Devuelve @{ usable; comprobado; motivo }.

        Existe porque "autenticacion: wallet" en rutas.json es lo que declaro quien preparo la
        entrega, no una propiedad del servidor del cliente. Sin contrastarlo, un servidor sin
        wallet intenta igualmente '/@alias' y el ORA-01017 resultante se lee como "las
        credenciales del wallet estan mal" cuando lo que pasa es que no hay wallet.

        comprobado=$false significa "no se ha podido comprobar": entonces NO se bloquea nada
        -se deja decidir a sqlplus- y la red de seguridad es el reintento con usuario y
        contrasena al fallar la conexion. Solo se bloquea con constancia de ausencia.  #>
    param(
        [bool]$HayTnsAdmin,
        [bool]$HaySqlnet,
        [bool]$HayWalletLocation,
        [bool]$HaySso,
        [bool]$RutaComprobable = $true,
        [bool]$RutaExiste = $true
    )
    if (-not $HayTnsAdmin) {
        return @{ usable = $true; comprobado = $false
                  motivo = "sin TNS_ADMIN no hay nada que comprobar aqui; lo resolvera sqlplus" }
    }
    if (-not $HaySqlnet) {
        return @{ usable = $false; comprobado = $true
                  motivo = "hay TNS_ADMIN pero no sqlnet.ora: sin el, Oracle no sabe donde esta el wallet" }
    }
    if (-not $HayWalletLocation) {
        return @{ usable = $false; comprobado = $true
                  motivo = "sqlnet.ora no declara WALLET_LOCATION" }
    }
    if (-not $RutaComprobable) {
        return @{ usable = $true; comprobado = $false
                  motivo = "WALLET_LOCATION no es comprobable desde PowerShell; lo resolvera sqlplus" }
    }
    if (-not $RutaExiste) {
        return @{ usable = $false; comprobado = $true
                  motivo = "la carpeta de wallet declarada en sqlnet.ora no existe en esta maquina" }
    }
    if (-not $HaySso) {
        return @{ usable = $false; comprobado = $true
                  motivo = "falta cwallet.sso: el wallet no es de auto-login y sqlplus no puede abrirlo sin contrasena" }
    }
    return @{ usable = $true; comprobado = $true
              motivo = "sqlnet.ora con WALLET_LOCATION y cwallet.sso presentes" }
}

function Test-RsErrorCredenciales {
    <#  El fallo de conexion es de credencial y, por tanto, reintentable con usuario y
        contrasena? ORA-01017 (usuario/contrasena invalidos: en modo wallet significa que el
        wallet no aporta credencial para el alias), ORA-12578/ORA-28759 (wallet no abierto o no
        encontrado), ORA-01005 (sin contrasena) y el "Login failed" de SQL Server.

        Deliberadamente NO entra aqui ORA-12154 ni ORA-12560/12537: esos son resolucion de
        nombre y protocolo, y cambiar de modo de autenticacion no los arregla.  #>
    param([string]$Salida)
    return ($Salida -match 'ORA-01017|ORA-12578|ORA-28759|ORA-01005|Login failed|Error de inicio de sesi')
}

function ConvertFrom-RsSecureString {
    <#  SecureString -> texto plano, liberando el buffer intermedio.

        SecureStringToBSTR reserva memoria NO gestionada que el recolector de basura no toca:
        sin ZeroFreeBSTR la contrasena se queda en claro en el proceso hasta que termina. El
        texto que se devuelve sigue siendo un String normal -inevitable, sqlplus necesita la
        contrasena en claro-, pero no hay razon para dejar ademas una segunda copia que nadie
        va a limpiar. El finally cubre tambien el caso de que la conversion falle.

        Cadena vacia se normaliza a $null: "el operador pulso Enter" es una respuesta, y el
        llamante la distingue de una contrasena real.  #>
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

function Request-RsCredenciales {
    <#  Pide usuario y contrasena por consola. Devuelve @{ usuario; password } o $null si el
        operador no las da (Enter en blanco), que es una respuesta legitima: significa
        "no tengo credenciales", y el llamante termina con el diagnostico completo.  #>
    param([string]$UsuarioSugerido = "", [string]$Conexion = "", [string]$Motor = "")
    $u = $UsuarioSugerido
    if ($u) {
        $r = Read-Host "  Usuario [$u]"
        if ($r) { $u = $r.Trim() }
    } else {
        $u = (Read-Host "  Usuario").Trim()
    }
    if (-not $u) { return $null }
    $sec = Read-Host "  Password de $u@$Conexion ($Motor)" -AsSecureString
    $p   = ConvertFrom-RsSecureString -Segura $sec
    if (-not $p) { return $null }
    return @{ usuario = $u; password = $p }
}

if ($DotSourceOnly) { return }

# ===========================================================================
# Ejecucion
# ===========================================================================

if (-not $Entorno) { Write-Host "ERROR: falta -Entorno (DESA | TEST | PROD)."; exit 1 }

$paquete = $PSScriptRoot
if (-not $RutasJson) { $RutasJson = Join-Path $paquete "rutas.json" }
if (!(Test-Path $RutasJson)) { Write-Host "ERROR: no se encuentra rutas.json: $RutasJson"; exit 1 }

if (-not $Carpeta) {
    foreach ($c in @("Scripts", "scripts")) {
        $p = Join-Path $paquete $c
        if (Test-Path $p) { $Carpeta = $p; break }
    }
}
if (-not $Carpeta -or !(Test-Path $Carpeta)) { Write-Host "ERROR: no se encuentra la carpeta de scripts."; exit 1 }
$Carpeta = (Resolve-Path $Carpeta).Path

# --- Configuracion del entorno -------------------------------------------
$cfg = Get-Content $RutasJson -Raw -Encoding UTF8 | ConvertFrom-Json
$ent = $cfg.entornos.$Entorno
if (-not $ent -or -not $ent.bd) { Write-Host "ERROR: entorno '$Entorno' sin bloque 'bd' en rutas.json"; exit 1 }

$motor       = ("$($ent.bd.motor)").ToUpper()
$conexion    = "$($ent.bd.conexion)"
$usuarioJson = "$($ent.bd.usuario)"
$authJson    = "$($ent.bd.autenticacion)"
$modoAuth    = Get-RsModoAutenticacion -Declarado $authJson -UsuarioParam $Usuario -UsuarioJson $usuarioJson

if (-not $conexion) { Write-Host "ERROR: 'conexion' vacia para $Entorno en rutas.json"; exit 1 }
if ($motor -ne 'ORACLE' -and $motor -ne 'SQLSERVER') {
    Write-Host "ERROR: motor no soportado: '$motor' (usa ORACLE o SQLSERVER)"; exit 1
}

$usuarioEfectivo = if ($Usuario) { $Usuario } else { $usuarioJson }
if ($modoAuth -eq 'usuario' -and -not $usuarioEfectivo) {
    Write-Host "ERROR: autenticacion por usuario pero no hay 'usuario' en rutas.json ni -Usuario."; exit 1
}
if (-not $Schema -and $ent.bd.schema) { $Schema = "$($ent.bd.schema)" }

# --- Lista de scripts (manifiesto o convencion) --------------------------
if (-not $Manifiesto) {
    $posible = Join-Path $Carpeta "scripts.json"
    if (Test-Path $posible) { $Manifiesto = $posible }
}

if ($Manifiesto -and (Test-Path $Manifiesto)) {
    Write-Host "Manifiesto: $Manifiesto (manda sobre el descubrimiento por carpetas)"
    $plan = Get-RsScriptsManifiesto -RutaManifiesto $Manifiesto -DirScripts $Carpeta -Entorno $Entorno -IncluirPurga:([bool]$Recargar)
} else {
    $plan = Get-RsScriptsConvencion -DirScripts $Carpeta -Entorno $Entorno -IncluirPurga:([bool]$Recargar)
}

foreach ($a in $plan.avisos) { Write-Host "AVISO: $a" }
if ($plan.errores.Count -gt 0) {
    Write-Host ""
    foreach ($e in $plan.errores) { Write-Host "ERROR: $e" }
    Write-Host ""
    Write-Host "       La entrega esta incompleta. No se conecta a la BD: es preferible no"
    Write-Host "       empezar a dejar la base de datos a medias."
    exit 1
}

$scripts = @($plan.scripts)
if ($scripts.Count -eq 0) { Write-Host "AVISO: no hay scripts que ejecutar en $Carpeta."; exit 0 }

Write-RsSeccion "Plan de ejecucion - entorno $Entorno"
Write-Host "Carpeta: $Carpeta"
$i = 0
foreach ($s in $scripts) {
    $i++
    $rel = $s.FullName.Substring($Carpeta.Length).TrimStart('\','/')
    Write-Host ("  {0,2}. {1}  ({2:N0} bytes)" -f $i, $rel, $s.Length)
}
if ($Recargar) { Write-Host "  (-Recargar: se ejecutan tambien los scripts de purga; se BORRAN datos antes de insertar)" }
if ($Schema)   { Write-Host "  CURRENT_SCHEMA se fija a $Schema" }

# --- Entorno de conexion --------------------------------------------------
Write-RsSeccion "Entorno de conexion"
Write-Host "Motor     : $motor"
Write-Host "Conexion  : $conexion"
$txtModo = switch ($modoAuth) {
    'externa'  { if ($motor -eq 'ORACLE') { 'EXTERNA (wallet, sqlplus /@alias)' } else { 'INTEGRADA (sqlcmd -E)' } }
    'usuario'  { "USUARIO ($usuarioEfectivo)" }
    default    { 'SIN DECLARAR en rutas.json (se resuelve por evidencia de la maquina)' }
}
Write-Host "Modo      : $txtModo  [declarado en rutas.json: $(if ($authJson) { $authJson } else { '(nada)' })]"

# rutas.json declara wallet y ADEMAS un usuario: no es un error, pero es contradictorio y hay
# que decirlo. El usuario declarado se usa como sugerencia si hay que caer a usuario/contrasena.
if ($modoAuth -eq 'externa' -and $usuarioJson -and $motor -eq 'ORACLE') {
    Write-Host "AVISO: rutas.json declara autenticacion externa y ademas usuario '$usuarioJson'."
    Write-Host "       En modo wallet ese usuario NO se envia: la identidad la pone la credencial"
    Write-Host "       del wallet. Se usara como sugerencia si hay que conectar con contrasena."
}

# Evidencia de wallet recogida en el pre-vuelo. Se inicializa aqui para que la resolucion
# final de modo funcione tambien cuando el motor no es Oracle.
$evTnsAdmin = $false; $evSqlnet = $false; $evWalletLoc = $false
$evSso = $false; $evRutaComprobable = $true; $evRutaExiste = $true

if ($motor -eq 'ORACLE') {
    if (-not (Get-Command sqlplus -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: sqlplus no esta en el PATH. Instala el Oracle Client / Instant Client"
        Write-Host "       (paquete Basic + SQL*Plus) y anade su carpeta bin al PATH."
        exit 1
    }

    # Con wallet, 'conexion' tiene que ser un ALIAS. Se comprueba ANTES de conectar porque
    # un descriptor o un EZConnect dan ORA-12154, que parece de red y no lo es.
    if ($modoAuth -eq 'externa' -and -not (Test-RsAliasTns -Valor $conexion)) {
        Write-Host "ERROR: con wallet, 'conexion' debe ser un ALIAS de tnsnames.ora, no una cadena."
        Write-Host "       Recibido: $conexion"
        Write-Host "       Un descriptor '(DESCRIPTION=...)' o un EZConnect 'host:puerto/servicio' no"
        Write-Host "       sirven: la credencial se busca por el texto exacto del alias, y cualquier"
        Write-Host "       troceo por '/' o '@' rompe un descriptor TCPS -> ORA-12154."
        Write-Host "       Pon en rutas.json el nombre de la entrada de tnsnames.ora, o conecta con"
        Write-Host "       usuario y contrasena (-Usuario), que si admite cadena de conexion."
        exit 1
    }

    if (-not $TnsAdmin -and $ent.bd.tnsAdmin) { $TnsAdmin = "$($ent.bd.tnsAdmin)" }
    if ($TnsAdmin) {
        if (!(Test-Path $TnsAdmin)) { Write-Host "ERROR: no existe la carpeta TNS_ADMIN: $TnsAdmin"; exit 1 }
        $TnsAdmin = (Resolve-Path $TnsAdmin).Path
        $env:TNS_ADMIN = $TnsAdmin
    } elseif ($env:TNS_ADMIN) {
        $TnsAdmin = $env:TNS_ADMIN
    }
    $evTnsAdmin = [bool]$TnsAdmin
    Write-Host "TNS_ADMIN : $(if ($TnsAdmin) { $TnsAdmin } else { '(no definido - sqlplus usara el default del cliente Oracle)' })"

    # NLS_LANG describe el encoding del FICHERO .sql, no el de la BD. Los .sql se generan en
    # UTF-8: con otro NLS_LANG los acentos entran corruptos y Oracle NO da error, se descubre
    # al consultar. Se respeta lo que el usuario tenga puesto, pero se avisa.
    $nls = Resolve-RsNlsLang -Parametro $NlsLang -Entorno $env:NLS_LANG
    $env:NLS_LANG = $nls.valor
    Write-Host "NLS_LANG  : $($nls.valor)  ($($nls.origen))"

    if (-not (Test-RsNlsUtf8 -Valor $nls.valor)) {
        Write-Host ""
        Write-Host "AVISO: los .sql estan en UTF-8 y NLS_LANG no lo es. Los acentos se cargaran"
        Write-Host "       corruptos y Oracle NO dara ningun error: se ve despues, al consultar."
        Write-Host "       Lo esperado aqui es AMERICAN_AMERICA.AL32UTF8."
        if (-not $SinConfirmar) {
            $resp = Read-Host "       Continuar de todos modos? (s/N)"
            if ($resp -notmatch '^[SsYy]') { Write-Host "Cancelado."; exit 1 }
        }
    }

    if ($TnsAdmin) {
        $fSqlnet = Join-Path $TnsAdmin "sqlnet.ora"
        $fTns    = Join-Path $TnsAdmin "tnsnames.ora"

        if (Test-Path $fSqlnet) {
            $evSqlnet = $true
            $sqlnet = Get-Content $fSqlnet -Raw
            $tieneWalletLoc = $sqlnet -match '(?im)^\s*WALLET_LOCATION'
            $tieneOverride  = $sqlnet -match '(?im)WALLET_OVERRIDE\s*=\s*TRUE'
            $evWalletLoc = [bool]$tieneWalletLoc
            Write-Host "sqlnet.ora: OK  (WALLET_LOCATION: $(if($tieneWalletLoc){'si'}else{'NO'}) | WALLET_OVERRIDE=TRUE: $(if($tieneOverride){'si'}else{'NO'}))"
            if ($modoAuth -ne 'usuario' -and -not $tieneOverride -and $tieneWalletLoc) {
                Write-Host "AVISO: falta SQLNET.WALLET_OVERRIDE = TRUE - sin eso Oracle ignora las credenciales"
                Write-Host "       del wallet y pide usuario/contrasena."
            }

            if ($sqlnet -match '(?is)WALLET_LOCATION.*?DIRECTORY\s*=\s*([^\)\r\n]+)') {
                $w = Resolve-RsWalletDir -Directory $matches[1] -OracleHome $env:ORACLE_HOME
                Write-Host "Wallet    : $($w.ruta)"
                $evRutaComprobable = [bool]$w.comprobable
                if (-not $w.comprobable) {
                    Write-Host "AVISO: la ruta de WALLET_LOCATION no es comprobable desde PowerShell"
                    Write-Host "       ('?' de ORACLE_HOME sin expandir o caracteres ilegales)."
                    Write-Host "       Se omite la comprobacion de cwallet.sso; sqlplus la resolvera por su cuenta."
                    if (Test-Path (Join-Path $TnsAdmin "cwallet.sso")) {
                        Write-Host "       Hay cwallet.sso en TNS_ADMIN ($TnsAdmin): es la ubicacion que suele valer."
                    }
                }
                elseif (Test-Path $w.ruta) {
                    $sso = Test-Path (Join-Path $w.ruta "cwallet.sso")
                    $p12 = Test-Path (Join-Path $w.ruta "ewallet.p12")
                    $evSso = [bool]$sso
                    Write-Host "            cwallet.sso: $(if($sso){'si'}else{'NO'}) | ewallet.p12: $(if($p12){'si'}else{'NO'})"
                } else {
                    $evRutaExiste = $false
                }
            }
        } else {
            Write-Host "sqlnet.ora: NO ENCONTRADO en $TnsAdmin"
        }

        if (Test-Path $fTns) {
            $tns = Get-Content $fTns -Raw
            $aliasEsc = [regex]::Escape($conexion)
            if ($tns -match "(?im)^\s*$aliasEsc\s*(,|=)") { Write-Host "tnsnames  : alias '$conexion' encontrado" }
            else { Write-Host "AVISO: el alias '$conexion' no aparece en $fTns - revisar antes de ejecutar." }
        } else {
            Write-Host "AVISO: no hay tnsnames.ora en $TnsAdmin."
        }
    }
}
else {
    if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: sqlcmd no esta en el PATH. Instala las herramientas de linea de comandos"
        Write-Host "       de SQL Server (mssql-tools / SQL Server Command Line Utilities)."
        exit 1
    }
}

# --- Resolucion final del modo de conexion --------------------------------
# Lo que dice rutas.json es una DECLARACION de quien preparo la entrega. Aqui se contrasta con
# la maquina del cliente: si consta que no hay wallet, no se intenta '/@alias' -eso produce un
# ORA-01017 que se lee como "credenciales del wallet mal" cuando lo que falta es el wallet- y
# se ofrece la via de usuario/contrasena, que siempre esta disponible.
if ($motor -eq 'ORACLE') {
    $wallet = Test-RsWalletDisponible -HayTnsAdmin $evTnsAdmin -HaySqlnet $evSqlnet `
                  -HayWalletLocation $evWalletLoc -HaySso $evSso `
                  -RutaComprobable $evRutaComprobable -RutaExiste $evRutaExiste
} else {
    # SQL Server: la autenticacion integrada no tiene fichero que comprobar. Si no vale, lo
    # dira el "Login failed" y ahi se ofrece usuario/contrasena.
    $wallet = @{ usable = $true; comprobado = $false; motivo = "autenticacion integrada de Windows (no se comprueba de antemano)" }
}

if ($modoAuth -eq 'indeterminado') {
    # rutas.json no declara 'autenticacion' ni 'usuario'. No se supone nada: decide la evidencia.
    if ($motor -ne 'ORACLE') {
        $modoAuth = 'externa'
        Write-Host ""
        Write-Host "Modo resuelto: INTEGRADA. rutas.json no declara 'autenticacion' ni 'usuario' para"
        Write-Host "               $Entorno, y en SQL Server el default historico es -E."
    } elseif ($wallet.usable -and (Test-RsAliasTns -Valor $conexion)) {
        $modoAuth = 'externa'
        Write-Host ""
        Write-Host "Modo resuelto: EXTERNA (wallet). rutas.json no lo declara; se deduce de la maquina:"
        Write-Host "               $($wallet.motivo)."
    } else {
        $modoAuth = 'usuario'
        Write-Host ""
        Write-Host "Modo resuelto: USUARIO/CONTRASENA. rutas.json no declara 'autenticacion' ni"
        Write-Host "               'usuario' para $Entorno, y no consta wallet utilizable:"
        Write-Host "               $($wallet.motivo)."
        Write-Host "               Se piden las credenciales a continuacion."
    }
}

if ($modoAuth -eq 'externa' -and $motor -eq 'ORACLE' -and $wallet.comprobado -and -not $wallet.usable) {
    Write-Host ""
    Write-Host "AVISO: rutas.json declara autenticacion externa para $Entorno, pero en esta maquina"
    Write-Host "       NO hay wallet utilizable: $($wallet.motivo)."
    Write-Host "       Conectar con '/@$conexion' daria ORA-01017, que parece un problema de"
    Write-Host "       credenciales del wallet cuando lo que falta es el wallet entero."

    if ($Password -and ($usuarioEfectivo -or $Usuario)) {
        # Desatendido pero con credenciales completas en la linea de comandos: se usa lo que hay.
        $modoAuth = 'usuario'
        Write-Host "       Hay -Password y usuario '$usuarioEfectivo': se conecta con usuario/contrasena."
    } elseif ($SinConfirmar) {
        Write-Host ""
        Write-Host "ERROR: sin consola (-SinConfirmar) no se pueden pedir credenciales y no se va a"
        Write-Host "       intentar una conexion que consta que fallara."
        Write-Host "       Salidas: (a) instalar/copiar el wallet y dejar TNS_ADMIN apuntando a el,"
        Write-Host "                (b) relanzar con -Usuario <usuario> -Password <contrasena>,"
        Write-Host "                (c) corregir 'autenticacion' en rutas.json si ese entorno no usa wallet."
        exit 1
    } else {
        Write-Host ""
        Write-Host "       Se puede conectar con usuario y contrasena. Deja el usuario en blanco para"
        Write-Host "       cancelar y revisar el wallet."
        $cred = Request-RsCredenciales -UsuarioSugerido $usuarioEfectivo -Conexion $conexion -Motor $motor
        if ($cred) {
            $usuarioEfectivo = $cred.usuario
            $Password        = $cred.password
            $modoAuth        = 'usuario'
            Write-Host "Modo      : USUARIO ($usuarioEfectivo)  [rutas.json decia wallet]"
        } else {
            Write-Host ""
            Write-Host "ERROR: sin credenciales y sin wallet utilizable no hay forma de conectar."
            Write-Host "       Revisa el wallet (TNS_ADMIN, sqlnet.ora, cwallet.sso) o corrige"
            Write-Host "       'autenticacion' en rutas.json si $Entorno no usa wallet."
            exit 1
        }
    }
}

# --- Credenciales ---------------------------------------------------------
# Hacen falta TAMBIEN con -Simular: la simulacion conecta de verdad (comprueba usuario,
# CURRENT_SCHEMA y protocolo), lo unico que no hace es escribir. Sin ellas el CONNECT sale
# como 'usuario/@alias' -> SP2-0306 Invalid option, que no es fallo de wallet ni de red sino
# de sintaxis, y despista completamente.
if ($modoAuth -eq 'usuario' -and -not $usuarioEfectivo) {
    if ($SinConfirmar) {
        Write-Host "ERROR: modo usuario sin 'usuario'. Pasa -Usuario, o declara 'usuario' en rutas.json."
        exit 1
    }
    $usuarioEfectivo = (Read-Host "Usuario de $conexion ($motor)").Trim()
    if (-not $usuarioEfectivo) { Write-Host "ERROR: hace falta un usuario para conectar."; exit 1 }
}

if ($modoAuth -eq 'usuario' -and -not $Password) {
    $sec = Read-Host "Password de $usuarioEfectivo@$conexion ($motor)" -AsSecureString
    $Password = ConvertFrom-RsSecureString -Segura $sec
    if (-not $Password) {
        Write-Host "ERROR: en modo usuario hace falta contrasena. Pasa -Password, o usa"
        Write-Host "       autenticacion externa (wallet / integrada) si la BD lo permite."
        exit 1
    }
}

# En modo externo el alias va como UN solo argumento literal '/@alias': no se compone ni se
# trocea ninguna cadena. En modo usuario, /nolog + CONNECT dentro del fichero temporal, para
# que la contrasena no aparezca en la linea de comandos del proceso.
# Se recalcula en cada intento: si la conexion se reintenta cambiando de modo, estos dos
# valores tienen que cambiar con el, o el reintento repetiria el connect que ya fallo.
function Set-RsArgumentosConexion {
    $script:connectArg  = if ($modoAuth -eq 'externa') { "/@$conexion" } else { "/nolog" }
    $script:connectLine = if ($modoAuth -eq 'externa') { "" } else { "CONNECT $usuarioEfectivo/$Password@$conexion" }
}
Set-RsArgumentosConexion
$schemaLine = if ($Schema) { "ALTER SESSION SET CURRENT_SCHEMA = $Schema;" } else { "" }
$cabecera   = Get-RsCabeceraSqlPlus

function Invoke-RsSqlServer {
    <#  La contrasena va por SQLCMDPASSWORD, nunca por -P: con -P queda visible en la lista
        de procesos de la maquina del cliente.  #>
    param([string]$Fichero)
    # $argumentos, no $args: $args es variable automatica de PowerShell y asignarla dentro de
    # una funcion pisa los argumentos posicionales de la propia llamada.
    $argumentos = @('-S', $conexion, '-b', '-i', $Fichero)
    if ($modoAuth -eq 'externa') { $argumentos += '-E' } else { $argumentos += @('-U', $usuarioEfectivo) }
    if ($Schema) { $argumentos += @('-v', "SCHEMA=$Schema") }
    $previo = $env:SQLCMDPASSWORD
    try {
        if ($modoAuth -ne 'externa') { $env:SQLCMDPASSWORD = $Password }
        $salida = & sqlcmd @argumentos 2>&1
        $script:ultimoCodigo = $LASTEXITCODE
        return $salida
    } finally {
        $env:SQLCMDPASSWORD = $previo
    }
}

function Invoke-RsOracle {
    param([string[]]$Lineas)
    $tmp = New-RsTempSql -Lineas $Lineas
    try {
        $salida = & sqlplus -L -S $connectArg "@$tmp" 2>&1
        $script:ultimoCodigo = $LASTEXITCODE
        return $salida
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# --- Prueba de conexion, antes de tocar nada ------------------------------
# Va en bucle porque un fallo de credencial NO es el final: puede ser que la entrega declarase
# wallet y esta maquina no lo tenga, o que la contrasena se haya tecleado mal. En ambos casos
# hay una salida y se ofrece, en vez de terminar con pistas de wallet.
Write-RsSeccion "Prueba de conexion"
$maxIntentos = 3
$intento = 0
$out = @(); $code = 1; $salida = ""

while ($true) {
    $intento++
    Set-RsArgumentosConexion

    if ($motor -eq 'ORACLE') {
        $out = Invoke-RsOracle -Lineas (@($cabecera[0], $cabecera[1]) + @(
            $connectLine,
            "SET PAGESIZE 0 FEEDBACK OFF HEADING OFF VERIFY OFF",
            "SELECT 'CONEXION_OK|'||USER||'|'||SYS_CONTEXT('USERENV','CURRENT_SCHEMA')||'|'||SYS_CONTEXT('USERENV','DB_NAME')||'|'||SYS_CONTEXT('USERENV','NETWORK_PROTOCOL') FROM DUAL;",
            "EXIT SUCCESS"
        ) | Where-Object { $_ -ne "" })
    } else {
        $tmp = New-RsTempSql -Lineas @(
            "SET NOCOUNT ON;",
            "SELECT 'CONEXION_OK|'+SUSER_NAME()+'|'+SCHEMA_NAME()+'|'+DB_NAME()+'|'+ISNULL(CONVERT(varchar(30),CONNECTIONPROPERTY('net_transport')),'?');"
        )
        try { $out = Invoke-RsSqlServer -Fichero $tmp } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    $code   = $script:ultimoCodigo
    $salida = ($out -join "`n")
    $out | ForEach-Object { Write-Host "  $_" }

    if ($code -eq 0 -and $salida -match 'CONEXION_OK') { break }

    Write-Host ""

    # SP2-xxxx es sqlplus rechazando el comando ANTES de intentar conectar: es sintaxis del
    # CONNECT, no wallet, no red, no credenciales. Las pistas ORA-* de abajo solo confunden.
    if ($salida -match 'SP2-0306|SP2-0640|SP2-0157') {
        Write-Host "ERROR: sqlplus rechazo la sintaxis del CONNECT (SP2-xxxx), no llego a conectar."
        Write-Host "       No es un problema de wallet, red ni credenciales."
        if ($modoAuth -ne 'externa') {
            Write-Host "       Modo usuario sin contrasena: el connect sale como '$usuarioEfectivo/@$conexion'."
            Write-Host "       Reejecuta pasando -Password, o deja que el script la pida por consola."
        } else {
            Write-Host "       Modo wallet: revisa que 'conexion' no lleve espacios ni comillas sobrantes."
        }
        exit 1
    }

    # Fallo de credencial: hay otra via. Se ofrece antes de rendirse.
    if ((Test-RsErrorCredenciales -Salida $salida) -and -not $SinConfirmar -and $intento -lt $maxIntentos) {
        if ($modoAuth -eq 'externa') {
            Write-Host "La autenticacion externa no ha servido para conectar."
            if ($motor -eq 'ORACLE') {
                Write-Host "  Un ORA-01017 en este modo NO significa que el usuario o la contrasena sean"
                Write-Host "  malos: en modo wallet no se envia ninguna contrasena. Significa que el wallet"
                Write-Host "  no aporta credencial para el alias '$conexion', o que no hay wallet."
            }
            Write-Host "  Se puede conectar con usuario y contrasena. Enter en blanco para no hacerlo."
        } else {
            Write-Host "Las credenciales no han sido validas. Puedes volver a introducirlas"
            Write-Host "  (intento $intento de $maxIntentos). Enter en blanco para no reintentar."
        }

        $cred = Request-RsCredenciales -UsuarioSugerido $usuarioEfectivo -Conexion $conexion -Motor $motor
        if ($cred) {
            $usuarioEfectivo = $cred.usuario
            $Password        = $cred.password
            $modoAuth        = 'usuario'
            Write-Host ""
            Write-Host "Reintentando como $usuarioEfectivo@$conexion (usuario/contrasena)..."
            continue
        }
        Write-Host ""
    }

    Write-Host "ERROR: no se ha podido conectar (exit $code)."
    if ($motor -eq 'ORACLE') {
        if ($modoAuth -eq 'externa') {
            if ($wallet.comprobado -and -not $wallet.usable) {
                Write-Host "  En esta maquina NO consta wallet utilizable: $($wallet.motivo)."
                Write-Host "  Relanza con -Usuario <usuario> (te pedira la contrasena), o instala el wallet."
            } else {
                Write-Host "  Pistas segun el error de arriba (modo WALLET, no se envio contrasena):"
                Write-Host "  ORA-01017 : el wallet no aporta credencial para ese alias. Comprobar"
                Write-Host "              'mkstore -wrl <wallet> -listCredential' y que el alias coincida EXACTO."
                Write-Host "              Si esa BD no usa wallet, relanza con -Usuario <usuario>."
                Write-Host "  ORA-12154 : el alias no se resuelve. Revisar TNS_ADMIN y que '$conexion' este en"
                Write-Host "              tnsnames.ora. Con wallet hay que usar el ALIAS, nunca el descriptor"
                Write-Host "              completo ni host:puerto/servicio."
                Write-Host "  ORA-12578 : wallet no abierto / cwallet.sso ausente o sin permisos de lectura."
                Write-Host "  ORA-28759 : Oracle no encuentra el wallet (WALLET_LOCATION mal en sqlnet.ora)."
                Write-Host "  ORA-12560/12537 : protocolo. En TCPS el wallet es tambien el almacen de"
                Write-Host "              certificados; revisar que el descriptor del alias use PROTOCOL=TCPS."
            }
        } else {
            Write-Host "  Pistas segun el error de arriba (modo USUARIO '$usuarioEfectivo'):"
            Write-Host "  ORA-01017 : usuario o contrasena incorrectos para '$conexion'. Ojo al usuario:"
            Write-Host "              el dueno del esquema y el de conexion no siempre son el mismo."
            Write-Host "  ORA-28000/28001 : cuenta bloqueada o contrasena caducada. Lo arregla el DBA."
            Write-Host "  ORA-12154 : el alias/cadena de conexion no se resuelve. Revisar TNS_ADMIN."
            Write-Host "  ORA-12560/12537 : protocolo. Revisar host, puerto y si la BD exige TCPS."
        }
    } else {
        Write-Host "  'Login failed' con -E = el usuario de Windows que ejecuta esto no tiene acceso."
        Write-Host "  Relanza con -Usuario <usuario> para conectar con usuario y contrasena de SQL Server."
    }
    exit $(if ($code -ne 0) { $code } else { 1 })
}

$infoConn = ($out | Where-Object { $_ -match 'CONEXION_OK' } | Select-Object -First 1)
$campos = ("$infoConn".Trim() -split '\|')
Write-Host ""
Write-Host ("Conectado. Usuario: {0} | CURRENT_SCHEMA: {1} | BD: {2} | Protocolo: {3}" -f $campos[1], $campos[2], $campos[3], $campos[4])
Write-Host ("Autenticacion usada: {0}" -f $(if ($modoAuth -eq 'externa') { if ($motor -eq 'ORACLE') { 'EXTERNA (wallet)' } else { 'INTEGRADA (-E)' } } else { "USUARIO ($usuarioEfectivo)" }))

if ($Simular) {
    Write-Host ""
    Write-Host "(-Simular: conexion verificada, no se ha escrito nada en la BD)"
    exit 0
}

if (-not $SinConfirmar) {
    Write-Host ""
    $resp = Read-Host "Ejecutar los $($scripts.Count) scripts sobre $($campos[1])@$conexion (BD $($campos[3])) ? (S/N)"
    if ($resp -notmatch '^[SsYy]') { Write-Host "Cancelado por el usuario."; exit 0 }
}

# --- Ejecucion, fail-fast -------------------------------------------------
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$log   = Join-Path $Carpeta "_ejecucion_$stamp.log"
"== Ejecucion $stamp - entorno $Entorno - $motor - $conexion - usuario $($campos[1]) - schema $($campos[2]) - modo $modoAuth ==" |
    Out-File $log -Encoding UTF8

$ok = 0
foreach ($s in $scripts) {
    $rel = $s.FullName.Substring($Carpeta.Length).TrimStart('\','/')
    Write-Host ""
    Write-Host "--- $rel ---"
    "`n--- $rel ---" | Out-File $log -Append -Encoding UTF8

    if ($motor -eq 'ORACLE') {
        $out = Invoke-RsOracle -Lineas ($cabecera + @($connectLine, $schemaLine, "@`"$($s.FullName)`"", "EXIT SUCCESS") |
                                        Where-Object { $_ -ne "" })
    } else {
        $out = Invoke-RsSqlServer -Fichero $s.FullName
    }
    $code = $script:ultimoCodigo

    $out | ForEach-Object { Write-Host "  $_" }
    $out | Out-File $log -Append -Encoding UTF8

    if ($code -ne 0) {
        Write-Host ""
        Write-Host "ERROR: $rel fallo (exit $code). Se detiene la ejecucion."
        Write-Host "       Scripts correctos antes del fallo: $ok de $($scripts.Count)."
        Write-Host "       ORA-00001 / clave duplicada = los datos ya estaban cargados:"
        Write-Host "       relanzar con -Recargar si el paquete trae scripts de purga."
        Write-Host "Log: $log"
        exit $code
    }
    $ok++
    Write-Host "OK - $rel"
}

Write-Host ""
Write-Host "== $ok/$($scripts.Count) scripts ejecutados correctamente =="
Write-Host "Log: $log"
