# RS Enterprise Agent - Install a PROJECT scope (para comparar variantes sin tocar ~/.claude)
# Instala esta copia del skill (commands, subagentes, MCP) en el `.claude/` de UN proyecto concreto.
# Scope proyecto pisa a scope usuario por nombre (commands/agents/MCP) — abrir Claude Code en
# $ProjectPath corre esta variante; cualquier otra carpeta sigue con lo instalado en ~/.claude.
# ⛔ No toca hooks (Stop/UserPromptSubmit) — esos se combinan por scope en vez de pisarse,
#    duplicaría runner/logging si el usuario ya tiene el skill instalado globalmente.
# ⛔ No toca ~/.claude ni ~/.claude.json — instalación 100% local a $ProjectPath.

param(
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [string]$SkillPath = ($PSScriptRoot | Split-Path -Parent),
    [switch]$Quiet
)

if (!(Test-Path $ProjectPath)) { Write-Host "[ERROR] ProjectPath no existe: $ProjectPath"; exit 1 }
$ProjectPath = (Resolve-Path $ProjectPath).Path

$claudeDir      = Join-Path $ProjectPath ".claude"
$commandsDest   = Join-Path $claudeDir "commands"
$agentsDest     = Join-Path $claudeDir "agents"
$vendorDest     = Join-Path $claudeDir "rs-skill-full"
$mcpJsonPath    = Join-Path $ProjectPath ".mcp.json"
$userClaudeJson = "$env:USERPROFILE\.claude.json"

$runnerSrc    = Join-Path $SkillPath "runner\runner.ps1"
$commandsSrc  = Join-Path $SkillPath "commands"
$subagentsSrc = Join-Path $SkillPath "subagents"
$hooksSrc     = Join-Path $SkillPath "hooks"
$mcpSrc       = Join-Path $SkillPath "mcp"
$runnerDirSrc = Join-Path $SkillPath "runner"
$scriptsSrc   = Join-Path $SkillPath "scripts"

$skillMd = Join-Path $SkillPath "SKILL.md"
$version = "?"
if (Test-Path $skillMd) {
    $vLine = Get-Content $skillMd | Select-String 'version:' | Select-Object -First 1
    if ($vLine) { $version = ($vLine -replace '.*version:\s*"?([^"]+)"?.*', '$1').Trim() }
}

Write-Host "====================================="
Write-Host " RS Enterprise Agent v$version — Install a PROYECTO"
Write-Host "====================================="
Write-Host "Skill dir:    $SkillPath"
Write-Host "Project dir:  $ProjectPath"
Write-Host ""

if (!(Test-Path $runnerSrc)) { Write-Host "[ERROR] runner\runner.ps1 no encontrado en $runnerSrc"; exit 1 }

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

# ~/.claude.json es grande, tiene "mcpServers" repetido a distintos niveles (uno raíz + uno por
# cada entrada de "projects") y puede tener claves corruptas en otras secciones (p.ej. nombre de
# propiedad "" en cachés internas) que hacen fallar ConvertFrom-Json sobre el archivo completo
# (Add-Member no admite nombre vacío). Escaneamos solo las claves del objeto RAÍZ (profundidad 1)
# saltando el resto de valores sin parsearlos, y devolvemos el texto crudo del valor pedido.
function Get-RootJsonValueText([string]$Raw, [string]$Key) {
    $n = $Raw.Length
    $i = 0
    while ($i -lt $n -and $Raw[$i] -ne '{') { $i++ }
    $i++
    while ($i -lt $n) {
        while ($i -lt $n -and ($Raw[$i] -match '[\s,]')) { $i++ }
        if ($i -ge $n -or $Raw[$i] -eq '}') { break }
        if ($Raw[$i] -ne '"') { $i++; continue }
        $j = $i + 1
        while ($Raw[$j] -eq '\' -or $Raw[$j] -ne '"') { if ($Raw[$j] -eq '\') { $j += 2 } else { $j++ } }
        $curKey = $Raw.Substring($i + 1, $j - $i - 1)
        $i = $j + 1
        while ($Raw[$i] -ne ':') { $i++ }
        $i++
        while ($Raw[$i] -match '[\s]') { $i++ }
        $valueStart = $i
        if ($Raw[$i] -eq '{' -or $Raw[$i] -eq '[') {
            $open = $Raw[$i]; $close = if ($open -eq '{') { '}' } else { ']' }
            $depth = 0; $inString = $false; $escape = $false
            for (; $i -lt $n; $i++) {
                $ch = $Raw[$i]
                if ($escape) { $escape = $false; continue }
                if ($ch -eq '\') { if ($inString) { $escape = $true }; continue }
                if ($ch -eq '"') { $inString = -not $inString; continue }
                if ($inString) { continue }
                if ($ch -eq $open) { $depth++ }
                elseif ($ch -eq $close) { $depth--; if ($depth -eq 0) { $i++; break } }
            }
        } elseif ($Raw[$i] -eq '"') {
            $i++
            while ($Raw[$i] -eq '\' -or $Raw[$i] -ne '"') { if ($Raw[$i] -eq '\') { $i += 2 } else { $i++ } }
            $i++
        } else {
            while ($i -lt $n -and $Raw[$i] -ne ',' -and $Raw[$i] -ne '}') { $i++ }
        }
        $valueText = $Raw.Substring($valueStart, $i - $valueStart)
        if ($curKey -eq $Key) { return $valueText }
    }
    return $null
}

# Copia con diff por MD5 — mismo patrón que install-hooks.ps1.
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

# ── 1. Slash commands → <ProjectPath>\.claude\commands\
$cmdRes = Copy-DirWithDiff -SrcDir $commandsSrc -DestDir $commandsDest -Filter "*.md"
foreach ($n in $cmdRes.New)     { if (-not $Quiet) { Write-Host "[+] commands/$n  [NUEVO]" } }
foreach ($n in $cmdRes.Updated) { if (-not $Quiet) { Write-Host "[^] commands/$n  [ACTUALIZADO]" } }

# ── 2. Subagentes → <ProjectPath>\.claude\agents\
$agentRes = Copy-DirWithDiff -SrcDir $subagentsSrc -DestDir $agentsDest -Filter "*.md"
foreach ($n in $agentRes.New)     { if (-not $Quiet) { Write-Host "[+] agents/$n  [NUEVO]" } }
foreach ($n in $agentRes.Updated) { if (-not $Quiet) { Write-Host "[^] agents/$n  [ACTUALIZADO]" } }

# ── 3. Vendorizar hooks/mcp/scripts/runner → <ProjectPath>\.claude\rs-skill-full\
$hooksDest   = Join-Path $vendorDest "hooks"
$mcpDest     = Join-Path $vendorDest "mcp"
$runnerDest  = Join-Path $vendorDest "runner"
$scriptsDest = Join-Path $vendorDest "scripts"

$hooksRes   = Copy-DirWithDiff -SrcDir $hooksSrc     -DestDir $hooksDest   -Filter "*.ps1"
$mcpRes     = Copy-DirWithDiff -SrcDir $mcpSrc        -DestDir $mcpDest     -Filter "*.py"
$runnerRes  = Copy-DirWithDiff -SrcDir $runnerDirSrc  -DestDir $runnerDest  -Filter "*.ps1"
$scriptsRes = Copy-DirWithDiff -SrcDir $scriptsSrc    -DestDir $scriptsDest -Filter "*.py"

if (-not $Quiet) {
    Write-Host "[vendor] hooks:   $($hooksRes.New.Count) nuevos, $($hooksRes.Updated.Count) actualizados, $($hooksRes.Skipped.Count) sin cambios"
    Write-Host "[vendor] mcp:     $($mcpRes.New.Count) nuevos, $($mcpRes.Updated.Count) actualizados, $($mcpRes.Skipped.Count) sin cambios"
    Write-Host "[vendor] runner:  $($runnerRes.New.Count) nuevos, $($runnerRes.Updated.Count) actualizados, $($runnerRes.Skipped.Count) sin cambios"
    Write-Host "[vendor] scripts: $($scriptsRes.New.Count) nuevos, $($scriptsRes.Updated.Count) actualizados, $($scriptsRes.Skipped.Count) sin cambios"
}

# ── 4. MCP server "rs-workspace" en <ProjectPath>\.mcp.json (scope proyecto — pisa al de usuario
#        solo dentro de $ProjectPath). Copia command/type reales de la entrada de usuario en
#        ~/.claude.json (evita adivinar si es "python", "py", ruta completa, etc.) y solo
#        redirige "args" a la copia vendorizada del proyecto.
$mcpServerAbsolute = (Resolve-Path (Join-Path $mcpDest "rs-workspace-server.py")).Path
$userEntry = $null
if (Test-Path $userClaudeJson) {
    $userRaw = Get-Content $userClaudeJson -Raw
    $mcpServersText = Get-RootJsonValueText $userRaw 'mcpServers'
    if ($mcpServersText) {
        $mcpServersObj = $mcpServersText | ConvertFrom-Json
        if ($mcpServersObj.PSObject.Properties.Name -contains 'rs-workspace') {
            $userEntry = ConvertTo-HashtableDeep $mcpServersObj.'rs-workspace'
        }
    }
}

if ($userEntry) {
    $projectEntry = $userEntry.Clone()
    $projectEntry.args = @($mcpServerAbsolute)
} else {
    if (-not $Quiet) { Write-Host "[!] No se encontró rs-workspace en $userClaudeJson — completar 'command'/'type' a mano en $mcpJsonPath" }
    $projectEntry = [ordered]@{ type = "stdio"; command = "python"; args = @($mcpServerAbsolute) }
}

$mcpJson = if (Test-Path $mcpJsonPath) {
    Get-Content $mcpJsonPath -Raw | ConvertFrom-Json | ConvertTo-HashtableDeep
} else {
    @{ mcpServers = @{} }
}
if (-not $mcpJson.ContainsKey('mcpServers')) { $mcpJson.mcpServers = @{} }
$mcpJson.mcpServers.'rs-workspace' = $projectEntry
$mcpJson | ConvertTo-Json -Depth 20 | Set-Content $mcpJsonPath -Encoding UTF8
if (-not $Quiet) { Write-Host "[+] MCP rs-workspace ($mcpJsonPath) → $mcpServerAbsolute" }

# ── Resumen
Write-Host ""
Write-Host "─────────────────────────────────────"
Write-Host "  Commands  → $commandsDest : $($cmdRes.New.Count) nuevos, $($cmdRes.Updated.Count) actualizados, $($cmdRes.Skipped.Count) sin cambios"
Write-Host "  Subagentes → $agentsDest : $($agentRes.New.Count) nuevos, $($agentRes.Updated.Count) actualizados, $($agentRes.Skipped.Count) sin cambios"
Write-Host "  Vendor (hooks/mcp/scripts/runner) → $vendorDest"
Write-Host "  MCP rs-workspace (proyecto) → $mcpJsonPath"
Write-Host "─────────────────────────────────────"
Write-Host "  ⛔ Hooks (Stop/UserPromptSubmit) NO tocados — sigue usando los del scope usuario si existen."
Write-Host "  Abrir Claude Code en '$ProjectPath' y reiniciar para aplicar cambios."
Write-Host "  Cualquier OTRA carpeta sigue usando lo instalado en ~/.claude (sin cambios)."
Write-Host "====================================="
