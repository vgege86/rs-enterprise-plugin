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
    [string]$To,
    [string]$Chain,
    [string]$HandlerStatus = "assigned",
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
        $msg = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Req.Method)), $Req.Url)
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
$validCommands = @("projects", "get", "list", "create", "transition", "comment", "attach", "download", "me", "advance")
if ($validCommands -notcontains $Command.ToLower()) {
    Fail "Comando desconocido: $Command. Válidos: $($validCommands -join ', ')."
}

# Validar args obligatorios por comando (guarda pura, antes de credenciales/red).
switch ($Command.ToLower()) {
    "get"    { if (-not $Id)      { Fail "Falta -Id." } }
    "list"   { if (-not $Project) { Fail "Falta -Project." } }
    "create" {
        if (-not $Project)     { Fail "Falta -Project." }
        if (-not $Summary)     { Fail "Falta -Summary (resumen de la issue)." }
        if (-not $Description) { Fail "Falta -Description." }
        if (-not $Category)    { Fail "Falta -Category." }
    }
    "transition" {
        if (-not $Id)     { Fail "Falta -Id." }
        if (-not $Status) { Fail "Falta -Status (nombre del estado destino)." }
    }
    "comment" {
        if (-not $Id)   { Fail "Falta -Id." }
        if (-not $Text) { Fail "Falta -Text (texto del comentario)." }
    }
    "attach" {
        if (-not $Id)    { Fail "Falta -Id." }
        if (-not $Files) { Fail "Falta -Files." }
        foreach ($f in ($Files -split ',')) {
            $p = $f.Trim(); if (-not $p) { continue }
            if (-not (Test-Path $p)) { Fail "Fichero no encontrado: $p" }
        }
    }
    "download" {
        if (-not $Id)     { Fail "Falta -Id." }
        if (-not $FileId) { Fail "Falta -FileId." }
        if (-not $Out)    { Fail "Falta -Out (ruta destino)." }
    }
    "advance" {
        if (-not $Id)    { Fail "Falta -Id." }
        if (-not $To)    { Fail "Falta -To (estado destino)." }
        if (-not $Chain) { Fail "Falta -Chain (cadena ordenada de estados, coma-separada)." }
    }
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
    "me" {
        $data = Get-Json (New-MantisRequest $cred.baseUrl "GET" "/users/me")
        Emit @{ success = $true; id = $data.id; name = $data.name; real_name = $data.real_name }
    }
    "get" {
        $data = Get-Json (New-MantisRequest $cred.baseUrl "GET" "/issues/$Id")
        Emit @{ success = $true; issue = $data.issues[0] }
    }
    "list" {
        $data = Get-Json (New-MantisRequest $cred.baseUrl "GET" "/issues?project_id=$Project&page_size=$PageSize")
        Emit @{ success = $true; issues = $data.issues }
    }
    "create" {
        $bodyObj = @{
            summary     = $Summary
            description = $Description
            project     = @{ id = $Project }
            category    = @{ name = $Category }
        }
        if ($Handler) { $bodyObj.handler = @{ id = $Handler } }
        $data = Get-Json (New-MantisRequest $cred.baseUrl "POST" "/issues" $bodyObj)
        Emit @{ success = $true; id = $data.issue.id; issue = $data.issue }
    }
    "transition" {
        $data = Get-Json (New-MantisRequest $cred.baseUrl "PATCH" "/issues/$Id" @{ status = @{ name = $Status } })
        Emit @{ success = $true; id = $Id; status = $Status }
    }
    "comment" {
        $null = Get-Json (New-MantisRequest $cred.baseUrl "POST" "/issues/$Id/notes" @{ text = $Text })
        Emit @{ success = $true; id = $Id }
    }
    "attach" {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $client = New-Object System.Net.Http.HttpClient
        try {
            $client.DefaultRequestHeaders.Add("Authorization", $cred.token)
            $content = New-Object System.Net.Http.MultipartFormDataContent
            foreach ($f in ($Files -split ',')) {
                $p = $f.Trim(); if (-not $p) { continue }
                $path  = (Resolve-Path $p).Path
                $bytes = [IO.File]::ReadAllBytes($path)
                $part  = New-Object System.Net.Http.ByteArrayContent(,$bytes)
                $part.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/octet-stream")
                $content.Add($part, "files[]", (Split-Path $path -Leaf))
            }
            $url  = "$($cred.baseUrl)/api/rest/index.php/issues/$Id/files"
            $resp = $client.PostAsync($url, $content).GetAwaiter().GetResult()
            $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $resp.IsSuccessStatusCode) { Fail (Protect-MantisToken "HTTP $([int]$resp.StatusCode). $body" $cred.token) }
            $attached = @()
            foreach ($f in ($Files -split ',')) { $p = $f.Trim(); if ($p) { $attached += (Split-Path $p -Leaf) } }
            Emit @{ success = $true; id = $Id; attached = $attached; count = $attached.Count }
        } catch {
            Fail (Protect-MantisToken "Error al adjuntar: $($_.Exception.Message)" $cred.token)
        } finally { if ($content) { $content.Dispose() }; $client.Dispose() }
    }
    "download" {
        $r = Invoke-MantisHttp (New-MantisRequest $cred.baseUrl "GET" "/issues/$Id/files/$FileId") $cred.token
        if (-not $r.ok) { Fail (Protect-MantisToken "HTTP $($r.status). $($r.body)" $cred.token) }
        [IO.File]::WriteAllText($Out, $r.body)
        Emit @{ success = $true; id = $Id; file = $Out }
    }
    "advance" {
        $cur = (Get-Json (New-MantisRequest $cred.baseUrl "GET" "/issues/$Id")).issues[0].status.name
        $chainArr = @($Chain -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        try { $path = @(Get-MantisAdvancePath $chainArr $cur $To) } catch { Fail (Protect-MantisToken $_.Exception.Message $cred.token) }
        if ($path.Count -eq 0) {
            Emit @{ success = $true; id = $Id; from = $cur; applied = @(); to = $cur; note = "ya en el estado destino" }
        } else {
            $applied = @()
            foreach ($step in $path) {
                $body = @{ status = @{ name = $step } }
                if ($Handler -and $step -eq $HandlerStatus) { $body.handler = @{ id = $Handler } }
                $r = Invoke-MantisHttp (New-MantisRequest $cred.baseUrl "PATCH" "/issues/$Id" $body) $cred.token
                if (-not $r.ok) { Fail (Protect-MantisToken "advance: paso a '$step' falló (HTTP $($r.status)). Aplicados: $($applied -join ', '). $($r.body)" $cred.token) }
                $applied += $step
            }
            Emit @{ success = $true; id = $Id; from = $cur; applied = $applied; to = $To }
        }
    }
    default { Fail "Comando aún no implementado: $Command." }
}
exit 0
