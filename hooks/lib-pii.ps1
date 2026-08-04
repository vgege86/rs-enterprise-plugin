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

function Test-RsPiiGuards {
    <# Comprueba ESTRUCTURALMENTE que las dos guardas PII estan registradas como entradas
       de hooks.PreToolUse en el settings.json indicado.

       Devuelve @{ bash; write; ok; missing } (missing = lista de descripciones).

       Antes era un -match sobre el TEXTO del fichero: "pii-guard-bash" mencionado en un
       comentario, en una clave desactivada, o registrado bajo PostToolUse con un matcher
       que no dispara, contaba como guarda activa. /rs-pii enforce apoya el cambio de modo
       en este resultado, asi que un falso positivo aqui deja el workspace declarandose
       protegido con los dos bypass abiertos.

       ⚠️ Comprueba el FICHERO, no la sesion. Claude Code captura la configuracion de hooks
       al arrancar: unas entradas escritas a mitad de sesion no estan vivas hasta reiniciar.
       Esto no se puede verificar desde aqui -- por eso /rs-pii enforce debe pedir el
       reinicio y no declarar la proteccion activa en la misma sesion que las registro. #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$SettingsPath)

    $bash  = $false
    $write = $false
    if ($SettingsPath -and (Test-Path $SettingsPath)) {
        try {
            # Sin -AsHashtable: no existe en PowerShell 5.1, donde corren los hooks.
            $cfg = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entrada in @($cfg.hooks.PreToolUse)) {
                if (-not $entrada) { continue }
                $matcher = "$($entrada.matcher)"
                # Matcher plausible: el que realmente dispararia para esa herramienta. Un
                # matcher vacio o "*" aplica a todas, asi que tambien vale.
                $matchBash  = ($matcher -eq "" -or $matcher -eq "*" -or $matcher -match "Bash")
                $matchWrite = ($matcher -eq "" -or $matcher -eq "*" -or $matcher -match "Write|Edit")
                foreach ($h in @($entrada.hooks)) {
                    $cmd = "$($h.command)"
                    if (-not $cmd) { continue }
                    if ($matchBash  -and $cmd -match "pii-guard-bash")  { $bash  = $true }
                    if ($matchWrite -and $cmd -match "pii-guard-write") { $write = $true }
                }
            }
        } catch { }
    }

    $missing = @()
    if (-not $bash)  { $missing += "pii-guard-bash (PreToolUse, matcher Bash)" }
    if (-not $write) { $missing += "pii-guard-write (PreToolUse, matcher Write|Edit)" }

    return @{ bash = $bash; write = $write; ok = ($missing.Count -eq 0); missing = @($missing) }
}
