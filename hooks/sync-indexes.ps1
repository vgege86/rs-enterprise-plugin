<#
.SYNOPSIS
    Sincroniza índices de la BD real (ALL_INDEXES) al modelo JSON.
    Reemplaza índices con source="db"; preserva source="manual".
    Output JSON: success, table_count, index_count, model_path.

.PARAMETER Workspace
    Ruta raíz del proyecto (trunk).

.PARAMETER Proyecto
    Nombre del proyecto. Inferido del workspace si se omite.
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$Proyecto = ""
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

trap {
    @{ success = $false; error = $_.Exception.Message; step = "sync-indexes" } | ConvertTo-Json
    exit 1
}

$hooksDir = Split-Path $PSCommandPath -Parent
. (Join-Path $hooksDir "lib-dbconfig.ps1")

$Workspace = Resolve-RsWorkspace $Workspace
if (-not $Proyecto) { $Proyecto = Split-Path (Split-Path $Workspace -Parent) -Leaf }

$cfg = Read-RsDatabases $Workspace
if (-not $cfg.ok) { throw $cfg.error }

$c      = $cfg.conexiones[0]
$motor  = "$($c.motor)".ToUpper()
$cadena = "$($c.cadena)"

$rawDs = Get-CsPart -Cadena $cadena -Clave "Data Source"
if (-not $rawDs) { $rawDs = Get-CsPart -Cadena $cadena -Clave "Server" }
$user     = Get-CsPart -Cadena $cadena -Clave "User Id"
$password = Get-CsPart -Cadena $cadena -Clave "Password"
$schema   = if ($c.schema) { "$($c.schema)" } else { $user }

if ($motor -ne "ORACLE") { throw "sync-indexes solo soporta Oracle (motor actual: $motor)" }

$modelPath = Join-Path $Workspace "BD\$Proyecto-model.json"
if (-not (Test-Path $modelPath)) { throw "Modelo no encontrado: $modelPath" }

$model = Get-Content $modelPath -Raw -Encoding UTF8 | ConvertFrom-Json
# El owner real de las tablas puede no ser el usuario de conexión — el modelo ya existe
# (chequeado arriba), su "schema" es la fuente de verdad si la conexión de .rs-databases.json
# no trae uno explícito.
if ($schema -eq $user -and $model.schema) { $schema = $model.schema }
$schemaFilter = if ($schema) { $schema.ToUpper() } else { $user.ToUpper() }

# Consulta Oracle: ALL_INDEXES + ALL_IND_COLUMNS
$tempSql = [System.IO.Path]::GetTempFileName() + ".sql"
$tempOut = [System.IO.Path]::GetTempFileName() + ".csv"

@"
SET HEADING OFF
SET PAGESIZE 0
SET FEEDBACK OFF
SET LINESIZE 500
CONNECT $user/$password@$rawDs
SELECT i.TABLE_NAME || '|' || i.INDEX_NAME || '|' || i.UNIQUENESS || '|' ||
       ic.COLUMN_NAME || '|' || ic.COLUMN_POSITION
FROM ALL_INDEXES i
JOIN ALL_IND_COLUMNS ic
  ON ic.INDEX_NAME = i.INDEX_NAME AND ic.INDEX_OWNER = i.OWNER
WHERE i.OWNER = '$schemaFilter'
  AND i.INDEX_TYPE = 'NORMAL'
  AND i.STATUS     = 'VALID'
ORDER BY i.TABLE_NAME, i.INDEX_NAME, ic.COLUMN_POSITION;
EXIT;
"@ | Set-Content $tempSql -Encoding ASCII

sqlplus -S /nolog "@$tempSql" > $tempOut 2>&1
$rows = Get-Content $tempOut | Where-Object { $_ -match '\|' }

# Agrupar filas por (TABLE_NAME, INDEX_NAME)
$dbIndexes = @{}   # TABLE_NAME → @{ INDEX_NAME → @{unique, columns[]} }

foreach ($row in $rows) {
    $parts = $row.Trim() -split '\|'
    if ($parts.Count -lt 5) { continue }
    $tbl     = $parts[0].Trim()
    $idxName = $parts[1].Trim()
    $unique  = $parts[2].Trim() -eq 'UNIQUE'
    $col     = $parts[3].Trim()

    if (-not $tbl -or -not $idxName -or -not $col) { continue }

    if (-not $dbIndexes.ContainsKey($tbl))     { $dbIndexes[$tbl] = @{} }
    if (-not $dbIndexes[$tbl].ContainsKey($idxName)) {
        $dbIndexes[$tbl][$idxName] = @{ unique = $unique; columns = [System.Collections.Generic.List[string]]::new() }
    }
    $dbIndexes[$tbl][$idxName].columns.Add($col)
}

# Merge al modelo: reemplazar source=db, preservar source=manual
$totalIndexes = 0
foreach ($tName in ($model.tables | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
    $t = $model.tables.$tName

    # Conservar índices manuales
    $manual = @()
    if ($t.indexes) {
        $manual = @($t.indexes | Where-Object { $_.source -eq "manual" })
    }

    # Construir nuevos índices desde BD
    $newIdxs = @()
    if ($dbIndexes.ContainsKey($tName)) {
        foreach ($idxName in $dbIndexes[$tName].Keys) {
            $entry = $dbIndexes[$tName][$idxName]
            $newIdxs += [PSCustomObject]@{
                name    = $idxName
                columns = @($entry.columns)
                unique  = $entry.unique
                source  = "db"
            }
            $totalIndexes++
        }
    }

    $merged = @($manual) + @($newIdxs)
    $t | Add-Member -Force -NotePropertyName 'indexes' -NotePropertyValue $merged
}

# Guardar atómico
$model.updated_at = (Get-Date -Format "o")
$tmpPath = $modelPath + ".tmp"
$model | ConvertTo-Json -Depth 10 | Set-Content $tmpPath -Encoding UTF8
Move-Item $tmpPath $modelPath -Force

Remove-Item $tempSql, $tempOut -Force -ErrorAction SilentlyContinue

$tableCount = ($model.tables | Get-Member -MemberType NoteProperty).Count
@{
    success     = $true
    motor       = $motor
    schema      = $schemaFilter
    table_count = $tableCount
    index_count = $totalIndexes
    model_path  = $modelPath
    updated_at  = $model.updated_at
} | ConvertTo-Json
