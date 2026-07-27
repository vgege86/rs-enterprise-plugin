# Funciones puras de la integración Mantis (dot-sourceable, sin red).
# Patrón: hooks/lib-dbconfig.ps1. El token NUNCA se emite: usar Protect-MantisToken.

function Get-MantisCreds {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Credenciales no encontradas: $Path. Crea el fichero con { baseUrl, token } (ver references/mantis.md)."
    }
    try { $c = Get-Content -Raw -Path $Path -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "No se pudo parsear $Path como JSON." }
    $baseUrl = ("$($c.baseUrl)").TrimEnd('/')
    $token   = "$($c.token)"
    if (-not $baseUrl -or -not $token) {
        throw "Credenciales incompletas en $Path (se requieren baseUrl, token)."
    }
    return @{ baseUrl = $baseUrl; token = $token }
}

function Protect-MantisToken {
    param([string]$Text, [string]$Token)
    if (-not $Token) { return $Text }
    return $Text.Replace($Token, "***")
}

# Calcula el tramo de la cadena ordenada de estados a recorrer (uno a uno) para ir
# de $Current a $Target, sin saltos. Devuelve SIEMPRE un array (incluso de 0 o 1 elemento).
function Get-MantisAdvancePath {
    param([string[]]$Chain, [string]$Current, [string]$Target)
    $ci = [array]::IndexOf($Chain, $Current)
    $ti = [array]::IndexOf($Chain, $Target)
    if ($ci -lt 0) { throw "Estado actual '$Current' no está en la cadena de transición." }
    if ($ti -lt 0) { throw "Estado destino '$Target' no está en la cadena de transición." }
    if ($ti -lt $ci) { throw "No se puede retroceder de '$Current' a '$Target' (el protocolo solo avanza)." }
    if ($ti -eq $ci) { $result = @() } else { $result = @($Chain[($ci + 1)..$ti]) }
    # ,$result (comma unario) evita que PowerShell "desenrolle" un array de 1 elemento al
    # devolverlo por la pipeline: sin esto, la llamadora recibiría un string suelto, no un array.
    return ,$result
}

function New-MantisRequest {
    param(
        [string]$BaseUrl,
        [string]$Method,
        [string]$PathAndQuery,
        $BodyObj = $null
    )
    $body = $null
    if ($null -ne $BodyObj) { $body = ConvertTo-Json $BodyObj -Depth 8 -Compress }
    return @{
        Method = $Method
        # index.php: el rewrite .htaccess no está activo en la instancia (verificado en vivo);
        # esta forma funciona con y sin rewrite (más portable).
        Url    = "$BaseUrl/api/rest/index.php$PathAndQuery"
        Body   = $body
    }
}
