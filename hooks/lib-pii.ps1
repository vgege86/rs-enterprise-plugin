<#
.SYNOPSIS
    Deteccion de datos personales por FORMA, compartida entre la guarda de escritura
    (pii-guard-write.ps1) y el saneado del registro de ejecuciones (log-execution.ps1).
    Unico sitio que conoce estos patrones y el checksum DNI/NIE -- dot-sourcear desde
    quien lo necesite (mismo patron que hooks/lib-dbconfig.ps1, ver hooks/db-query.ps1).

.DESCRIPTION
    DNI y NIE no se detectan por forma sola: se exige letra de control valida
    ("TRWAGMYFPDXBNJZSQVHLCKE"[numero % 23]) porque el repositorio esta lleno de
    cadenas AAAAMMDD (convencion Actualizador\<ENTORNO>_<AAAAMMDD>) que casan la forma
    "8 digitos + letra" por pura casualidad. Sin la validacion, cualquier guarda o
    saneado que use esta forma se dispara a diario contra el propio repo.

    IBAN y correo se detectan solo por forma, sin checksum: ya son lo bastante
    distintivos.

    Telefono y tarjeta quedan fuera a proposito (no de scripts/pii_detect.py, que sigue
    intacto): son puramente numericos y casan con cualquier importe en centimos o
    identificador de fila largo. Esta correccion se aplico primero en la guarda de
    escritura (Task 7) y se repite aqui por el mismo motivo -- ver Remove-RsPii mas
    abajo.
#>

function Repair-RsTextoUtf8 {
    <# Recupera el texto UTF-8 original de un evento que PowerShell ya ha descodificado
       con la pagina de codigos equivocada. Idempotente: si el texto ya esta bien, lo
       devuelve tal cual.

       Por que hace falta. Claude Code lanza las dos guardas PreToolUse con
       "powershell -File" y les pasa el JSON del evento en UTF-8 por stdin. Con -File,
       PowerShell engancha esa stdin al pipeline del script, y @($input) la descodifica
       con [Console]::InputEncoding: en un Windows con locale espanola, la pagina OEM
       (cp850). Una ruta o un contenido con acentos llegaba destrozado ("Jose" con e
       acentuada -> mojibake) al mensaje de bloqueo. Los patrones de DNI/NIE/IBAN/correo
       son ASCII y una descodificacion de un solo byte preserva los bytes ASCII, asi que
       NO se dejaba de bloquear nada: lo que salia mal era el texto que lee el usuario.

       Por que no se arregla fijando [Console]::InputEncoding a UTF-8 al principio del
       script: PowerShell lee la stdin en otro hilo desde el arranque, asi que la
       asignacion compite con esa lectura. Medido: unas veces gana y otras no. Un arreglo
       que sale bien la mayoria de las veces es peor que ninguno, porque nadie vuelve a
       mirarlo. Tampoco sirve leer el handle crudo ([Console]::OpenStandardInput) por
       delante: con -File PowerShell ya se ha quedado la stdin y esa lectura da vacio.

       Lo que se hace es deshacer la descodificacion: re-codificar con la MISMA pagina que
       la produjo y volver a descodificar como UTF-8 estricto. Las paginas OEM son mapeos
       completos de un byte, asi que ese viaje es exacto. El UTF-8 estricto es lo que hace
       la funcion segura en los dos sentidos: si el texto ya era correcto, sus bytes en la
       pagina OEM no forman UTF-8 valido, GetString lanza y se devuelve el original.

       -Origen es la pagina con la que se descodifico, por defecto la que usa PowerShell
       para la stdin. Se puede pasar para probar la funcion sin depender de la consola de
       la maquina que ejecute la suite. #>
    param(
        [AllowEmptyString()][string]$Texto,
        [System.Text.Encoding]$Origen = $null
    )

    if (-not $Texto) { return $Texto }
    # Todo ASCII: no hay nada que recuperar y no tiene sentido arriesgar el viaje.
    if ($Texto -notmatch '[^\x00-\x7F]') { return $Texto }
    if (-not $Origen) { $Origen = [Console]::InputEncoding }
    try {
        $bytes = $Origen.GetBytes($Texto)
        # $true final = throwOnInvalidBytes: sin el, GetString mete U+FFFD y devolveria
        # basura como si fuera una recuperacion buena.
        $utf8Estricto = New-Object System.Text.UTF8Encoding($false, $true)
        return $utf8Estricto.GetString($bytes)
    } catch {
        return $Texto
    }
}

function Read-RsStdinUtf8 {
    <# Lee la stdin del PROCESO entera y la descodifica como UTF-8 explicitamente.

       Camino de respaldo para cuando $input viene vacio (p.ej. "pwsh -Command"): ahi
       PowerShell no ha consumido la stdin y se puede leer el handle. Se descodifica sin
       depender de [Console]::InputEncoding por si Set-RsStdinUtf8 no pudo fijarla. El
       $true final del StreamReader es detectEncodingFromByteOrderMarks: si el emisor
       antepone un BOM (PowerShell 5.1 lo hace al canalizar hacia un comando nativo) no
       acaba dentro del texto rompiendo ConvertFrom-Json. #>
    $flujo  = [Console]::OpenStandardInput()
    $lector = New-Object System.IO.StreamReader($flujo, (New-Object System.Text.UTF8Encoding($false)), $true)
    try   { return $lector.ReadToEnd() }
    finally { $lector.Dispose() }
}

$script:RsPiiPatronDni    = '\b\d{8}[A-HJ-NP-TV-Z]\b'
$script:RsPiiPatronNie    = '\b[XYZ]\d{7}[A-HJ-NP-TV-Z]\b'
$script:RsPiiPatronIban   = '\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b'
$script:RsPiiPatronCorreo = '\b[^@\s]+@[^@\s]+\.[A-Za-z]{2,}\b'

function Test-DniNieChecksum {
    <# Valida la letra de control de un DNI (8 digitos + letra) o un NIE (X/Y/Z + 7
       digitos + letra). $Valor debe venir ya recortado a la forma exacta (sin \b
       alrededor). #>
    param([Parameter(Mandatory=$true)][string]$Valor)

    $letras = "TRWAGMYFPDXBNJZSQVHLCKE"
    $v = $Valor.ToUpper()

    if ($v -match '^(\d{8})([A-Z])$') {
        $numero = [int]$Matches[1]
        $letra  = $Matches[2]
        return ($letras[$numero % 23] -eq $letra)
    }
    if ($v -match '^([XYZ])(\d{7})([A-Z])$') {
        $prefijos = @{ "X" = "0"; "Y" = "1"; "Z" = "2" }
        $numero   = [int]("$($prefijos[$Matches[1]])$($Matches[2])")
        $letra    = $Matches[3]
        return ($letras[$numero % 23] -eq $letra)
    }
    return $false
}

function Remove-RsPii {
    <# Sustituye por el literal [PII] las formas de dato personal detectadas en $Texto.
       Nunca emite el valor original. DNI/NIE solo se sustituyen si la letra de control
       es valida (ver cabecera); IBAN y correo se sustituyen por forma sola. #>
    param([string]$Texto)
    if (-not $Texto) { return $Texto }

    $evaluadorDniNie = { param($m) if (Test-DniNieChecksum $m.Value) { "[PII]" } else { $m.Value } }
    $Texto = [regex]::Replace($Texto, $script:RsPiiPatronDni, $evaluadorDniNie)
    $Texto = [regex]::Replace($Texto, $script:RsPiiPatronNie, $evaluadorDniNie)
    $Texto = $Texto -creplace $script:RsPiiPatronIban, '[PII]'
    $Texto = $Texto -creplace $script:RsPiiPatronCorreo, '[PII]'
    return $Texto
}

# Resolucion del modelo BD: una sola implementacion, la de lib-dbconfig.ps1 (Get-RsModelPath es
# "el unico sitio que resuelve el campo model"). Se carga solo si quien nos dot-sourcea no la
# traia ya -- check-env.ps1 carga las dos librerias.
if (-not (Get-Command Get-RsModelPath -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "lib-dbconfig.ps1")
}

# Lectura DIRIGIDA del modo: el modelo pesa entre 288 KB y 664 KB en workspaces reales y esto
# corre en CADA Bash y CADA Write. Medido sobre un modelo de 1,3 MB: 12 ms con esta regex
# contra 135 ms con ConvertFrom-Json, y en Windows PowerShell 5.1 la diferencia es mayor
# (su parser JSON es mucho mas lento que el de PS7). No se parsea el modelo entero para leer
# un campo. La contrapartida es que la regex puede no entender una forma que el parser si
# entenderia: por eso "hay bloque pii_policy y no consigo leer el modo" NO degrada a off
# (ver Get-RsPiiModoDeModelo), y por eso check-env.ps1 contrasta esta lectura con el parseo
# completo que ya hace, y avisa si discrepan.
$script:RsPiiRxPolicy = [regex]::new('"pii_policy"\s*:', 'IgnoreCase')
$script:RsPiiRxModo   = [regex]::new('"pii_policy"\s*:\s*\{[^{}]*?"mode"\s*:\s*"\s*(off|audit|enforce)\s*"', 'IgnoreCase')

function Find-RsWorkspaceRaiz {
    <# Sube desde $Desde hasta encontrar docs\.rs-databases.json. "" si no aparece.

       Es lo que decide si una operacion cae DENTRO de un workspace uCollect/RS. Fuera de uno
       las guardas no se activan: el plugin no tiene nada que decir sobre los otros repos del
       usuario, y ese era el precio de que vivieran en la configuracion personal.

       Misma expresion "docs\.rs-databases.json" que Read-RsDatabases a proposito: si una
       usara separador nativo y la otra no, en un sistema no-Windows encontrarian ficheros
       distintos. Que las dos coincidan importa mas que cual de las dos es mas portable. #>
    param([AllowEmptyString()][string]$Desde)

    if (-not $Desde) { return "" }
    try { $p = [System.IO.Path]::GetFullPath($Desde) } catch { return "" }
    # Un fichero -- o una ruta que todavia no existe, que es el caso normal en Write -- no es
    # por donde se empieza a subir: se empieza por su carpeta.
    if (-not (Test-Path -LiteralPath $p -PathType Container)) {
        try { $p = [System.IO.Path]::GetDirectoryName($p) } catch { return "" }
    }
    $saltos = 0
    while ($p -and $saltos -lt 40) {
        if (Test-Path -LiteralPath (Join-Path $p "docs\.rs-databases.json")) { return $p }
        $padre = ""
        try { $padre = [System.IO.Path]::GetDirectoryName($p) } catch { }
        if (-not $padre -or $padre -eq $p) { break }
        $p = $padre
        $saltos++
    }
    return ""
}

function Get-RsPiiModoDeModelo {
    <# Modo declarado en un modelo BD: off | audit | enforce | indeterminado | ausente.

       'ausente' = el fichero no esta; lo resuelve quien llama, porque la respuesta depende de
       si la conexion DECLARA su modelo (Test-RsModelDeclarado) o cae al convenio -- la misma
       distincion que ya aplica db_query.

       'indeterminado' = hay bloque pii_policy y no se ha podido leer el modo. NO se degrada a
       off a proposito: un modelo con politica que no se entiende es un workspace roto, y
       tratarlo como "sin politica" es exactamente el fallo silencioso que este sistema existe
       para evitar. Sin bloque pii_policy si es off: ese es el workspace ordinario que nunca
       configuro nada, y es lo que garantiza que actualizar no cambie el comportamiento. #>
    param([AllowEmptyString()][string]$ModelPath)

    if (-not $ModelPath) { return "indeterminado" }
    if (-not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) { return "ausente" }
    try { $texto = [System.IO.File]::ReadAllText($ModelPath) } catch { return "indeterminado" }
    $m = $script:RsPiiRxModo.Match($texto)
    if ($m.Success) { return $m.Groups[1].Value.ToLower() }
    if ($script:RsPiiRxPolicy.IsMatch($texto)) { return "indeterminado" }
    return "off"
}

function Get-RsPiiEstadoGuarda {
    <# Decide si las guardas PreToolUse deben actuar sobre una operacion, a partir de la ruta
       que la origina. Devuelve @{ activa; modo; motivo; workspace }.

       Las guardas siguen al modo del WORKSPACE, no a la maquina: lo normal en desarrollo es
       tenerlas desactivadas, y se encienden solo en el workspace cuya BD tiene datos reales.

       | Situacion                                   | Guarda   |
       |---------------------------------------------|----------|
       | Fuera de un workspace RS                    | inactiva |
       | Dentro, modo off                            | inactiva |
       | Dentro, modo audit o enforce                | ACTIVA   |
       | Dentro, modo indeterminado (workspace roto) | ACTIVA   |

       La ultima fila es la que evita que esto sea un agujero: un modelo declarado y ausente, o
       una config ilegible, no degradan a "sin proteccion". Es el mismo criterio que aplica
       db_query, que falla cerrado justo ahi.

       Con VARIAS conexiones manda la mas restrictiva: la guarda de Bash no puede saber a que
       BD apunta un comando, asi que un workspace con PROD en enforce y DEV en off tiene que
       bloquear igual. #>
    param([AllowEmptyString()][string]$Desde)

    $ws = Find-RsWorkspaceRaiz $Desde
    if (-not $ws) {
        return @{ activa = $false; modo = "fuera"; workspace = ""
                  motivo = "la operacion no cae dentro de un workspace uCollect/RS" }
    }

    $cfg = Read-RsDatabases -Workspace $ws
    if (-not $cfg.ok) {
        return @{ activa = $true; modo = "indeterminado"; workspace = $ws
                  motivo = "workspace RS con la config de BD ilegible: $($cfg.error)" }
    }

    $rango = @{ "off" = 0; "audit" = 1; "enforce" = 2; "indeterminado" = 3 }
    $peor  = "off"
    foreach ($c in @($cfg.conexiones)) {
        $modo = Get-RsPiiModoDeModelo (Get-RsModelPath -Workspace $ws -Conexion $c -Proyecto $cfg.proyecto)
        if ($modo -eq "ausente") {
            # Declarado y ausente = workspace roto; convenio y ausente = nunca configuro nada.
            $modo = if (Test-RsModelDeclarado $c) { "indeterminado" } else { "off" }
        }
        if ($rango[$modo] -gt $rango[$peor]) { $peor = $modo }
    }

    $motivo = switch ($peor) {
        "off"           { "el workspace declara pii_policy.mode = off" }
        "audit"         { "el workspace esta en audit" }
        "enforce"       { "el workspace esta en enforce" }
        "indeterminado" { "el workspace declara una politica que no se puede leer" }
    }
    return @{ activa = ($rango[$peor] -ge 1); modo = $peor; workspace = $ws; motivo = $motivo }
}

function Get-RsPiiGuardRuta {
    <# Extrae del comando de un hook la ruta del .ps1 de la guarda ($Script). "" si no
       aparece. Prueba primero la forma entrecomillada, que es la que escribe /rs-pii
       enforce y la unica que soporta rutas con espacios ("C:\Mis Cosas\hooks\..."). #>
    param([string]$Comando, [string]$Script)

    $esc = [regex]::Escape($Script)
    $m = [regex]::Match($Comando, '"([^"]*' + $esc + ')"')
    if (-not $m.Success) { $m = [regex]::Match($Comando, '([^\s"]*' + $esc + ')') }
    if (-not $m.Success) { return "" }
    return $m.Groups[1].Value
}

function Test-RsPiiGuardRuta {
    <# Clasifica la ruta registrada de una guarda. Devuelve @{ efectiva; motivo; ruta }.

       Registrada != efectiva, y la diferencia importa: si el .ps1 no esta donde dice la
       entrada, Claude Code lanza el hook, powershell sale con error y ese codigo NO es 2
       -- el unico que bloquea. La guarda falla ABIERTA y nada lo delata. Ver la cabecera
       de Test-RsPiiGuards. #>
    param([string]$Ruta)

    if (-not $Ruta) {
        return @{ efectiva = $false; motivo = "el comando no nombra el .ps1 de la guarda"; ruta = "" }
    }
    # ${CLAUDE_PLUGIN_ROOT}, %VAR% o $env:VAR sin expandir: Claude Code solo sustituye
    # ${CLAUDE_PLUGIN_ROOT} en .claude-plugin/plugin.json y .mcp.json; en settings.json
    # llega literal y el hook apunta a una carpeta que no existe.
    if ($Ruta -match '\$\{|\$env:|%[A-Za-z_][A-Za-z0-9_]*%') {
        return @{ efectiva = $false; motivo = "la ruta lleva una variable sin expandir"; ruta = $Ruta }
    }
    $rooted = $false
    try { $rooted = [System.IO.Path]::IsPathRooted($Ruta) } catch { }
    if (-not $rooted) {
        # Relativa: se resolveria contra el directorio de trabajo de Claude Code, que no
        # se conoce desde aqui. No verificable = no se puede afirmar que protege.
        return @{ efectiva = $false; motivo = "la ruta es relativa y no se puede verificar"; ruta = $Ruta }
    }
    if (-not (Test-Path -LiteralPath $Ruta -PathType Leaf)) {
        return @{ efectiva = $false; motivo = "el fichero no existe"; ruta = $Ruta }
    }
    return @{ efectiva = $true; motivo = ""; ruta = $Ruta }
}

function Get-RsPiiGuardsManifiesto {
    <# Las dos guardas declaradas por el propio plugin en .claude-plugin/plugin.json.
       Devuelve @{ bash = @{efectiva; ruta; motivo}; write = ... }.

       Esta es la fuente de verdad desde 3.4.0. Antes se registraban a mano en
       ~/.claude/settings.json, donde ${CLAUDE_PLUGIN_ROOT} NO se expande: /rs-pii enforce
       tenia que cablear la ruta absoluta, y el cache de plugins de Claude Code lleva la
       VERSION en la ruta
       (~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/hooks/...). O sea que cada
       actualizacion del plugin dejaba las dos entradas apuntando a un directorio que ya no
       existia y las guardas morian, fallando abiertas, en silencio. En el manifiesto la
       variable si se expande y apunta a la version en curso, sea cual sea. #>
    param([AllowEmptyString()][string]$ManifestPath)

    $res = @{
        bash  = @{ efectiva = $false; ruta = ""; motivo = "el plugin no declara la guarda" }
        write = @{ efectiva = $false; ruta = ""; motivo = "el plugin no declara la guarda" }
    }
    if (-not $ManifestPath -or -not (Test-Path -LiteralPath $ManifestPath)) { return $res }

    # ${CLAUDE_PLUGIN_ROOT} = la carpeta que contiene .claude-plugin/
    $raizPlugin = ""
    try { $raizPlugin = [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($ManifestPath))) } catch { }

    try {
        $cfg = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entrada in @($cfg.hooks.PreToolUse)) {
            if (-not $entrada) { continue }
            $matcher = "$($entrada.matcher)"
            $dispara = @{
                bash  = ($matcher -eq "" -or $matcher -eq "*" -or $matcher -match "Bash")
                write = ($matcher -eq "" -or $matcher -eq "*" -or $matcher -match "Write|Edit")
            }
            foreach ($h in @($entrada.hooks)) {
                $cmd = "$($h.command)"
                if (-not $cmd) { continue }
                foreach ($clave in @("bash", "write")) {
                    if ($res[$clave].efectiva -or -not $dispara[$clave]) { continue }
                    $script = "pii-guard-$clave.ps1"
                    if ($cmd -notmatch [regex]::Escape("pii-guard-$clave")) { continue }
                    $ruta = (Get-RsPiiGuardRuta -Comando $cmd -Script $script).Replace('${CLAUDE_PLUGIN_ROOT}', $raizPlugin)
                    $v = Test-RsPiiGuardRuta $ruta
                    $res[$clave].ruta = $v.ruta
                    if ($v.efectiva) { $res[$clave].efectiva = $true; $res[$clave].motivo = "" }
                    else { $res[$clave].motivo = "el plugin la declara pero $($v.motivo)" }
                }
            }
        }
    } catch { }
    return $res
}

function Test-RsPiiGuards {
    <# Comprueba que las dos guardas PII estan disponibles y que el .ps1 al que apuntan
       existe. Fuente preferente: el manifiesto del plugin (-ManifestPath). El settings.json
       personal se sigue mirando para detectar RESTOS de la epoca en que se registraban a
       mano: siguen disparando, y ademas suelen estar rotos (ver Get-RsPiiGuardsManifiesto).

       Devuelve @{ bash; write; ok; missing; stale; foreign; legacy; source }.
       bash/write son "efectiva", no "mencionada": una entrada bien formada que apunte a
       un fichero inexistente cuenta como NO registrada, y sale ademas en `stale`.
       source dice de donde sale cada una: "plugin", "settings" o "".
       legacy lista las entradas manuales de settings.json que ya sobran.

       Antes era un -match sobre el TEXTO del fichero: "pii-guard-bash" mencionado en un
       comentario, en una clave desactivada, o registrado bajo PostToolUse con un matcher
       que no dispara, contaba como guarda activa. /rs-pii enforce apoya el cambio de modo
       en este resultado, asi que un falso positivo aqui deja el workspace declarandose
       protegido con los dos bypass abiertos.

       La comprobacion de existencia cierra la version silenciosa de ese mismo fallo. La
       ruta va CABLEADA EN ABSOLUTO en settings.json (ahi ${CLAUDE_PLUGIN_ROOT} no se
       expande), asi que basta con que el plugin cambie de sitio -- reinstalacion, otra
       ruta de cache, otro perfil, un checkout movido -- para que la entrada apunte a un
       .ps1 que ya no esta. El hook falla, pero no con codigo 2, que es el unico que
       bloquea: los dos bypass quedan abiertos mientras check_env sigue diciendo
       "registradas". Es el mismo desenlace que la comprobacion por -match, alcanzable sin
       que nadie haga nada mal.

       -HooksDir (opcional) es el directorio hooks\ del plugin en uso. Si se pasa, una
       guarda que exista pero cuelgue de OTRA copia del plugin se anota en `foreign`: sigue
       protegiendo -- por eso no invalida `ok` -- pero es una copia vendorizada que no se
       actualiza con el plugin (el escenario de la v2.11.0, ver CHANGELOG).

       ⚠️ Comprueba el FICHERO, no la sesion. Claude Code captura la configuracion de hooks
       al arrancar: unas entradas escritas a mitad de sesion no estan vivas hasta reiniciar.
       Esto no se puede verificar desde aqui -- por eso /rs-pii enforce debe pedir el
       reinicio y no declarar la proteccion activa en la misma sesion que las registro. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SettingsPath,
        [AllowEmptyString()][string]$HooksDir = "",
        [AllowEmptyString()][string]$ManifestPath = ""
    )

    $guardas = [ordered]@{
        bash  = @{ script = "pii-guard-bash.ps1";  desc = "pii-guard-bash (PreToolUse, matcher Bash)";        efectiva = $false; rota = ""; source = "" }
        write = @{ script = "pii-guard-write.ps1"; desc = "pii-guard-write (PreToolUse, matcher Write|Edit)"; efectiva = $false; rota = ""; source = "" }
    }
    $foreign = @()
    $legacy  = @()

    $hooksDirNorm = ""
    if ($HooksDir) {
        try { $hooksDirNorm = [System.IO.Path]::GetFullPath($HooksDir).TrimEnd('\', '/') } catch { }
    }

    # 1) El manifiesto del plugin, que es la fuente desde 3.4.0.
    if ($ManifestPath) {
        $delPlugin = Get-RsPiiGuardsManifiesto $ManifestPath
        foreach ($clave in @("bash", "write")) {
            if ($delPlugin[$clave].efectiva) {
                $guardas[$clave].efectiva = $true
                $guardas[$clave].source   = "plugin"
            } elseif ($delPlugin[$clave].ruta) {
                # Declarada y rota: el repo del plugin esta incompleto. Mismo trato que una
                # entrada rota de settings.json -- no protege y hay que decirlo.
                $guardas[$clave].rota = "$($guardas[$clave].script) declarada en plugin.json pero no protege — $($delPlugin[$clave].motivo)"
            }
        }
    }

    # 2) Restos manuales en el settings.json personal. Siguen disparando, asi que si el
    #    plugin no la declarara todavia protegerian; pero ya sobran y se listan en `legacy`.
    if ($SettingsPath -and (Test-Path $SettingsPath)) {
        try {
            # Sin -AsHashtable: no existe en PowerShell 5.1, donde corren los hooks.
            $cfg = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entrada in @($cfg.hooks.PreToolUse)) {
                if (-not $entrada) { continue }
                $matcher = "$($entrada.matcher)"
                # Matcher plausible: el que realmente dispararia para esa herramienta. Un
                # matcher vacio o "*" aplica a todas, asi que tambien vale.
                $dispara = @{
                    bash  = ($matcher -eq "" -or $matcher -eq "*" -or $matcher -match "Bash")
                    write = ($matcher -eq "" -or $matcher -eq "*" -or $matcher -match "Write|Edit")
                }
                foreach ($h in @($entrada.hooks)) {
                    $cmd = "$($h.command)"
                    if (-not $cmd) { continue }
                    foreach ($clave in @("bash", "write")) {
                        $g = $guardas[$clave]
                        if (-not $dispara[$clave]) { continue }
                        if ($cmd -notmatch [regex]::Escape($g.script.Replace(".ps1", ""))) { continue }

                        $veredicto = Test-RsPiiGuardRuta (Get-RsPiiGuardRuta -Comando $cmd -Script $g.script)
                        # Toda entrada manual sobra ya: el plugin declara las dos guardas. Se
                        # listan vivas y rotas por igual -- las rotas fallan en cada llamada,
                        # y las vivas duplican el hook, que es el fallo de la v2.11.0.
                        $estadoLegacy = if ($veredicto.efectiva) { "viva" } else { $veredicto.motivo }
                        $legacy += "$($g.script) registrada a mano en settings.json ($estadoLegacy): $($veredicto.ruta)"

                        if ($g.efectiva) { continue }
                        if ($veredicto.efectiva) {
                            $g.efectiva = $true
                            $g.source   = "settings"
                            $g.rota     = ""
                            if ($hooksDirNorm) {
                                $dir = ""
                                # GetDirectoryName y no Split-Path: Split-Path trata la ruta como
                                # patron de comodines y una carpeta con [ ] en el nombre lo tumba.
                                try { $dir = [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($veredicto.ruta)).TrimEnd('\', '/') } catch { }
                                if ($dir -and $dir -ne $hooksDirNorm) {
                                    $foreign += "$($g.script) registrada desde otra copia del plugin: $($veredicto.ruta)"
                                }
                            }
                        } elseif (-not $g.rota) {
                            # Se guarda el primer motivo, pero se sigue recorriendo: puede
                            # haber una segunda entrada de la misma guarda que si sea buena.
                            $g.rota = "$($g.script) registrada pero no protege — $($veredicto.motivo): $($veredicto.ruta)"
                        }
                    }
                }
            }
        } catch { }
    }

    $missing = @()
    $stale   = @()
    foreach ($clave in @("bash", "write")) {
        $g = $guardas[$clave]
        if ($g.efectiva) { continue }
        if ($g.rota) { $stale += $g.rota; $missing += $g.rota }
        else         { $missing += $g.desc }
    }

    return @{
        bash    = $guardas.bash.efectiva
        write   = $guardas.write.efectiva
        ok      = ($missing.Count -eq 0)
        missing = @($missing)
        stale   = @($stale)
        foreign = @($foreign)
        legacy  = @($legacy)
        source  = @{ bash = $guardas.bash.source; write = $guardas.write.source }
    }
}
