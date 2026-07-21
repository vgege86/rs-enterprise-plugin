<#
.SYNOPSIS
    Adjunta uno o varios ficheros a una issue de Jira (Jira Cloud REST v3).
    Cubre el hueco del MCP Atlassian Rovo, que no expone attachment.

.DESCRIPTION
    Lee credenciales de %USERPROFILE%\.claude\rs-jira-credentials.json (baseUrl, email, token),
    hace Basic auth email:token y POST multipart a
    {baseUrl}/rest/api/3/issue/{IssueKey}/attachments con header X-Atlassian-Token: no-check.
    JSON in/out (misma convención que detect-vcs.ps1). El token NUNCA se escribe en stdout/stderr.

.PARAMETER IssueKey
    Clave de la issue (ej. PROJ-123).

.PARAMETER Files
    Rutas de fichero coma-separadas (una o varias).

.EXAMPLE
    .\jira-attach.ps1 -IssueKey PROJ-123 -Files "C:\AIS\<Proyecto>\scripts\mig-001.sql"
    .\jira-attach.ps1 -IssueKey PROJ-123 -Files "C:\a\1.sql,C:\a\2.sql"
#>
param(
    [Parameter(Mandatory = $true)][string]$IssueKey,
    [Parameter(Mandatory = $true)][string]$Files
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

function Fail([string]$msg) {
    @{ success = $false; issue = $IssueKey; error = $msg } | ConvertTo-Json -Compress
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

# --- ficheros ---
$fileList = @()
foreach ($f in ($Files -split ',')) {
    $p = $f.Trim()
    if (-not $p) { continue }
    if (-not (Test-Path $p)) { Fail "Fichero no encontrado: $p" }
    $fileList += (Resolve-Path $p).Path
}
if ($fileList.Count -eq 0) { Fail "No se indicaron ficheros válidos." }

# --- request multipart (HttpClient, compatible con Windows PowerShell 5.1) ---
try {
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $client  = New-Object System.Net.Http.HttpClient
    $basic   = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$email`:$token"))
    $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Basic", $basic)
    $client.DefaultRequestHeaders.Add("X-Atlassian-Token", "no-check")

    $content = New-Object System.Net.Http.MultipartFormDataContent
    $streams = @()
    foreach ($path in $fileList) {
        $bytes = [IO.File]::ReadAllBytes($path)
        $part  = New-Object System.Net.Http.ByteArrayContent(,$bytes)
        $part.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/octet-stream")
        $content.Add($part, "file", (Split-Path $path -Leaf))
        $streams += $part
    }

    $url  = "$baseUrl/rest/api/3/issue/$IssueKey/attachments"
    $resp = $client.PostAsync($url, $content).GetAwaiter().GetResult()
    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    if (-not $resp.IsSuccessStatusCode) {
        Fail "Jira devolvió HTTP $([int]$resp.StatusCode). $body"
    }

    $attached = @()
    try {
        $parsed = $body | ConvertFrom-Json
        foreach ($a in $parsed) { if ($a.filename) { $attached += $a.filename } }
    } catch { }
    if ($attached.Count -eq 0) { foreach ($p in $fileList) { $attached += (Split-Path $p -Leaf) } }

    @{ success = $true; issue = $IssueKey; attached = $attached; count = $attached.Count } | ConvertTo-Json -Compress
    exit 0
}
catch {
    Fail "Error al adjuntar: $($_.Exception.Message)"
}
finally {
    if ($content) { $content.Dispose() }
    if ($client)  { $client.Dispose() }
}
