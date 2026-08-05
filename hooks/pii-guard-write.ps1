<#
.SYNOPSIS
    Guarda PreToolUse sobre Write/Edit: impide persistir datos personales en ficheros.

.DESCRIPTION
    Detecta por FORMA (DNI/NIE con letra de control valida, IBAN, correo) en el
    contenido que se va a escribir. No detecta nombres ni direcciones -- no tienen
    patron reconocible (ver docs/proteccion-pii-consultas-bd.md #5.2f).

    DNI y NIE no se bloquean por forma sola: se valida la letra de control. Sin la
    validacion, este repositorio esta lleno de cadenas AAAAMMDD (convencion
    Actualizador\<ENTORNO>_<AAAAMMDD>) que casan la forma "8 digitos + letra" por pura
    casualidad, la guarda se dispara a diario y se acaba desactivando -- entonces no
    protege nada. Los patrones y el checksum viven en hooks/lib-pii.ps1 (compartido con
    el saneado de hooks/log-execution.ps1, mismo motivo alli). Telefono y tarjeta se
    han excluido a proposito de esta guarda (no de scripts/pii_detect.py, que sigue
    intacto): son puramente numericos y casarian con cualquier importe en centimos o
    identificador de fila largo.

    Excluye las rutas de entrega al cliente (Instalador, Actualizador): ahi el volcado
    de datos reales es el proposito del fichero, no una fuga.

    Registro en ~/.claude/settings.json bajo hooks.PreToolUse con matcher "Write|Edit".
    Salida 2 = bloquear, 0 = permitir.
#>
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot "lib-pii.ps1")

try {
    # Misma dualidad que pii-guard-bash.ps1: stdin real cuando Claude Code lanza el hook
    # como proceso, $input cuando un test Pester lo invoca via pipe dentro del mismo
    # proceso ("'json' | & script.ps1" no llega a la stdin del proceso). Read-RsStdinUtf8
    # descodifica esa stdin como UTF-8 explicitamente y Repair-RsTextoUtf8 deshace la
    # descodificacion en pagina OEM que hace PowerShell cuando la stdin llega por $input
    # (ver lib-pii.ps1): sin eso, una ruta con acentos salia destrozada en el bloqueo.
    $textoEvento = Repair-RsTextoUtf8 ([string]::Join("`n", @($input)))
    if (-not $textoEvento) { $textoEvento = Read-RsStdinUtf8 }
    $evento    = $textoEvento | ConvertFrom-Json
    $ruta      = "$($evento.tool_input.file_path)"
    $contenido = "$($evento.tool_input.content)$($evento.tool_input.new_string)"
    $cwd       = "$($evento.cwd)"
} catch {
    exit 0
}

# La guarda sigue al modo del WORKSPACE (ver Get-RsPiiEstadoGuarda). Manda el workspace del
# FICHERO que se va a escribir, no el de la sesion: escribiendo en el workspace B desde una
# sesion abierta en A, quien decide es B -- es su BD la que tiene o no datos reales. El cwd
# queda de respaldo para las herramientas que no traen ruta.
$estado = Get-RsPiiEstadoGuarda $(if ($ruta) { $ruta } else { $cwd })
if (-not $estado.activa) { exit 0 }

# Entrega al cliente: el volcado de datos reales es intencionado.
if ($ruta -match '\\(Instalador|Actualizador)\\') { exit 0 }

# Test-DniNieChecksum viene de lib-pii.ps1 (dot-sourced arriba).

function Block-Pii {
    param([string]$Forma, [string]$Ruta)

    Write-Error @"
BLOQUEADO: el contenido a escribir contiene un dato con forma de $Forma.

Fichero: $Ruta

No persistas datos personales en ficheros del repositorio ni en documentacion. Si el
valor es un ejemplo, usa uno claramente ficticio. Si es un volcado real que debe
entregarse al cliente, escribelo bajo Instalador\ o Actualizador\.
"@
    exit 2
}

# DNI / NIE: la forma sola no basta (ver cabecera), se exige letra de control valida.
foreach ($m in [regex]::Matches($contenido, $script:RsPiiPatronDni)) {
    if (Test-DniNieChecksum $m.Value) { Block-Pii "DNI" $ruta }
}
foreach ($m in [regex]::Matches($contenido, $script:RsPiiPatronNie)) {
    if (Test-DniNieChecksum $m.Value) { Block-Pii "NIE" $ruta }
}

# IBAN / correo: la forma ya es lo bastante distintiva, sin checksum.
if ($contenido -cmatch $script:RsPiiPatronIban) { Block-Pii "IBAN" $ruta }
if ($contenido -cmatch $script:RsPiiPatronCorreo) { Block-Pii "correo electronico" $ruta }

exit 0
