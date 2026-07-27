# Cliente REST autónomo de MantisBT (2.x). JSON in/out. Llamado por la skill rs-mantis vía Bash.
# NO usa el MCP rs-workspace (esquiva el FP de CrowdStrike). El token nunca se emite.
param(
    [Parameter(Mandatory = $true)][string]$Command,
    [int]$Id,
    [int]$Project,
    [int]$PageSize = 50,
    [string]$Category,
    [string]$Summary,
    [string]$Description,
    [int]$Handler,
    [string]$Status,
    [string]$Text,
    [string]$Files,
    [int]$FileId,
    [string]$Out,
    [string]$CredPath = (Join-Path $env:USERPROFILE ".claude\rs-mantis-credentials.json")
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12   # PS 5.1 negocia TLS antiguo por defecto
. (Join-Path $PSScriptRoot "lib-mantis.ps1")

function Emit($obj)   { $obj | ConvertTo-Json -Depth 12 -Compress; }
function Fail($msg)   { Emit @{ success = $false; error = "$msg" }; exit 1 }

# Ejecutor HTTP (toca red; cubierto en verificación con token real, no en Pester).
function Invoke-MantisHttp {
    param($Req, [string]$Token)
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $client = New-Object System.Net.Http.HttpClient
    try {
        $client.DefaultRequestHeaders.Add("Authorization", $Token)
        $msg = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::$($Req.Method), $Req.Url)
        if ($Req.Body) {
            $msg.Content = New-Object System.Net.Http.StringContent($Req.Body, [Text.Encoding]::UTF8, "application/json")
        }
        $resp = $client.SendAsync($msg).GetAwaiter().GetResult()
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return @{ ok = $resp.IsSuccessStatusCode; status = [int]$resp.StatusCode; body = $body }
    } catch {
        return @{ ok = $false; status = 0; body = $_.Exception.Message }
    } finally { $client.Dispose() }
}

# Validar el comando antes de resolver credenciales (guarda pura, sin red ni fichero).
$validCommands = @("projects", "get", "list", "create", "transition", "comment", "attach", "download")
if ($validCommands -notcontains $Command.ToLower()) {
    Fail "Comando desconocido: $Command. Válidos: $($validCommands -join ', ')."
}

# Resolver credenciales (falla limpio antes de tocar red).
try { $cred = Get-MantisCreds $CredPath } catch { Fail $_.Exception.Message }

function Get-Json($req) {
    $r = Invoke-MantisHttp $req $cred.token
    if (-not $r.ok) { Fail (Protect-MantisToken "HTTP $($r.status). $($r.body)" $cred.token) }
    if ([string]::IsNullOrWhiteSpace($r.body)) { return $null }
    try { return ($r.body | ConvertFrom-Json) } catch { return $r.body }
}

switch ($Command.ToLower()) {
    "projects" {
        $data = Get-Json (New-MantisRequest $cred.baseUrl "GET" "/projects")
        Emit @{ success = $true; projects = $data.projects }
    }
    "get" {
        if (-not $Id) { Fail "Falta -Id." }
        $data = Get-Json (New-MantisRequest $cred.baseUrl "GET" "/issues/$Id")
        Emit @{ success = $true; issue = $data.issues[0] }
    }
    "list" {
        if (-not $Project) { Fail "Falta -Project." }
        $data = Get-Json (New-MantisRequest $cred.baseUrl "GET" "/issues?project_id=$Project&page_size=$PageSize")
        Emit @{ success = $true; issues = $data.issues }
    }
    default { Fail "Comando aún no implementado: $Command." }
}
exit 0
