<#
.SYNOPSIS
    Extrae schemas de tablas del modelo BD (BD/<proyecto>-model.json).
    Devuelve solo las tablas solicitadas para no saturar el contexto.

.PARAMETER Workspace
    Ruta raíz del proyecto (trunk).

.PARAMETER Tables
    Tablas a extraer, separadas por coma. Si se omite, devuelve lista de nombres.

.PARAMETER Proyecto
    Nombre del proyecto. Inferido del workspace si se omite.
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$Tables = "",
    [string]$Proyecto = ""
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

if (-not $Proyecto) {
    $Proyecto = Split-Path (Split-Path $Workspace -Parent) -Leaf
}

$modelPath = Join-Path $Workspace "BD\$Proyecto-model.json"
if (-not (Test-Path $modelPath)) {
    @{ success = $false; error = "Modelo no encontrado: $modelPath. Ejecuta 'actualiza el modelo BD' para crearlo." } | ConvertTo-Json
    exit 0
}

try {
    $model = Get-Content $modelPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    @{ success = $false; error = "Error al parsear $modelPath`: $_" } | ConvertTo-Json
    exit 0
}

$tableNames = ($model.tables | Get-Member -MemberType NoteProperty).Name
$engine     = $model.engine
$totalTables = $tableNames.Count

if (-not $Tables) {
    # Sin tablas específicas: devolver solo metadatos + lista de nombres
    @{
        success      = $true
        proyecto     = $Proyecto
        engine       = $engine
        table_count  = $totalTables
        table_names  = $tableNames
        model_path   = $modelPath
        note         = "Llama de nuevo con -Tables 'TABLA1,TABLA2' para obtener schemas."
    } | ConvertTo-Json -Depth 3
    exit 0
}

# Extraer schemas de tablas solicitadas
$requested = $Tables -split ',' | ForEach-Object { $_.Trim().ToUpper() }
$result = @{}
$notFound = @()

foreach ($tbl in $requested) {
    $tblDef = $model.tables.PSObject.Properties[$tbl]
    if ($tblDef) {
        $result[$tbl] = $tblDef.Value
    } else {
        # Búsqueda case-insensitive
        $match = $tableNames | Where-Object { $_ -eq $tbl } | Select-Object -First 1
        if (-not $match) { $match = $tableNames | Where-Object { $_ -ieq $tbl } | Select-Object -First 1 }
        if ($match) {
            $result[$match] = $model.tables.PSObject.Properties[$match].Value
        } else {
            $notFound += $tbl
        }
    }
}

@{
    success     = $true
    proyecto    = $Proyecto
    engine      = $engine
    tables      = $result
    not_found   = $notFound
    model_path  = $modelPath
} | ConvertTo-Json -Depth 8
