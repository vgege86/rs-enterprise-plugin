<#
.SYNOPSIS
    Registra una ejecución del pipeline en executions/history.json.
    Se llama al final de cada pipeline para que /rs-historial tenga datos.

.PARAMETER Workspace
    Ruta raíz del proyecto

.PARAMETER Solution
    Nombre de la solución (sin .sln)

.PARAMETER Task
    Descripción breve del cambio realizado

.PARAMETER Status
    Estado final: success | fail | partial

.PARAMETER Agents
    Lista de agentes ejecutados, separados por coma

.EXAMPLE
    .\log-execution.ps1 "C:\...\trunk" "RSProcIN" "añadir validación fecha" "success" "planner,core,validator,tester,build"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Solution,
    [Parameter(Mandatory=$true)][string]$Task,
    [ValidateSet("success","fail","partial")][string]$Status = "success",
    [string]$Agents = ""
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

trap {
    @{ success = $false; error = $_.Exception.Message; step = "log-execution" } | ConvertTo-Json
    exit 1
}

$historyDir  = Join-Path $Workspace "executions"
$historyFile = Join-Path $historyDir "history.json"

if (-not (Test-Path $historyDir)) { New-Item -ItemType Directory -Force $historyDir | Out-Null }

# Cargar historial existente
$history = @()
if (Test-Path $historyFile) {
    try {
        $raw = Get-Content $historyFile -Encoding UTF8 -Raw
        $loaded = $raw | ConvertFrom-Json
        $history = @($loaded)
    } catch { $history = @() }
}

# Nueva entrada
$entry = @{
    id        = [System.Guid]::NewGuid().ToString("N").Substring(0,8)
    timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    solution  = $Solution
    workspace = $Workspace
    task      = $Task
    status    = $Status
    agents    = if ($Agents) { @($Agents -split ",") } else { @() }
}

# Añadir al inicio
$history = @($entry) + $history

# Rotación: si supera 500 → archivar las más antiguas a history-archive-YYYYMM.json
$maxEntries = 500
if ($history.Count -gt $maxEntries) {
    $toArchive  = $history[$maxEntries..($history.Count - 1)]
    $month      = (Get-Date -Format "yyyyMM")
    $archiveFile = Join-Path $historyDir "history-archive-$month.json"

    # Cargar archivo existente del mes y añadir
    $existing = @()
    if (Test-Path $archiveFile) {
        try { $existing = @(Get-Content $archiveFile -Encoding UTF8 -Raw | ConvertFrom-Json) } catch { }
    }
    ($toArchive + $existing) | ConvertTo-Json -Depth 4 | Set-Content $archiveFile -Encoding UTF8

    $history = $history[0..($maxEntries - 1)]
}

$history | ConvertTo-Json -Depth 4 | Set-Content $historyFile -Encoding UTF8

@{
    success   = $true
    entry_id  = $entry.id
    timestamp = $entry.timestamp
    total_entries = $history.Count
} | ConvertTo-Json
