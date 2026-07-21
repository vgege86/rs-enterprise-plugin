<#
.SYNOPSIS
    Valida el entorno de trabajo RS Enterprise Agent.
.PARAMETER workspace
    Ruta del workspace (carpeta raíz del proyecto trunk/).
.PARAMETER proyecto
    Nombre del proyecto AIS (ej: <Proyecto>).
.EXAMPLE
    .\check-env.ps1 "C:\SVN\RS\<Proyecto>\trunk" "<Proyecto>"
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$workspace,

    [Parameter(Mandatory=$true)]
    [string]$proyecto
)

$results = @()
$overallStatus = "LISTO"

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $script:results += [PSCustomObject]@{
        Check  = $Name
        Status = $Status
        Detail = $Detail
    }
    if ($Status -eq "FAIL" -and $script:overallStatus -ne "BLOQUEANTE") {
        $script:overallStatus = "BLOQUEANTE"
    } elseif ($Status -eq "WARN" -and $script:overallStatus -eq "LISTO") {
        $script:overallStatus = "ATENCION"
    }
}

# Check 1: .rs-databases.json
. (Join-Path $PSScriptRoot "lib-dbconfig.ps1")
$cfgPath = Join-Path $workspace "docs\.rs-databases.json"
if (Test-Path $cfgPath) {
    $cfg = Read-RsDatabases $workspace
    if ($cfg.ok) {
        $resumen = ($cfg.conexiones | ForEach-Object { "$($_.id) ($("$($_.motor)".ToUpper()))" }) -join ", "
        $detail  = "$($cfg.conexiones.Count) conexión(es): $resumen. Principal: $($cfg.conexiones[0].id)"
        Add-Check ".rs-databases.json" "OK" $detail
    } else {
        Add-Check ".rs-databases.json" "FAIL" $cfg.error
    }
} else {
    $legacy = Join-Path $workspace "docs\XMLConfig.xml"
    if (Test-Path $legacy) {
        Add-Check ".rs-databases.json" "FAIL" "Workspace sin migrar — ejecutar: hooks\convert-config.ps1 `"$workspace`""
    } else {
        Add-Check ".rs-databases.json" "FAIL" "No encontrado: $cfgPath"
    }
}

# Check 2: Ruta AIS base
$aisBase = "C:\ais\$proyecto\"
if (Test-Path $aisBase) {
    Add-Check "Ruta AIS" "OK" $aisBase
} else {
    Add-Check "Ruta AIS" "WARN" "No existe: $aisBase (puede ser proyecto nuevo)"
}

# Check 3: dotnet SDK
try {
    $dotnetOut = & dotnet --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Add-Check "dotnet SDK" "OK" "$dotnetOut"
    } else {
        Add-Check "dotnet SDK" "FAIL" "dotnet no disponible o error: $dotnetOut"
    }
} catch {
    Add-Check "dotnet SDK" "FAIL" "dotnet no encontrado en PATH"
}

# Check 4: SVN (no bloqueante — puede que el proyecto use Git en vez de SVN)
try {
    $svnOut = & svn --version --quiet 2>&1
    if ($LASTEXITCODE -eq 0) {
        Add-Check "SVN" "OK" "$svnOut"
    } else {
        Add-Check "SVN" "WARN" "svn no disponible — modos SVN no funcionarán"
    }
} catch {
    Add-Check "SVN" "WARN" "svn no encontrado en PATH — modos SVN no funcionarán"
}

# Check 4b: Git (no bloqueante — puede que el proyecto use SVN en vez de Git)
try {
    $gitOut = & git --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Add-Check "Git" "OK" "$gitOut"
    } else {
        Add-Check "Git" "WARN" "git no disponible — modos Git no funcionarán"
    }
} catch {
    Add-Check "Git" "WARN" "git no encontrado en PATH — modos Git no funcionarán"
}

# Check 5: Modelo BD (informativo)
$modelPath = Join-Path $workspace "BD\$proyecto-model.json"
if (Test-Path $modelPath) {
    try {
        $model = Get-Content $modelPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $updatedAt  = $model.updated_at
        $tableCount = ($model.tables | Get-Member -MemberType NoteProperty).Count
        Add-Check "Modelo BD" "OK" "Actualizado: $updatedAt, Tablas: $tableCount"
    } catch {
        Add-Check "Modelo BD" "WARN" "Existe pero error al leer JSON"
    }
} else {
    Add-Check "Modelo BD" "INFO" "No existe aún — ejecutar 'sincroniza el modelo BD'"
}

# Check 6: Documentación agentic
$docsPath = Join-Path $workspace "docs\agentic_manual\tecnica\00_INDICE_MAESTRO.md"
if (Test-Path $docsPath) {
    Add-Check "Docs agentic" "OK" "Índice maestro presente"
} else {
    Add-Check "Docs agentic" "WARN" "No encontrado — agente funcionará sin contexto técnico completo"
}

# Check 7: Coherencia de instalación — copias fuera del plugin que sombrean al pipeline.
# Una instalación manual antigua en ~/.claude deja agentes/comandos/hooks que ganan al plugin
# y hacen correr etapas obsoletas sin avisar (el planner viejo no emite PLAN/STAGES → sin Gate A).
$claudeHome = Join-Path $env:USERPROFILE ".claude"
$sombras = @()
foreach ($p in @(
    @{ Path = (Join-Path $claudeHome "agents");         Glob = "rs-*.md"; Que = "agentes" },
    @{ Path = (Join-Path $claudeHome "commands");       Glob = "rs-*.md"; Que = "comandos" }
)) {
    if (Test-Path $p.Path) {
        $n = @(Get-ChildItem -Path $p.Path -Filter $p.Glob -File -ErrorAction SilentlyContinue).Count
        if ($n -gt 0) { $sombras += "$n $($p.Que) en $($p.Path)" }
    }
}
foreach ($d in @("rs-skill-full", "hooks\rs", "hooks\scripts")) {
    $full = Join-Path $claudeHome $d
    if (Test-Path $full) { $sombras += "copia vendorizada en $full" }
}

# El MCP 'rs-workspace' debe servirse del plugin, no de una copia suelta
$mcpDetalle = ""
$claudeJson = Join-Path $env:USERPROFILE ".claude.json"
if (Test-Path $claudeJson) {
    try {
        $cj = Get-Content $claudeJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $srv = $cj.mcpServers.'rs-workspace'
        if ($srv -and $srv.args -and $srv.args.Count -gt 0) {
            $srvPath = [string]$srv.args[0]
            $mcpDetalle = "MCP rs-workspace → $srvPath"
            if ($srvPath -like "*\.claude\rs-skill-full\*") {
                $sombras += "MCP global apunta a la copia vendorizada ($srvPath)"
            }
        }
    } catch { }
}

if ($sombras.Count -gt 0) {
    Add-Check "Coherencia instalación" "FAIL" ("Copias fuera del plugin — el pipeline puede correr agentes obsoletos: " + ($sombras -join " | ") + ". Muévelas a un backup y reinicia Claude Code.")
} else {
    Add-Check "Coherencia instalación" "OK" ("Sin copias fuera del plugin. " + $mcpDetalle).Trim()
}

# Output JSON estructurado para consumo del agente
$output = @{
    workspace   = $workspace
    proyecto    = $proyecto
    timestamp   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    overall     = $overallStatus
    checks      = $results
}

$output | ConvertTo-Json -Depth 4
