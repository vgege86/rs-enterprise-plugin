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
