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

function Test-RsPiiGuards {
    <# Comprueba que las dos guardas PII estan registradas como entradas de
       hooks.PreToolUse en el settings.json indicado Y que el .ps1 al que apuntan existe.

       Devuelve @{ bash; write; ok; missing; stale; foreign } — listas de descripciones.
       bash/write son "efectiva", no "mencionada": una entrada bien formada que apunte a
       un fichero inexistente cuenta como NO registrada, y sale ademas en `stale`.

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
        [AllowEmptyString()][string]$HooksDir = ""
    )

    $guardas = [ordered]@{
        bash  = @{ script = "pii-guard-bash.ps1";  desc = "pii-guard-bash (PreToolUse, matcher Bash)";        efectiva = $false; rota = "" }
        write = @{ script = "pii-guard-write.ps1"; desc = "pii-guard-write (PreToolUse, matcher Write|Edit)"; efectiva = $false; rota = "" }
    }
    $foreign = @()

    $hooksDirNorm = ""
    if ($HooksDir) {
        try { $hooksDirNorm = [System.IO.Path]::GetFullPath($HooksDir).TrimEnd('\', '/') } catch { }
    }

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
                        if ($g.efectiva) { continue }
                        if (-not $dispara[$clave]) { continue }
                        if ($cmd -notmatch [regex]::Escape($g.script.Replace(".ps1", ""))) { continue }

                        $veredicto = Test-RsPiiGuardRuta (Get-RsPiiGuardRuta -Comando $cmd -Script $g.script)
                        if ($veredicto.efectiva) {
                            $g.efectiva = $true
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
    }
}
