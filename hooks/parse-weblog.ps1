<#
.SYNOPSIS
    Parsea logs de error de la capa web (NLog/log4net, ELMAH XML, el formato propio de la
    AgendaWeb uCollect/RS y volcados de stack .NET), agrupa las ocurrencias por FIRMA y
    devuelve solo el agregado.

.DESCRIPTION
    Un log de errores repite el mismo fallo cientos de veces. Lo que interesa para abrir tareas
    no son las lineas, son los TIPOS de error distintos. Este hook colapsa las N ocurrencias de
    un mismo fallo en una firma con su recuento y una muestra, y NUNCA emite el log completo:
    la salida es un JSON acotado (top -MaxSignatures firmas), pensado para caber en contexto.

    Firma = SHA1( tipo de excepcion + frame mas profundo de codigo propio + mensaje normalizado ).
    El mensaje se normaliza antes de hashear (numeros, GUIDs, fechas, rutas y hex -> marcadores),
    porque "Cliente 4711 no existe" y "Cliente 8322 no existe" son el mismo error.

    ⛔ PII: los logs de una web llevan datos reales de usuario y estos textos acaban copiados en
    un ticket. Mensajes y muestras pasan por Remove-RsPii (lib-pii.ps1) y ademas por la redaccion
    de literales entre comillas simples ('...' -> '<val>'): en el formato rs-cerrores el mensaje
    trae el SQL entero, y los datos personales viajan DENTRO de esos literales, donde ninguna
    deteccion por forma llega (un nombre o un numero de lote no tienen forma reconocible).
    La redaccion se aplica solo a la SALIDA, nunca a la clave de firma: el hash es el marcador
    [log:<hash>] con el que /rs-log-errores deduplica contra los tickets ya abiertos, y cambiarlo
    haria que se recrearan todos.

    FORMATO rs-cerrores (AgendaWeb uCollect/RS). Cada evento abre con una cabecera propia:

        Error: (11/08/2026 13:45) - Codigo error: -2147467259 Codigo error sql: 0 Descripción error: ORA-12899: ...

    y las lineas siguientes son el stack ("   en Clase.Metodo(...)"). No lo reconocia ningun
    parser hasta la 3.20.0 y el desenlace era un falso negativo SILENCIOSO — la tool respondia
    success:true con total_events:1 sobre un log de 1.696 eventos, y ese "1 error" se tria como
    incidencia aislada de infraestructura. Dos motivos encadenados:
      1. La fecha va entre PARENTESIS y sin segundos, asi que no casaba $rxStamp (que exigia
         "[" y "HH:mm:ss") y la rama nlog/log4net nunca entraba: ningun evento tenia stamp.
      2. Al caer al volcado plano, el gate era $rxExcepcion, que pide >=1 caracter antes de
         "Error" ([A-Za-z_][\w.]*(?:Exception|Error)) y NO casa el literal "Error:" a secas.
    ⚠️ La hora viene con una o dos cifras ("(20/02/2026 8:41)"): exigir HH de dos cifras deja
    fuera el 20% de los eventos y ademas los pega como continuacion del evento anterior.
    La etiqueta de cabecera no es siempre "Error" (tambien "cErrores", "Fail"...) y de ella se
    deriva el nivel, para que -Niveles siga filtrando.

    En este formato la excepcion util NO es un token *Exception/*Error: es el CODIGO. Se toma,
    por este orden, el ORA-xxxxx del texto, el "Codigo error: <n>" de la cabecera y, solo si no
    hay ninguno, la excepcion .NET. Sin esto todas las firmas colapsan en "SinExcepcion" y el
    dedup queda inservible.

.PARAMETER Path
    Fichero de log o carpeta que los contiene.

.PARAMETER Glob
    Patron de fichero cuando -Path es carpeta. Por defecto "*.log".

.PARAMETER Desde
    Fecha/hora ISO minima (yyyy-MM-dd [HH:mm:ss]). Descarta eventos anteriores.

.PARAMETER Niveles
    Niveles a considerar, coma-separados. Por defecto "ERROR,FATAL".

.PARAMETER MaxSignatures
    Maximo de firmas distintas devueltas (las mas frecuentes). Por defecto 30.

.PARAMETER Samples
    Muestras por firma. Por defecto 2.

.PARAMETER MaxLines
    Tope de lineas leidas en total (proteccion ante logs enormes). Por defecto 500000.

.EXAMPLE
    .\parse-weblog.ps1 -Path "C:\AIS\<Proyecto>\AgendaWeb\logs" -Desde 2026-08-01
#>
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Glob = "*.log",
    [string]$Desde,
    [string]$Niveles = "ERROR,FATAL",
    [int]$MaxSignatures = 30,
    [int]$Samples = 2,
    [int]$MaxLines = 500000
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot "lib-pii.ps1")

function Emit($obj) { $obj | ConvertTo-Json -Depth 8 -Compress }
function Fail($msg) { Emit @{ success = $false; error = "$msg" }; exit 0 }

if (-not (Test-Path -LiteralPath $Path)) { Fail "Ruta no encontrada: $Path" }

# --- Ficheros a escanear -----------------------------------------------------------------
$item = Get-Item -LiteralPath $Path
if ($item.PSIsContainer) {
    $files = @(Get-ChildItem -LiteralPath $Path -Filter $Glob -File -Recurse -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { Fail "Sin ficheros que casen con '$Glob' en $Path" }
} else {
    $files = @($item)
}

$desdeDt = $null
if ($Desde) {
    [datetime]$parsed = [datetime]::MinValue
    if ([datetime]::TryParse($Desde, [ref]$parsed)) { $desdeDt = $parsed }
    else { Fail "-Desde no es una fecha valida: $Desde" }
}

$nivelSet = @($Niveles -split ',' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })

# --- Patrones ----------------------------------------------------------------------------
# Delimitador "[" o "(" y segundos OPCIONALES: hay logs que escriben "(11/08/2026 13:45)".
$rxStamp     = [regex]::new('^\s*[\[(]?(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(?::\d{2})?(?:[.,]\d+)?|\d{2}/\d{2}/\d{4}[ T]\d{2}:\d{2}(?::\d{2})?)')
$rxNivel     = [regex]::new('\b(FATAL|ERROR|WARN(?:ING)?|INFO|DEBUG|TRACE)\b')
$rxExcepcion = [regex]::new('([A-Za-z_][\w.]*(?:Exception|Error))\b')
# Frame: NO anclado a inicio de linea. En el formato rs-cerrores el primer frame propio viene
# pegado al final del texto del mensaje ("... ) )     en Comun.cConexion.EjecutarQuery(...)"),
# asi que anclarlo con ^ pierde justo el frame que identifica el fallo.
$rxFrame     = [regex]::new('(?:^|[\s\)])(?:at|en)\s+([\w.<>`+]+\.[\w<>`+]+)\s*\(')
# Marcos de plataforma: no identifican el fallo, el frame util es el primero que NO casa.
$rxPlataforma = [regex]::new('^(System\.|Microsoft\.|mscorlib|Newtonsoft\.|lambda_method|NLog\.|log4net\.)')
# Pagina .aspx.cs / control .ascx.cs mas cercano a la cima del stack -> campo "pantalla". Es lo
# que permite triar sin abrir el codigo: dos ORA-00001 identicos en dos pantallas distintas son
# dos tareas distintas.
$rxPantalla  = [regex]::new('([\w]+)\.(aspx|ascx)\.cs')

# --- Formato rs-cerrores (AgendaWeb uCollect/RS) ------------------------------------------
# "<Etiqueta>: (d/M/yyyy H:mm[:ss]) - Codigo error: <n> Codigo error sql: <n> Descripción error: <texto>"
$rxRsCab     = [regex]::new('^\s*([A-Za-z_][\w]*)\s*:\s*\(\s*(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*\)\s*-')
# "Descripci.{0,3}n" y no "Descripción": si el log llega con la codificacion mal resuelta, la
# "ó" es un U+FFFD y un patron literal deja de casar sin que nada lo delate (el mensaje seguiria
# saliendo, pero con la cabecera entera pegada delante). Get-RsCodificacion evita el caso normal;
# esto cubre el resto.
$rxRsDesc    = [regex]::new('Descripci.{0,3}n\s+error:\s*(.*)$')
$rxRsCodigo  = [regex]::new('Codigo\s+error:\s*(-?\d+)')
$rxOra       = [regex]::new('\bORA-\d{5}\b')
# Literal SQL: lo que va entre comillas simples es el DATO, y ahi es donde viaja la PII que
# ninguna deteccion por forma reconoce. {0,400} y no * para no morir en un backtrack sobre una
# linea de 30 KB con las comillas desparejadas.
$rxLiteral   = [regex]::new("'[^']{0,400}'")

function Get-RsNivelEtiqueta([string]$etiqueta) {
    <# Nivel derivado de la etiqueta de cabecera del formato rs-cerrores. La etiqueta no es
       siempre "Error": el mismo log escribe "cErrores" (el nombre de la clase que registra) y
       "Fail". Se mapea para que -Niveles siga siendo un filtro util; "" = el log no dice nivel
       y lo resuelve quien llama. #>
    if (-not $etiqueta) { return "" }
    if ($etiqueta -match '(?i)fatal')        { return "FATAL" }
    if ($etiqueta -match '(?i)error|fail')   { return "ERROR" }
    if ($etiqueta -match '(?i)warn')         { return "WARNING" }
    if ($etiqueta -match '(?i)info')         { return "INFO" }
    if ($etiqueta -match '(?i)debug')        { return "DEBUG" }
    if ($etiqueta -match '(?i)trace')        { return "TRACE" }
    return ""
}

function Normalizar([string]$t) {
    if (-not $t) { return "" }
    $t = [regex]::Replace($t, '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}', '<guid>')
    $t = [regex]::Replace($t, '\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}:\d{2})?', '<fecha>')
    $t = [regex]::Replace($t, '\d{2}/\d{2}/\d{4}', '<fecha>')
    $t = [regex]::Replace($t, '[A-Za-z]:\\[^\s"'']+', '<ruta>')
    $t = [regex]::Replace($t, '0x[0-9a-fA-F]+', '<hex>')
    $t = [regex]::Replace($t, '\d+', '#')
    return $t.Trim()
}

function Get-RsCodificacion([string]$ruta) {
    <# Codificacion con la que leer el log. [IO.File]::ReadLines sin argumento asume UTF-8, y
       los logs de una web .NET en Windows salen en la codepage ANSI de la maquina: cada acento
       es un byte invalido en UTF-8 que se convierte en U+FFFD. Eso no solo afea el texto que
       acaba en el ticket — rompe los patrones que lo leen ("Descripción error:" deja de casar)
       y el fallo es silencioso, que es justo lo que este hook ya pago una vez.

       Con BOM manda el BOM. Sin BOM se prueba a descodificar los primeros 64 KB como UTF-8
       ESTRICTO: si no lanza, el fichero es UTF-8; si lanza, es ANSI. Un log ASCII puro cae en
       UTF-8, que para ASCII es el mismo resultado. #>
    $enc = $null
    try {
        $bytes = New-Object byte[] 65536
        $fs = [IO.File]::OpenRead($ruta)
        try { $n = $fs.Read($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
        if ($n -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            return New-Object Text.UTF8Encoding($true)
        }
        # El bloque puede cortar un caracter multibyte por la mitad: se retrocede hasta salir
        # de los bytes de continuacion (10xxxxxx) para no declarar ANSI por el corte.
        while ($n -gt 0 -and ($bytes[$n - 1] -band 0xC0) -eq 0x80) { $n-- }
        if ($n -gt 0) { $n-- }
        $estricto = New-Object Text.UTF8Encoding($false, $true)
        [void]$estricto.GetString($bytes, 0, [Math]::Max($n, 0))
        return New-Object Text.UTF8Encoding($false)
    } catch {
        try {
            $cp = [int][Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
            # En PowerShell 7 (.NET Core) las codepages heredadas no estan registradas de serie.
            if (Test-Path Variable:\PSVersionTable) {
                try { [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance) } catch { }
            }
            $enc = [Text.Encoding]::GetEncoding($cp)
        } catch { $enc = [Text.Encoding]::Default }
        return $enc
    }
}

function Hash8([string]$t) {
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($t))
        return (($bytes | ForEach-Object { $_.ToString("x2") }) -join '').Substring(0, 8)
    } finally { $sha.Dispose() }
}

function Recortar([string]$t, [int]$max) {
    if (-not $t) { return "" }
    $t = ($t -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' ').Trim()
    if ($t.Length -gt $max) { return $t.Substring(0, $max) + "..." }
    return $t
}

function Proteger([string]$t) {
    <# Unica puerta de salida de texto del log. Primero los literales entre comillas simples
       (el dato de un INSERT/WHERE, donde va la PII que no tiene forma reconocible) y despues
       Remove-RsPii, que cubre correo, IBAN y DNI/NIE por forma alla donde no haya comillas.
       ⛔ No se usa para construir la clave de firma — ver la cabecera del fichero. #>
    if (-not $t) { return $t }
    $t = $rxLiteral.Replace($t, "'<val>'")
    return Remove-RsPii $t
}

# --- Acumulador de firmas ----------------------------------------------------------------
$firmas       = @{}
$totalEventos = 0
$lineas       = 0
$topeLineas   = $false
$formatos     = @{}

function Registrar($evento, $fichero) {
    $texto   = ($evento.Lineas -join "`n")
    $primera = $evento.Lineas[0]

    # Frame propio: el primero que no sea plataforma (la cima del stack es lo mas profundo).
    # Se busca en TODAS las lineas y sin anclar a inicio (ver $rxFrame).
    $frame = ""
    foreach ($l in $evento.Lineas) {
        foreach ($mF in $rxFrame.Matches($l)) {
            $cand = $mF.Groups[1].Value
            if (-not $rxPlataforma.IsMatch($cand)) { $frame = $cand; break }
            if (-not $frame) { $frame = $cand }   # respaldo si TODO es plataforma
        }
        if ($frame -and -not $rxPlataforma.IsMatch($frame)) { break }
    }

    # Pantalla: la .aspx.cs mas cercana a la cima del stack; un .ascx.cs sirve de respaldo.
    $pantalla = ""
    foreach ($l in $evento.Lineas) {
        $mP = $rxPantalla.Match($l)
        if (-not $mP.Success) { continue }
        if ($mP.Groups[2].Value -ieq "aspx") { $pantalla = $mP.Groups[1].Value; break }
        if (-not $pantalla) { $pantalla = $mP.Groups[1].Value }
    }

    if ($evento.Formato -eq "rs-cerrores") {
        # Codigo antes que excepcion: es lo que identifica el fallo en este formato.
        $mOra = $rxOra.Match($texto)
        $mCod = $rxRsCodigo.Match($primera)
        if ($mOra.Success) {
            $exc = $mOra.Value
        } elseif ($mCod.Success -and $mCod.Groups[1].Value -ne "0") {
            # Un "Codigo error: 0" no discrimina nada, asi que no se usa de etiqueta.
            $exc = "COD" + $mCod.Groups[1].Value
        } else {
            $mEx = $rxExcepcion.Match($texto)
            $exc = if ($mEx.Success) { $mEx.Groups[1].Value }
                   elseif ($mCod.Success) { "COD" + $mCod.Groups[1].Value }
                   else { "SinCodigo" }
        }
        # Mensaje: lo que dice la cabecera despues de "Descripción error:"; si no lo trae, la
        # cabecera entera sin la etiqueta ni la fecha.
        $mDesc = $rxRsDesc.Match($primera)
        $msg = if ($mDesc.Success) { $mDesc.Groups[1].Value } else { $rxRsCab.Replace($primera, '', 1) }
        $msg = $msg.Trim(" ", "-", "|", "`t")
    } else {
        # Excepcion: la primera del evento; si no hay ninguna, el error no es tipado.
        $mEx  = $rxExcepcion.Match($texto)
        $exc  = if ($mEx.Success) { $mEx.Groups[1].Value } else { "SinExcepcion" }

        # Mensaje: la primera linea sin el prefijo de timestamp/nivel.
        $msg = $rxStamp.Replace($primera, '')
        $msg = $rxNivel.Replace($msg, '', 1)
        $msg = $msg.Trim(" ", "-", "|", "[", "]", ":", "`t")
    }

    $clave = "$exc|$frame|$(Normalizar $msg)"
    $hash  = Hash8 $clave

    if (-not $firmas.ContainsKey($hash)) {
        $firmas[$hash] = [PSCustomObject]@{
            hash       = $hash
            exception  = $exc
            origin     = $frame
            pantalla   = $pantalla
            message    = Recortar (Proteger $msg) 300
            count      = 0
            first_seen = $evento.Stamp
            last_seen  = $evento.Stamp
            files      = @()
            samples    = @()
        }
    }

    $f = $firmas[$hash]
    $f.count++
    if ($evento.Stamp) {
        if (-not $f.first_seen -or $evento.Stamp -lt $f.first_seen) { $f.first_seen = $evento.Stamp }
        if (-not $f.last_seen  -or $evento.Stamp -gt $f.last_seen)  { $f.last_seen  = $evento.Stamp }
    }
    # La primera ocurrencia puede venir sin pantalla (stack recortado) y una posterior traerla.
    if (-not $f.pantalla -and $pantalla) { $f.pantalla = $pantalla }
    if ($f.files -notcontains $fichero) { $f.files += $fichero }
    if ($f.samples.Count -lt $Samples) {
        $f.samples += [PSCustomObject]@{
            timestamp = $evento.Stamp
            file      = $fichero
            line      = $evento.LineNo
            text      = Recortar (Proteger ($evento.Lineas -join " | ")) 600
        }
    }
}

# --- Barrido -----------------------------------------------------------------------------
foreach ($file in $files) {
    if ($topeLineas) { break }
    $nombre = $file.Name

    # ELMAH: XML con un <error .../> por incidencia, no lineas.
    $esXml = $file.Extension -ieq ".xml"
    if ($esXml) {
        try {
            [xml]$xml = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        } catch { continue }
        $nodos = @($xml.SelectNodes("//error"))
        if ($nodos.Count -eq 0) { continue }
        $formatos["elmah-xml"] = $true
        foreach ($n in $nodos) {
            $stamp = "$($n.time)"
            if ($desdeDt) {
                [datetime]$dt = [datetime]::MinValue
                if ([datetime]::TryParse($stamp, [ref]$dt) -and $dt -lt $desdeDt) { continue }
            }
            $totalEventos++
            $cuerpo = @("$($n.type): $($n.message)")
            if ($n.detail) { $cuerpo += (("$($n.detail)" -split "`n") | Select-Object -First 20) }
            Registrar @{ Lineas = $cuerpo; Stamp = $stamp; LineNo = 0; Formato = "elmah-xml" } $nombre
        }
        continue
    }

    $evento   = $null
    $omitir   = $false   # cabecera descartada (nivel o -Desde): sus lineas no abren nada
    $nLinea   = 0
    try {
        foreach ($linea in [IO.File]::ReadLines($file.FullName, (Get-RsCodificacion $file.FullName))) {
            $nLinea++
            $lineas++
            if ($lineas -ge $MaxLines) { $topeLineas = $true; break }

            # Formato rs-cerrores: se prueba PRIMERO. Su cabecera lleva la fecha entre
            # parentesis detras de la etiqueta, asi que no casa $rxStamp (anclado al inicio);
            # y mientras un evento de este formato esta abierto, solo lo cierra otra cabecera
            # suya — dentro del SQL del mensaje hay fechas que si casarian $rxStamp.
            $mRs = $rxRsCab.Match($linea)
            if ($mRs.Success) {
                if ($evento) { $totalEventos++; Registrar $evento $nombre }
                $evento = $null
                $omitir = $false

                $nivel = Get-RsNivelEtiqueta $mRs.Groups[1].Value
                if ($nivel -and ($nivelSet -notcontains $nivel) -and
                    -not ($nivel -eq "WARNING" -and $nivelSet -contains "WARN")) { $omitir = $true; continue }

                # Stamp normalizado a "yyyy-MM-dd HH:mm:ss": el log lo escribe dd/MM/yyyy y con
                # la hora de una o dos cifras, que como texto ordena mal — y first_seen/last_seen
                # se calculan comparando cadenas.
                $stamp = "{0:D4}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2}" -f `
                         [int]$mRs.Groups[4].Value, [int]$mRs.Groups[3].Value, [int]$mRs.Groups[2].Value, `
                         [int]$mRs.Groups[5].Value, [int]$mRs.Groups[6].Value,
                         $(if ($mRs.Groups[7].Success) { [int]$mRs.Groups[7].Value } else { 0 })

                if ($desdeDt) {
                    [datetime]$dt = [datetime]::MinValue
                    if ([datetime]::TryParseExact($stamp, "yyyy-MM-dd HH:mm:ss",
                            [Globalization.CultureInfo]::InvariantCulture,
                            [Globalization.DateTimeStyles]::None, [ref]$dt) -and $dt -lt $desdeDt) {
                        $omitir = $true; continue
                    }
                }

                $formatos["rs-cerrores"] = $true
                $evento = @{ Lineas = @($linea); Stamp = $stamp; LineNo = $nLinea; Formato = "rs-cerrores" }
                continue
            }

            if ($evento -and $evento.Formato -eq "rs-cerrores") {
                if ($evento.Lineas.Count -lt 40) { $evento.Lineas += $linea }
                continue
            }
            $mStamp = $rxStamp.Match($linea)
            if ($mStamp.Success) {
                # Cierra el evento anterior antes de abrir el nuevo.
                if ($evento) { $totalEventos++; Registrar $evento $nombre }
                $evento = $null
                $omitir = $false

                $stamp  = $mStamp.Groups[1].Value
                $mNivel = $rxNivel.Match($linea)
                $nivel  = if ($mNivel.Success) { $mNivel.Groups[1].Value.ToUpper() } else { "" }

                # Nivel: si el log lo trae y no esta pedido, se descarta el evento entero.
                # $omitir hace que "descartar la cabecera" descarte tambien sus lineas de stack:
                # sin el, una linea con "...Exception" del evento tirado abre uno nuevo por el
                # camino del volcado plano, y el recuento cuenta lo que se acababa de filtrar.
                if ($nivel -and ($nivelSet -notcontains $nivel) -and
                    -not ($nivel -eq "WARNING" -and $nivelSet -contains "WARN")) { $omitir = $true; continue }
                if (-not $nivel -and -not $rxExcepcion.IsMatch($linea)) { $omitir = $true; continue }

                if ($desdeDt) {
                    [datetime]$dt = [datetime]::MinValue
                    if ([datetime]::TryParse(($stamp -replace ',', '.'), [ref]$dt) -and $dt -lt $desdeDt) { $omitir = $true; continue }
                }

                $formatos["nlog-log4net"] = $true
                $evento = @{ Lineas = @($linea); Stamp = $stamp; LineNo = $nLinea; Formato = "nlog-log4net" }
                continue
            }

            if ($evento) {
                # Continuacion (stack, inner exception) — acotada para no cargar el log entero.
                if ($evento.Lineas.Count -lt 40) { $evento.Lineas += $linea }
                continue
            }

            # Lineas de un evento ya descartado: no abren uno nuevo.
            if ($omitir) { continue }

            # Volcado plano sin timestamp: la propia linea de excepcion abre el evento.
            if ($rxExcepcion.IsMatch($linea) -and $linea.Trim()) {
                $formatos["stacktrace-plano"] = $true
                $evento = @{ Lineas = @($linea); Stamp = ""; LineNo = $nLinea; Formato = "stacktrace-plano" }
            }
        }
    } catch {
        continue
    }
    if ($evento) { $totalEventos++; Registrar $evento $nombre }
}

if ($firmas.Count -eq 0) {
    Emit @{
        success         = $true
        path            = $Path
        files_scanned   = $files.Count
        lines_scanned   = $lineas
        total_events    = 0
        format_detected = "desconocido"
        signatures      = @()
        truncated       = $false
        message         = "Sin errores reconocidos. Revisar -Glob, -Niveles o -Desde; si el log tiene un formato propio, indicarlo."
    }
    exit 0
}

$orden      = @($firmas.Values | Sort-Object -Property count -Descending)
$devueltas  = @($orden | Select-Object -First $MaxSignatures)
$formato    = if ($formatos.Keys.Count -eq 0) { "desconocido" }
              elseif ($formatos.Keys.Count -eq 1) { @($formatos.Keys)[0] }
              else { "mixto (" + (@($formatos.Keys) -join ', ') + ")" }

Emit @{
    success            = $true
    path               = $Path
    files_scanned      = $files.Count
    lines_scanned      = $lineas
    scan_truncated     = $topeLineas
    total_events       = $totalEventos
    format_detected    = $formato
    distinct_signatures = $orden.Count
    signatures         = $devueltas
    truncated          = ($orden.Count -gt $devueltas.Count)
}
