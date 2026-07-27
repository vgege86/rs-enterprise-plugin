<#
.SYNOPSIS
    Descarga un adjunto de una issue de Jira (Jira Cloud REST v3) a un fichero local.
    Cubre el hueco del MCP Atlassian Rovo, que no expone descarga de attachments.

.DESCRIPTION
    Lee credenciales de %USERPROFILE%\.claude\rs-jira-credentials.json (baseUrl, email, token),
    hace Basic auth email:token y GET a {baseUrl}/rest/api/3/attachment/content/{FileId}
    (siguiendo redirects) con header X-Atlassian-Token: no-check. Escribe los bytes en -Out.
    JSON in/out (misma convención que jira-attach.ps1). El token NUNCA se escribe en stdout/stderr.

.PARAMETER IssueKey
    Clave de la issue (ej. PROJ-123). Solo para trazar en la salida.

.PARAMETER FileId
    Id numérico del adjunto (de fields.attachment[].id de la issue).

.PARAMETER Out
    Ruta de fichero destino donde escribir el adjunto.

.EXAMPLE
    .\jira-download.ps1 -IssueKey PROJ-123 -FileId 10456 -Out "N:\ws\docs\anexo.pdf"
#>
param(
    [Parameter(Mandatory = $true)][string]$IssueKey,
    [Parameter(Mandatory = $true)][string]$FileId,
    [Parameter(Mandatory = $true)][string]$Out
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

function Fail([string]$msg) {
    @{ success = $false; issue = $IssueKey; fileId = $FileId; error = $msg } | ConvertTo-Json -Compress
    exit 1
}

# --- credenciales (fuera del repo) ---
$credPath = Join-Path $env:USERPROFILE ".claude\rs-jira-credentials.json"
if (-not (Test-Path $credPath)) {
    Fail "Credenciales no encontradas: $credPath. Crea el fichero con { baseUrl, email, token } (ver references/jira.md)."
}
try {
    $cred = Get-Content -Raw -Path $credPath | ConvertFrom-Json
} catch {
    Fail "No se pudo parsear $credPath como JSON."
}
$baseUrl = ("$($cred.baseUrl)").TrimEnd('/')
$email   = "$($cred.email)"
$token   = "$($cred.token)"
if (-not $baseUrl -or -not $email -or -not $token) {
    Fail "Credenciales incompletas en $credPath (se requieren baseUrl, email, token)."
}

# --- destino ---
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) {
    try { New-Item -ItemType Directory -Path $outDir -Force | Out-Null } catch { Fail "No se pudo crear el directorio destino: $outDir" }
}

# --- request GET (HttpClient sin auto-redirect: la Authorization NO debe reenviarse a un host
#     cross-host en el 302 de Jira hacia su storage de media, p.ej. una URL presignada de AWS) ---
try {
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client  = New-Object System.Net.Http.HttpClient($handler)
    $basic   = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$email`:$token"))

    $url = "$baseUrl/rest/api/3/attachment/content/$FileId"
    $resp = $null
    $maxHops = 5
    for ($hop = 0; $hop -le $maxHops; $hop++) {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
        if ($hop -eq 0) {
            # Solo la petición inicial a Jira lleva credenciales propias.
            $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Basic", $basic)
            $req.Headers.Add("X-Atlassian-Token", "no-check")
        }
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()

        $status = [int]$resp.StatusCode
        if ($status -ge 300 -and $status -lt 400 -and $resp.Headers.Location) {
            $location = $resp.Headers.Location
            $url = if ($location.IsAbsoluteUri) { $location.AbsoluteUri } else { (New-Object System.Uri([System.Uri]$url, $location)).AbsoluteUri }
            continue
        }
        break
    }

    if (-not $resp.IsSuccessStatusCode) {
        Fail "Jira devolvió HTTP $([int]$resp.StatusCode) al descargar el adjunto $FileId."
    }

    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    [IO.File]::WriteAllBytes($Out, $bytes)

    @{ success = $true; issue = $IssueKey; fileId = $FileId; out = (Resolve-Path $Out).Path; bytes = $bytes.Length } | ConvertTo-Json -Compress
    exit 0
}
catch {
    Fail "Error al descargar: $($_.Exception.Message)"
}
finally {
    if ($client)  { $client.Dispose() }
    if ($handler) { $handler.Dispose() }
}
