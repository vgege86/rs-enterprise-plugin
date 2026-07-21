<#
.SYNOPSIS
    Compara el modelo BD local (model.json) con el esquema real de la base de datos.
    Devuelve JSON estructurado con las diferencias: tablas nuevas, columnas añadidas/eliminadas
    y columnas con tipo o nullable modificado.

.PARAMETER Workspace
    Ruta raíz del proyecto

.EXAMPLE
    .\compare-model.ps1 "C:\SVN\RS\<Proyecto>\trunk"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$Tables = ""   # Coma-separadas. Vacío = todas las tablas.
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$hooksDir   = Split-Path $PSCommandPath -Parent
. (Join-Path $hooksDir "lib-dbconfig.ps1")

$configJson = & "$hooksDir\get-config.ps1" $Workspace | ConvertFrom-Json
if ($configJson.error) {
    @{ success = $false; error = $configJson.error } | ConvertTo-Json; exit 1
}

$motor      = $configJson.motor
$datasource = $configJson.datasource
$schema     = $configJson.schema
$modelPath  = $configJson.model_path

# Password: no se expone vía get-config.ps1/get_db_config — leer directo de .rs-databases.json
$dbCfg = Read-RsDatabases (Resolve-RsWorkspace $Workspace)
if (-not $dbCfg.ok) {
    @{ success = $false; error = $dbCfg.error } | ConvertTo-Json; exit 1
}
$password = Get-CsPart -Cadena "$($dbCfg.conexiones[0].cadena)" -Clave "Password"

if (-not (Test-Path $modelPath)) {
    @{ success = $false; error = "Modelo BD no encontrado: $modelPath. Ejecutar /rs-erd primero." } | ConvertTo-Json; exit 1
}

# Cargar modelo local
# model.tables es un PSCustomObject con una propiedad por tabla (no un array) — igual
# que en sync-from-db.ps1. Usar variable propia ($modelTableList), NUNCA "$tables": PowerShell
# es case-insensitive y colisionaría con el parámetro tipado [string]$Tables, coaccionándolo
# a texto y rompiendo el filtro de tablas (bug confirmado esta sesión).
$modelRaw    = Get-Content $modelPath -Encoding UTF8 -Raw | ConvertFrom-Json
$modelTables = @{}
foreach ($tName in ($modelRaw.tables | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
    $modelTables[$tName.ToUpper()] = $modelRaw.tables.$tName
}

# ── Normalizar tipo del modelo (quitar CHAR/BYTE qualifier, normalizar espacios) ──
function Normalize-ModelType([string]$t) {
    if (-not $t) { return "" }
    return ($t -replace '\s+CHAR\s*\)', ')' -replace '\s+BYTE\s*\)', ')' -replace '\s+', '').ToUpper().Trim()
}

# ── Reconstruir tipo normalizado desde BD ──
function Build-DbType([string]$dataType, [string]$charLen, [string]$precision, [string]$scale) {
    $dt  = $dataType.Trim().ToUpper()
    $cl  = [int]($charLen   -replace '[^0-9]','0')
    $p   = [int]($precision -replace '[^0-9]','0')
    $s   = [int]($scale     -replace '[^0-9]','0')
    if ($dt -in @('VARCHAR2','VARCHAR','CHAR','NVARCHAR2','NVARCHAR','NCHAR') -and $cl -gt 0) {
        return "$dt($cl)"
    }
    if ($dt -eq 'NUMBER' -or $dt -in @('DECIMAL','NUMERIC','FLOAT')) {
        if ($p -gt 0 -and $s -gt 0) { return "$dt($p,$s)" }
        if ($p -gt 0)               { return "$dt($p)" }
        return $dt
    }
    return $dt
}

# ── Query a BD ──
$dbTables = @{}  # [tableName] => list of @{name, db_type, nullable}

# Filtro de tablas opconal
$tableFilter = ""
if ($Tables -and $Tables.Trim() -ne "") {
    $tableList = ($Tables -split "," | ForEach-Object { "'$($_.Trim().ToUpper())'" }) -join ","
    $tableFilter = "AND TABLE_NAME IN ($tableList)"
}

if ($motor -eq "ORACLE") {
    if (-not (Get-Command "sqlplus" -ErrorAction SilentlyContinue)) {
        @{ success = $false; error = "sqlplus no disponible en PATH" } | ConvertTo-Json; exit 1
    }
    $query = @"
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF VERIFY OFF TRIMOUT ON TRIMSPOOL ON
CONNECT $($configJson.user)/$password@$datasource
SELECT TABLE_NAME || '|' || COLUMN_NAME || '|' || DATA_TYPE || '|' ||
       NVL(TO_CHAR(CHAR_LENGTH),'0') || '|' || NULLABLE || '|' ||
       NVL(TO_CHAR(DATA_PRECISION),'0') || '|' || NVL(TO_CHAR(DATA_SCALE),'0')
FROM ALL_TAB_COLUMNS WHERE OWNER = UPPER('$schema') $tableFilter
ORDER BY TABLE_NAME, COLUMN_ID;
EXIT;
"@
    $tmpSql = [System.IO.Path]::GetTempFileName() + ".sql"
    # ASCII, no UTF8: en PS5.1 Set-Content -Encoding UTF8 SIEMPRE antepone BOM, aunque el
    # contenido sea ASCII puro — el BOM corrompe la primera línea SQL (SP2-0734), sqlplus la
    # ignora, HEADING/PAGESIZE quedan en default y la cabecera se reimprime como fila fantasma.
    $query | Set-Content $tmpSql -Encoding ASCII
    $output = sqlplus -S /nolog "@$tmpSql" 2>&1
    Remove-Item $tmpSql -ErrorAction SilentlyContinue
} elseif ($motor -eq "SQLSERVER") {
    if (-not (Get-Command "sqlcmd" -ErrorAction SilentlyContinue)) {
        @{ success = $false; error = "sqlcmd no disponible en PATH" } | ConvertTo-Json; exit 1
    }
    $query = @"
SELECT TABLE_NAME + '|' + COLUMN_NAME + '|' + DATA_TYPE + '|' +
       CAST(ISNULL(CHARACTER_MAXIMUM_LENGTH,0) AS VARCHAR) + '|' + IS_NULLABLE + '|' +
       CAST(ISNULL(NUMERIC_PRECISION,0) AS VARCHAR) + '|' + CAST(ISNULL(NUMERIC_SCALE,0) AS VARCHAR)
FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = '$schema' $tableFilter
ORDER BY TABLE_NAME, ORDINAL_POSITION
"@
    $output = sqlcmd -S $datasource -d $schema -Q $query -h -1 -W 2>&1
} else {
    @{ success = $false; error = "Motor no soportado: $motor" } | ConvertTo-Json; exit 1
}

# Parsear output
foreach ($line in $output) {
    $parts = ($line -as [string]).Trim() -split '\|'
    if ($parts.Count -ge 7 -and $parts[0] -match '^\w+$') {
        $tbl = $parts[0].Trim().ToUpper()
        $dbType = Build-DbType $parts[2].Trim() $parts[3].Trim() $parts[5].Trim() $parts[6].Trim()
        $nullableDb = ($parts[4].Trim() -in @('Y','YES'))
        if (-not $dbTables[$tbl]) { $dbTables[$tbl] = @() }
        $dbTables[$tbl] += @{ name = $parts[1].Trim().ToUpper(); db_type = $dbType; nullable = $nullableDb }
    }
}

# ── Calcular diff ──
$added    = @()
$removed  = @()
$modified = @()

foreach ($tbl in $dbTables.Keys) {
    if (-not $modelTables[$tbl]) { $added += $tbl }
}
foreach ($tbl in $modelTables.Keys) {
    if (-not $dbTables[$tbl]) { $removed += $tbl }
}

foreach ($tbl in ($dbTables.Keys | Where-Object { $modelTables[$_] })) {
    $dbColMap    = @{}
    foreach ($c in $dbTables[$tbl]) { $dbColMap[$c.name] = $c }
    $modelColMap = @{}
    $modelCols = $modelTables[$tbl].columns
    if ($modelCols) {
        foreach ($cName in ($modelCols | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
            $modelColMap[$cName.ToUpper()] = $modelCols.$cName
        }
    }

    $dbColNames    = @($dbColMap.Keys)
    $modelColNames = @($modelColMap.Keys)

    $newCols  = @($dbColNames    | Where-Object { $_ -notin $modelColNames })   # en BD, no en modelo
    $dropCols = @($modelColNames | Where-Object { $_ -notin $dbColNames })      # en modelo, no en BD

    # Columnas presentes en ambos — comparar tipo y nullable
    $modifiedCols = @()
    foreach ($colName in ($dbColNames | Where-Object { $_ -in $modelColNames })) {
        $dbCol    = $dbColMap[$colName]
        $modelCol = $modelColMap[$colName]

        $modelTypeStr = if ($modelCol.type) { $modelCol.type } else { "" }
        $dbTypeNorm    = Normalize-ModelType $dbCol.db_type
        $modelTypeNorm = Normalize-ModelType $modelTypeStr

        $typeChanged     = $dbTypeNorm -ne $modelTypeNorm -and $modelTypeNorm -ne ""
        $modelNullable   = if ($null -ne $modelCol.nullable) { [bool]$modelCol.nullable } else { $true }
        $nullableChanged = $dbCol.nullable -ne $modelNullable

        if ($typeChanged -or $nullableChanged) {
            $entry = @{ column = $colName }
            if ($typeChanged)     { $entry.db_type = $dbCol.db_type; $entry.model_type = $modelTypeStr }
            if ($nullableChanged) { $entry.db_nullable = $dbCol.nullable; $entry.model_nullable = $modelNullable }
            $modifiedCols += $entry
        }
    }

    if ($newCols.Count -gt 0 -or $dropCols.Count -gt 0 -or $modifiedCols.Count -gt 0) {
        $modified += @{
            table            = $tbl
            new_columns      = $newCols       # en BD, no en modelo → candidatos a DROP o a añadir al modelo
            removed_columns  = $dropCols      # en modelo, no en BD → ALTER TABLE ADD
            modified_columns = $modifiedCols  # tipo o nullable difieren → ALTER TABLE MODIFY
        }
    }
}

@{
    success          = $true
    motor            = $motor
    schema           = $schema
    model_path       = $modelPath
    tables_filter    = if ($Tables) { $Tables } else { $null }
    tables_in_db     = $dbTables.Count
    tables_in_model  = $modelTables.Count
    added_in_db      = $added
    removed_from_db  = $removed
    modified         = $modified
    drift_detected   = ($added.Count + $removed.Count + $modified.Count) -gt 0
} | ConvertTo-Json -Depth 5
