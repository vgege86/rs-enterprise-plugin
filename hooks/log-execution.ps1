<#
.SYNOPSIS
    Registra una ejecución del pipeline en executions/history/<desarrollador>.json.
    Se llama al final de cada pipeline para que /rs-historial tenga datos.

.DESCRIPTION
    ⛔ UN FICHERO POR DESARROLLADOR. Hasta la 3.26.x todas las ejecuciones iban a un único
    executions/history.json, y cada entrada nueva se insertaba AL PRINCIPIO del array. Con varios
    desarrolladores sobre el mismo trunk, todos modificaban las mismas primeras líneas del mismo
    fichero y SVN daba conflicto en cada update/commit. Añadir un campo "developer" no lo arregla
    (el conflicto es por líneas, no por campos): lo que lo arregla es que cada uno escriba solo en
    SU fichero. Los lectores (/rs-historial, /rs-stats, /rs-dashboard) juntan todos.

    El history.json antiguo no se toca: se sigue leyendo como histórico (entradas sin developer).

.PARAMETER Developer
    Quién ejecuta. Por defecto: $env:RS_DEVELOPER y, si no está, el usuario de Windows
    ($env:USERNAME). Se normaliza a minúsculas y [a-z0-9._-] para el nombre del fichero.

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
    [string]$Agents = "",
    [string]$Developer = ""
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

trap {
    @{ success = $false; error = $_.Exception.Message; step = "log-execution" } | ConvertTo-Json
    exit 1
}

. (Join-Path $PSScriptRoot "lib-pii.ps1")

# --- Quién: fija el fichero ---
if (-not $Developer) { $Developer = $env:RS_DEVELOPER }
if (-not $Developer) { $Developer = $env:USERNAME }
if (-not $Developer) { $Developer = $env:USER }
# DOMINIO\usuario -> usuario; solo caracteres seguros para un nombre de fichero.
$Developer = ($Developer -replace '^.*[\\/]', '').Trim().ToLowerInvariant() -replace '[^a-z0-9._-]', '_'
if (-not $Developer -or $Developer -match '^[._-]*$') { $Developer = "desconocido" }

$historyDir  = Join-Path (Join-Path $Workspace "executions") "history"
$historyFile = Join-Path $historyDir "$Developer.json"

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

# --- Saneado PII ---
# El texto de la tarea lo escribe el usuario y puede llevar datos personales
# ("revisar el deudor 12345678Z"). El historial se versiona y se lee en /rs-stats
# y /rs-dashboard, asi que un dato aqui se propaga a tres sitios mas.
$Task = Remove-RsPii $Task

# Nueva entrada
$entry = @{
    id        = [System.Guid]::NewGuid().ToString("N").Substring(0,8)
    timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    developer = $Developer
    solution  = $Solution
    workspace = $Workspace
    task      = $Task
    status    = $Status
    agents    = if ($Agents) { @($Agents -split ",") } else { @() }
}

# Añadir al inicio
$history = @($entry) + $history

# Rotación: si supera 500 → archivar las más antiguas a <dev>-archive-YYYYMM.json (también por
# desarrollador: un archivo compartido volvería a dar los mismos conflictos).
$maxEntries = 500
if ($history.Count -gt $maxEntries) {
    $toArchive  = $history[$maxEntries..($history.Count - 1)]
    $month      = (Get-Date -Format "yyyyMM")
    $archiveFile = Join-Path $historyDir "$Developer-archive-$month.json"

    # Cargar archivo existente del mes y añadir
    $existing = @()
    if (Test-Path $archiveFile) {
        try { $existing = @(Get-Content $archiveFile -Encoding UTF8 -Raw | ConvertFrom-Json) } catch { }
    }
    ConvertTo-Json -InputObject @($toArchive + $existing) -Depth 4 | Set-Content $archiveFile -Encoding UTF8

    $history = $history[0..($maxEntries - 1)]
}

# -InputObject: con la pipeline, un array de 1 elemento se escribiría como objeto suelto y el
# fichero de un desarrollador nuevo no sería un array.
ConvertTo-Json -InputObject @($history) -Depth 4 | Set-Content $historyFile -Encoding UTF8

@{
    success   = $true
    entry_id  = $entry.id
    developer = $Developer
    file      = $historyFile
    timestamp = $entry.timestamp
    total_entries = $history.Count
} | ConvertTo-Json
