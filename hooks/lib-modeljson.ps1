<#
.SYNOPSIS
    Escritura del BD\<proyecto>-model.json desde PowerShell. Dot-sourcear desde todo hook que
    guarde el modelo.

    ⛔ NO serializa. Delega en scripts\_modeljson.py, que es el UNICO escritor canonico del
    plugin. Este fichero solo transporta la estructura hasta el.

.NOTES
    POR QUE NO SE ESCRIBE DIRECTAMENTE CON ConvertTo-Json

    El ConvertTo-Json de PowerShell 5.1 no indenta con dos espacios por nivel: ALINEA cada valor
    a la columna de la clave padre. Un modelo de 1,1 MB se va a 3,5 MB (x3,2) y cambia el
    sangrado de TODAS las lineas, asi que el diff del control de versiones queda inservible
    linea a linea aunque el BOM y los CRLF sean correctos. El JSON es valido y el contenido es
    el mismo: solo se ve al abrir el diff, que es cuando ya esta subido.

    Tampoco vale reimplementar el formato canonico en PowerShell. Serian DOS escritores otra
    vez —uno aqui y otro en Python— y volverian a divergir, que es exactamente el fallo que
    esto viene a cerrar (el mismo camino que ya recorrio el mapeo de tipos antes de
    scripts\_dbtypes.py).

    Lo que si hace este fichero es serializar con -Compress a un temporal. Ese texto NO se
    conserva: solo viaja hasta Python, que lo reserializa en forma canonica. Al ir comprimido,
    el bug de indentacion de PS 5.1 ni siquiera llega a manifestarse.

    -Depth 20 sobra para el modelo (la anidacion real es de 5 niveles: tables > tabla > columns
    > columna > campo), pero un -Depth corto TRUNCA en silencio a cadenas "System.Object[]" en
    vez de fallar. Con un margen amplio, ese modo de fallo no existe.
#>

function Save-RsModelJson {
    <#  Guarda el modelo en forma canonica: indent=2, ensure_ascii, CRLF y UTF-8 CON BOM.
        Escritura atomica y verificada por scripts\_modeljson.py — si la verificacion falla,
        el modelo anterior NO se toca y esta funcion lanza.

        Devuelve la hashtable del veredicto (ok, path, bytes, bom, lf_sueltos, no_ascii,
        reparse, coincide).

        ⛔ Lanza si Python no esta disponible. Es deliberado: el plugin ya exige Python para el
        servidor MCP, y caer a un ConvertTo-Json de emergencia significaria reintroducir el
        formato roto justo cuando nadie esta mirando.  #>
    param(
        [Parameter(Mandatory=$true)]$Model,
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$Depth = 20
    )

    $py = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts\_modeljson.py"
    if (-not (Test-Path $py)) {
        throw "No se encuentra el escritor canonico del modelo: $py"
    }

    $tmpIn = [System.IO.Path]::GetTempFileName() + ".json"
    try {
        # Sin BOM: lo lee Python con utf-8-sig, pero el fichero es de transporte y cuanto menos
        # tenga que adivinar, mejor.
        $texto = $Model | ConvertTo-Json -Depth $Depth -Compress
        [System.IO.File]::WriteAllText($tmpIn, $texto, (New-Object System.Text.UTF8Encoding($false)))

        $salida = & python $py escribir $Path $tmpIn 2>&1
        $code   = $LASTEXITCODE
        $texto  = ($salida | Out-String).Trim()

        $veredicto = $null
        try { $veredicto = $texto | ConvertFrom-Json } catch { }

        if ($code -ne 0 -or -not $veredicto -or -not $veredicto.ok) {
            $motivo = if ($veredicto -and $veredicto.error) { $veredicto.error } else { $texto }
            throw "No se pudo escribir el modelo en forma canonica ($Path): $motivo"
        }
        return $veredicto
    }
    finally {
        Remove-Item $tmpIn -Force -ErrorAction SilentlyContinue
    }
}

function Test-RsModelJson {
    <#  Verifica un model.json ya escrito sin tocarlo: BOM, LF sueltos, bytes no-ASCII y
        reparseo. Para diagnostico (check-env, revision manual); la escritura ya se verifica
        sola. Devuelve el veredicto o $null si no se pudo ejecutar.  #>
    param([Parameter(Mandatory=$true)][string]$Path)

    $py = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts\_modeljson.py"
    if (-not (Test-Path $py) -or -not (Test-Path $Path)) { return $null }
    try {
        $salida = & python $py verificar $Path 2>&1
        return (($salida | Out-String).Trim() | ConvertFrom-Json)
    } catch {
        return $null
    }
}
