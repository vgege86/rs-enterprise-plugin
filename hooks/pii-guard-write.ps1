<#
.SYNOPSIS
    Guarda PreToolUse sobre Write/Edit: impide persistir datos personales en ficheros.

.DESCRIPTION
    Detecta por FORMA (DNI/NIE con letra de control valida, IBAN, correo) en el
    contenido que se va a escribir. No detecta nombres ni direcciones -- no tienen
    patron reconocible (ver docs/proteccion-pii-consultas-bd.md #5.2f).

    DNI y NIE no se bloquean por forma sola: se valida la letra de control
    ("TRWAGMYFPDXBNJZSQVHLCKE"[numero % 23]) porque este repositorio esta lleno de
    cadenas AAAAMMDD (convencion Actualizador\<ENTORNO>_<AAAAMMDD>) que casan la forma
    "8 digitos + letra" por pura casualidad. Sin la validacion, la guarda se dispara
    a diario y se acaba desactivando -- entonces no protege nada. Telefono y tarjeta
    se han excluido a proposito de esta guarda (no de scripts/pii_detect.py, que sigue
    intacto): son puramente numericos y casarian con cualquier importe en centimos o
    identificador de fila largo.

    Excluye las rutas de entrega al cliente (Instalador, Actualizador): ahi el volcado
    de datos reales es el proposito del fichero, no una fuga.

    Registro en ~/.claude/settings.json bajo hooks.PreToolUse con matcher "Write|Edit".
    Salida 2 = bloquear, 0 = permitir.
#>
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

try {
    # Misma dualidad que pii-guard-bash.ps1: stdin real ([Console]::In) cuando Claude Code
    # lanza el hook como proceso, $input cuando un test Pester lo invoca via pipe dentro
    # del mismo proceso ("'json' | & script.ps1" no llega a [Console]::In).
    $textoEvento = [string]::Join("`n", @($input))
    if (-not $textoEvento) { $textoEvento = [Console]::In.ReadToEnd() }
    $evento    = $textoEvento | ConvertFrom-Json
    $ruta      = "$($evento.tool_input.file_path)"
    $contenido = "$($evento.tool_input.content)$($evento.tool_input.new_string)"
} catch {
    exit 0
}

# Entrega al cliente: el volcado de datos reales es intencionado.
if ($ruta -match '\\(Instalador|Actualizador)\\') { exit 0 }

# Valida la letra de control de un DNI (8 digitos + letra) o un NIE (X/Y/Z + 7 digitos
# + letra). $Valor debe venir ya recortado a la forma exacta (sin \b alrededor).
function Test-DniNieChecksum {
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
foreach ($m in [regex]::Matches($contenido, '\b\d{8}[A-HJ-NP-TV-Z]\b')) {
    if (Test-DniNieChecksum $m.Value) { Block-Pii "DNI" $ruta }
}
foreach ($m in [regex]::Matches($contenido, '\b[XYZ]\d{7}[A-HJ-NP-TV-Z]\b')) {
    if (Test-DniNieChecksum $m.Value) { Block-Pii "NIE" $ruta }
}

# IBAN / correo: la forma ya es lo bastante distintiva, sin checksum.
if ($contenido -cmatch '\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b') { Block-Pii "IBAN" $ruta }
if ($contenido -cmatch '\b[^@\s]+@[^@\s]+\.[A-Za-z]{2,}\b') { Block-Pii "correo electronico" $ruta }

exit 0
