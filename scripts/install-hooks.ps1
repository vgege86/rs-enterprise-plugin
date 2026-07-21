# RS Enterprise Agent - Install  ⛔ OBSOLETO (v2.11.0)
#
# Este instalador es de la época PRE-PLUGIN. Copiaba agentes a ~/.claude/agents/, comandos a
# ~/.claude/commands/ y una copia vendorizada del server MCP a ~/.claude/rs-skill-full/.
# Desde que esto es un plugin de Claude Code, esas copias NO se actualizan con
# `/plugin marketplace update` y GANAN al plugin: el pipeline acaba ejecutando agentes viejos
# (p.ej. un planner que no emite PLAN/STAGES, con lo que el Gate A se salta en silencio).
# Fue exactamente lo que ocurrió el 2026-07-20 — ver CHANGELOG 2.11.0.
#
# Instalación correcta:  /plugin install rs-enterprise-agent@rs-enterprise-agent
# Diagnóstico:           /rs-env  → check "Coherencia instalación"
#
# Se conserva solo como referencia histórica. Aborta salvo -Force explícito.

param(
    [string]$SkillPath = ($PSScriptRoot | Split-Path -Parent),
    [switch]$Quiet,
    [switch]$Force
)

if (-not $Force) {
    Write-Host "⛔ install-hooks.ps1 esta OBSOLETO desde v2.11.0." -ForegroundColor Red
    Write-Host "   Crea copias en ~/.claude que sombrean al plugin y rompen el Gate A del pipeline."
    Write-Host "   Usa:  /plugin install rs-enterprise-agent@rs-enterprise-agent"
    Write-Host "   Comprueba con:  /rs-env  (check 'Coherencia instalación')"
    Write-Host "   Si aun asi sabes lo que haces:  install-hooks.ps1 -Force"
    exit 2
}

$commandsDest = "$env:USERPROFILE\.claude\commands"
$agentsDest   = "$env:USERPROFILE\.claude\agents"
$settingsPath = "$env:USERPROFILE\.claude\settings.json"
$claudeJsonPath = "$env:USERPROFILE\.claude.json"
$vendorDest   = "$env:USERPROFILE\.claude\rs-skill-full"
$runnerSrc    = Join-Path $SkillPath "runner\runner.ps1"
$commandsSrc  = Join-Path $SkillPath "commands"
$subagentsSrc = Join-Path $SkillPath "subagents"
$hooksSrc     = Join-Path $SkillPath "hooks"
$mcpSrc       = Join-Path $SkillPath "mcp"
$runnerDirSrc = Join-Path $SkillPath "runner"
$scriptsSrc   = Join-Path $SkillPath "scripts"

# Leer versión de SKILL.md
$skillMd = Join-Path $SkillPath "SKILL.md"
$version = "?"
if (Test-Path $skillMd) {
    $vLine = Get-Content $skillMd | Select-String 'version:' | Select-Object -First 1
    if ($vLine) { $version = ($vLine -replace '.*version:\s*"?([^"]+)"?.*','$1').Trim() }
}

Write-Host "====================================="
Write-Host " RS Enterprise Agent v$version — Install"
Write-Host "====================================="
Write-Host "Skill dir: $SkillPath"
Write-Host ""

if (!(Test-Path $runnerSrc)) { Write-Host "[ERROR] runner\runner.ps1 no encontrado en $runnerSrc"; exit 1 }

# Copia con diff por MD5 — mismo patrón para commands/hooks/mcp/runner.
# Devuelve [PSCustomObject]@{ New=[]; Updated=[]; Skipped=[] }
function Copy-DirWithDiff([string]$SrcDir, [string]$DestDir, [string]$Filter) {
    if (!(Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
    $res = [PSCustomObject]@{ New = @(); Updated = @(); Skipped = @() }
    foreach ($f in Get-ChildItem -Path $SrcDir -Filter $Filter -File) {
        $name     = $f.Name
        $destFile = Join-Path $DestDir $name
        $isNew    = -not (Test-Path $destFile)
        if (-not $isNew -and (Get-FileHash $f.FullName -Algorithm MD5).Hash -eq (Get-FileHash $destFile -Algorithm MD5).Hash) {
            $res.Skipped += $name; continue
        }
        Copy-Item $f.FullName $destFile -Force
        if ($isNew) { $res.New += $name } else { $res.Updated += $name }
    }
    return $res
}

# -AsHashtable de ConvertFrom-Json requiere pwsh 6+; convertimos a mano para funcionar en
# Windows PowerShell 5.1 también.
function ConvertTo-HashtableDeep {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process {
        if ($null -eq $InputObject) { return $InputObject }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $arr = @()
            foreach ($item in $InputObject) { $arr += , (ConvertTo-HashtableDeep $item) }
            return , $arr
        }
        if ($InputObject -is [PSCustomObject]) {
            $h = @{}
            foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
            return $h
        }
        return $InputObject
    }
}

# ── 1. Slash commands → ~/.claude/commands/
$cmdRes = Copy-DirWithDiff -SrcDir $commandsSrc -DestDir $commandsDest -Filter "*.md"
foreach ($n in $cmdRes.New)     { if (-not $Quiet) { Write-Host "[+] $n  [NUEVO]" } }
foreach ($n in $cmdRes.Updated) { if (-not $Quiet) { Write-Host "[^] $n  [ACTUALIZADO]" } }
$newFiles = $cmdRes.New; $updated = $cmdRes.Updated; $skipped = $cmdRes.Skipped

# ── 1a. Subagentes (model: haiku) → ~/.claude/agents/
$agentRes = Copy-DirWithDiff -SrcDir $subagentsSrc -DestDir $agentsDest -Filter "*.md"
foreach ($n in $agentRes.New)     { if (-not $Quiet) { Write-Host "[+] agents/$n  [NUEVO]" } }
foreach ($n in $agentRes.Updated) { if (-not $Quiet) { Write-Host "[^] agents/$n  [ACTUALIZADO]" } }

# ── 1b. Vendorizar hooks .ps1, scripts mcp/*.py y runner → ~/.claude/rs-skill-full/
#        No depende de tener el árbol fuente del plugin montado en tiempo de ejecución.
$hooksDest   = Join-Path $vendorDest "hooks"
$mcpDest     = Join-Path $vendorDest "mcp"
$runnerDest  = Join-Path $vendorDest "runner"
$scriptsDest = Join-Path $vendorDest "scripts"

$hooksRes   = Copy-DirWithDiff -SrcDir $hooksSrc     -DestDir $hooksDest   -Filter "*.ps1"
$mcpRes     = Copy-DirWithDiff -SrcDir $mcpSrc        -DestDir $mcpDest     -Filter "*.py"
$runnerRes  = Copy-DirWithDiff -SrcDir $runnerDirSrc  -DestDir $runnerDest  -Filter "*.ps1"
# scripts/*.py (analyze-dalc, export-dmd, generate-sql, render-erd): hooks como analyze-dalc.ps1
# los invocan vía ruta relativa a sí mismos (..\scripts\*.py) — sin vendorizar esta carpeta,
# esos hooks fallan al correr desde la copia local en ~/.claude/rs-skill-full/hooks/.
$scriptsRes = Copy-DirWithDiff -SrcDir $scriptsSrc    -DestDir $scriptsDest -Filter "*.py"

$vendorNew     = $hooksRes.New     + $mcpRes.New     + $runnerRes.New     + $scriptsRes.New
$vendorUpdated = $hooksRes.Updated + $mcpRes.Updated + $runnerRes.Updated + $scriptsRes.Updated
$vendorSkipped = $hooksRes.Skipped + $mcpRes.Skipped + $runnerRes.Skipped + $scriptsRes.Skipped
if (-not $Quiet) {
    Write-Host "[vendor] hooks:   $($hooksRes.New.Count) nuevos, $($hooksRes.Updated.Count) actualizados, $($hooksRes.Skipped.Count) sin cambios"
    Write-Host "[vendor] mcp:     $($mcpRes.New.Count) nuevos, $($mcpRes.Updated.Count) actualizados, $($mcpRes.Skipped.Count) sin cambios"
    Write-Host "[vendor] runner:  $($runnerRes.New.Count) nuevos, $($runnerRes.Updated.Count) actualizados, $($runnerRes.Skipped.Count) sin cambios"
    Write-Host "[vendor] scripts: $($scriptsRes.New.Count) nuevos, $($scriptsRes.Updated.Count) actualizados, $($scriptsRes.Skipped.Count) sin cambios"
}

# ── 2. Registrar Stop hook apuntando al runner VENDORIZADO (no a N:\)
$runnerAbsolute = (Resolve-Path (Join-Path $runnerDest "runner.ps1")).Path
# Sin escapar backslashes aquí — ConvertTo-Json ya los escapa al serializar; doblarlos antes corrompe el path.
$hookCommand    = "powershell -ExecutionPolicy Bypass -File `"$runnerAbsolute`""

if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    $settings = [PSCustomObject]@{}
}
if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -MemberType NoteProperty -Name 'hooks' -Value ([PSCustomObject]@{})
}
if (-not $settings.hooks.PSObject.Properties['Stop']) {
    $settings.hooks | Add-Member -MemberType NoteProperty -Name 'Stop' -Value @()
}

# Eliminar entradas anteriores del RS runner (copia vieja o skill dir anterior)
$settings.hooks.Stop = @($settings.hooks.Stop | Where-Object {
    -not ($_.hooks | Where-Object { $_.command -match 'runner\.ps1' -and $_.command -match '(rs-skill|hooks.rs)' })
})

$newHook = [PSCustomObject]@{
    matcher = ""
    hooks   = @([PSCustomObject]@{
        type          = "command"
        command       = $hookCommand
        shell         = "powershell"
        timeout       = 120
        statusMessage = "RS Runner..."
    })
}
$settings.hooks.Stop = @($settings.hooks.Stop) + $newHook
if (-not $Quiet) { Write-Host "[+] Stop hook → $runnerAbsolute" }

# ── 2b. Registrar UserPromptSubmit hook (skill-trigger) — detecta .sln en el prompt e
#        inyecta recordatorio de invocar la skill. Idempotente: elimina entradas previas.
$triggerAbsolute = (Resolve-Path (Join-Path $hooksDest "skill-trigger.ps1")).Path
$triggerCommand  = "powershell -ExecutionPolicy Bypass -File `"$triggerAbsolute`""

if (-not $settings.hooks.PSObject.Properties['UserPromptSubmit']) {
    $settings.hooks | Add-Member -MemberType NoteProperty -Name 'UserPromptSubmit' -Value @()
}
$settings.hooks.UserPromptSubmit = @($settings.hooks.UserPromptSubmit | Where-Object {
    -not ($_.hooks | Where-Object { $_.command -match 'skill-trigger\.ps1' })
})
$settings.hooks.UserPromptSubmit = @($settings.hooks.UserPromptSubmit) + [PSCustomObject]@{
    matcher = ""
    hooks   = @([PSCustomObject]@{
        type          = "command"
        command       = $triggerCommand
        shell         = "powershell"
        timeout       = 10
        statusMessage = "RS skill trigger..."
    })
}
if (-not $Quiet) { Write-Host "[+] UserPromptSubmit hook → $triggerAbsolute" }

$settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8

# ── 3. Registrar/actualizar MCP server "rs-workspace" en ~/.claude.json apuntando a la copia local
$mcpServerAbsolute = (Resolve-Path (Join-Path $mcpDest "rs-workspace-server.py")).Path
$mcpUpdated = $false
if (Test-Path $claudeJsonPath) {
    # $claudeJsonPath es grande y puede tener claves corruptas en secciones ajenas (ej. nombre de
    # propiedad "" en cachés internas) que hacen fallar CUALQUIER ConvertFrom-Json sobre el archivo
    # completo — ni -AsHashtable (no existe en PS 5.1, el powershell.exe que ejecuta el hook en
    # runtime) ni el parseo plano (PSCustomObject rechaza el nombre de propiedad vacío) lo evitan.
    # No arriesgar una reserialización completa de este archivo (config global compartida) — si no
    # se puede parsear entero, avisar y no tocarlo, en vez de adivinar o corromperlo.
    try {
        $claudeJson = Get-Content $claudeJsonPath -Raw | ConvertFrom-Json | ConvertTo-HashtableDeep
        if ($claudeJson.ContainsKey('mcpServers') -and $claudeJson.mcpServers.ContainsKey('rs-workspace')) {
            $currentArgs = @($claudeJson.mcpServers.'rs-workspace'.args)
            if ($currentArgs.Count -ne 1 -or $currentArgs[0] -ne $mcpServerAbsolute) {
                $claudeJson.mcpServers.'rs-workspace'.args = @($mcpServerAbsolute)
                $claudeJson | ConvertTo-Json -Depth 100 | Set-Content $claudeJsonPath -Encoding UTF8
            }
            $mcpUpdated = $true
            if (-not $Quiet) { Write-Host "[+] MCP rs-workspace → $mcpServerAbsolute" }
        } else {
            if (-not $Quiet) { Write-Host "[!] MCP rs-workspace no registrado en $claudeJsonPath — registrarlo manualmente apuntando a: $mcpServerAbsolute" }
        }
    } catch {
        if (-not $Quiet) { Write-Host "[!] No se pudo parsear $claudeJsonPath completo (claves corruptas en otra sección) — MCP rs-workspace no verificado/actualizado. Si ya estaba registrado sigue funcionando; si no, registrarlo a mano apuntando a: $mcpServerAbsolute" }
    }
} else {
    if (-not $Quiet) { Write-Host "[!] $claudeJsonPath no encontrado — MCP rs-workspace no actualizado" }
}

# ── Resumen
Write-Host ""
Write-Host "─────────────────────────────────────"
if ($newFiles.Count -gt 0) { Write-Host "  Commands nuevos ($($newFiles.Count)): $($newFiles -join ', ')" }
if ($updated.Count  -gt 0) { Write-Host "  Commands actualizados ($($updated.Count)): $($updated -join ', ')" }
Write-Host "  Commands sin cambios: $($skipped.Count)"
Write-Host "  Subagentes (Haiku) → $agentsDest : $($agentRes.New.Count) nuevos, $($agentRes.Updated.Count) actualizados, $($agentRes.Skipped.Count) sin cambios"
Write-Host "  Hooks/mcp/runner vendorizados en: $vendorDest"
Write-Host "    nuevos: $($vendorNew.Count) | actualizados: $($vendorUpdated.Count) | sin cambios: $($vendorSkipped.Count)"
if ($mcpUpdated) { Write-Host "  MCP rs-workspace: actualizado para usar la copia local" }
Write-Host "─────────────────────────────────────"
Write-Host "  Reiniciar Claude Code para aplicar cambios."
Write-Host "====================================="
