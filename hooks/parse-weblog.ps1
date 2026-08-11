<#
.SYNOPSIS
    Parsea logs de error de la capa web (NLog/log4net, ELMAH XML, volcados de stack .NET),
    agrupa las ocurrencias por FIRMA y devuelve solo el agregado.

.DESCRIPTION
    Un log de errores repite el mismo fallo cientos de veces. Lo que interesa para abrir tareas
    no son las lineas, son los TIPOS de error distintos. Este hook colapsa las N ocurrencias de
    un mismo fallo en una firma con su recuento y una muestra, y NUNCA emite el log completo:
    la salida es un JSON acotado (top -MaxSignatures firmas), pensado para caber en contexto.

    Firma = SHA1( tipo de excepcion + frame mas profundo de codigo propio + mensaje normalizado ).
    El mensaje se normaliza antes de hashear (numeros, GUIDs, fechas, rutas y hex -> marcadores),
    porque "Cliente 4711 no existe" y "Cliente 8322 no existe" son el mismo error.

    ⛔ PII: los logs de una web llevan datos reales de usuario y estos textos acaban copiados en
    un ticket. Mensajes y muestras pasan por Remove-RsPii (lib-pii.ps1) antes de salir.

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
$rxStamp     = [regex]::new('^\s*\[?(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?|\d{2}/\d{2}/\d{4}[ T]\d{2}:\d{2}:\d{2})')
$rxNivel     = [regex]::new('\b(FATAL|ERROR|WARN(?:ING)?|INFO|DEBUG|TRACE)\b')
$rxExcepcion = [regex]::new('([A-Za-z_][\w.]*(?:Exception|Error))\b')
$rxFrame     = [regex]::new('^\s*(?:at|en)\s+([\w.<>`+]+\.[\w<>`+]+)\s*\(')
# Marcos de plataforma: no identifican el fallo, el frame util es el primero que NO casa.
$rxPlataforma = [regex]::new('^(System\.|Microsoft\.|mscorlib|Newtonsoft\.|lambda_method|NLog\.|log4net\.)')

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

# --- Acumulador de firmas ----------------------------------------------------------------
$firmas       = @{}
$totalEventos = 0
$lineas       = 0
$topeLineas   = $false
$formatos     = @{}

function Registrar($evento, $fichero) {
    $texto = ($evento.Lineas -join "`n")

    # Excepcion: la primera del evento; si no hay ninguna, el error no es tipado.
    $mEx  = $rxExcepcion.Match($texto)
    $exc  = if ($mEx.Success) { $mEx.Groups[1].Value } else { "SinExcepcion" }

    # Frame propio: el primero que no sea plataforma (la cima del stack es lo mas profundo).
    $frame = ""
    foreach ($l in $evento.Lineas) {
        $mF = $rxFrame.Match($l)
        if ($mF.Success) {
            $cand = $mF.Groups[1].Value
            if (-not $rxPlataforma.IsMatch($cand)) { $frame = $cand; break }
            if (-not $frame) { $frame = $cand }   # respaldo si TODO es plataforma
        }
    }

    # Mensaje: la primera linea sin el prefijo de timestamp/nivel.
    $primera = $evento.Lineas[0]
    $msg = $rxStamp.Replace($primera, '')
    $msg = $rxNivel.Replace($msg, '', 1)
    $msg = $msg.Trim(" ", "-", "|", "[", "]", ":", "`t")

    $clave = "$exc|$frame|$(Normalizar $msg)"
    $hash  = Hash8 $clave

    if (-not $firmas.ContainsKey($hash)) {
        $firmas[$hash] = [PSCustomObject]@{
            hash       = $hash
            exception  = $exc
            origin     = $frame
            message    = Recortar (Remove-RsPii $msg) 300
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
    if ($f.files -notcontains $fichero) { $f.files += $fichero }
    if ($f.samples.Count -lt $Samples) {
        $f.samples += [PSCustomObject]@{
            timestamp = $evento.Stamp
            file      = $fichero
            line      = $evento.LineNo
            text      = Recortar (Remove-RsPii ($evento.Lineas -join " | ")) 600
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
            Registrar @{ Lineas = $cuerpo; Stamp = $stamp; LineNo = 0 } $nombre
        }
        continue
    }

    $evento = $null
    $nLinea = 0
    try {
        foreach ($linea in [IO.File]::ReadLines($file.FullName)) {
            $nLinea++
            $lineas++
            if ($lineas -ge $MaxLines) { $topeLineas = $true; break }

            $mStamp = $rxStamp.Match($linea)
            if ($mStamp.Success) {
                # Cierra el evento anterior antes de abrir el nuevo.
                if ($evento) { $totalEventos++; Registrar $evento $nombre }
                $evento = $null

                $stamp  = $mStamp.Groups[1].Value
                $mNivel = $rxNivel.Match($linea)
                $nivel  = if ($mNivel.Success) { $mNivel.Groups[1].Value.ToUpper() } else { "" }

                # Nivel: si el log lo trae y no esta pedido, se descarta el evento entero.
                if ($nivel -and ($nivelSet -notcontains $nivel) -and
                    -not ($nivel -eq "WARNING" -and $nivelSet -contains "WARN")) { continue }
                if (-not $nivel -and -not $rxExcepcion.IsMatch($linea)) { continue }

                if ($desdeDt) {
                    [datetime]$dt = [datetime]::MinValue
                    if ([datetime]::TryParse(($stamp -replace ',', '.'), [ref]$dt) -and $dt -lt $desdeDt) { continue }
                }

                $formatos["nlog-log4net"] = $true
                $evento = @{ Lineas = @($linea); Stamp = $stamp; LineNo = $nLinea }
                continue
            }

            if ($evento) {
                # Continuacion (stack, inner exception) — acotada para no cargar el log entero.
                if ($evento.Lineas.Count -lt 40) { $evento.Lineas += $linea }
                continue
            }

            # Volcado plano sin timestamp: la propia linea de excepcion abre el evento.
            if ($rxExcepcion.IsMatch($linea) -and $linea.Trim()) {
                $formatos["stacktrace-plano"] = $true
                $evento = @{ Lineas = @($linea); Stamp = ""; LineNo = $nLinea }
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
