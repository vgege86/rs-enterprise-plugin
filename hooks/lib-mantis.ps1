# Funciones puras de la integración Mantis (dot-sourceable, sin red).
# Patrón: hooks/lib-dbconfig.ps1. El token NUNCA se emite: usar Protect-MantisToken.

function Get-MantisCreds {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Credenciales no encontradas: $Path. Crea el fichero con { baseUrl, token } (ver references/mantis.md)."
    }
    try { $c = Get-Content -Raw -Path $Path | ConvertFrom-Json }
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
