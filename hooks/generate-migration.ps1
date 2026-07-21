<#
.SYNOPSIS
    Genera scripts SQL de migración a partir del drift entre model.json y BD real.
    CREATE TABLE   → tablas en modelo que no están en BD.
    ALTER TABLE ADD COLUMN  → columnas en modelo que no están en BD.
    ALTER TABLE MODIFY      → columnas con tipo o nullable diferente al modelo.
    DROP COLUMN (comentado) → columnas en BD que no están en el modelo.
    ADD CONSTRAINT FK       → claves foráneas de tablas nuevas.

.PARAMETER Workspace
    Ruta raíz del proyecto.

.EXAMPLE
    .\generate-migration.ps1 "C:\SVN\RS\<Proyecto>\trunk"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
$hooksDir = Split-Path $PSCommandPath -Parent

$configJson = & "$hooksDir\get-config.ps1" $Workspace | ConvertFrom-Json
if ($configJson.error) {
    @{ success = $false; error = $configJson.error } | ConvertTo-Json; exit 1
}

$motor     = $configJson.motor
$schema    = $configJson.schema
$modelPath = $configJson.model_path

$driftJson = & "$hooksDir\compare-model.ps1" $Workspace | ConvertFrom-Json
if (-not $driftJson.success) {
    @{ success = $false; error = $driftJson.error } | ConvertTo-Json; exit 1
}

if (-not $driftJson.drift_detected) {
    @{ success = $true; drift_detected = $false; message = "Sin drift — no se requieren migraciones"; sql_scripts = @() } | ConvertTo-Json
    exit 0
}

$model = Get-Content $modelPath -Encoding UTF8 -Raw | ConvertFrom-Json
$modelTables = @{}
$tables = if ($model.tables -is [System.Array]) { $model.tables } else { @($model.tables) }
foreach ($t in $tables) {
    $name = if ($t.name) { $t.name } else { $t.tableName }
    if ($name) { $modelTables[$name.ToUpper()] = $t }
}

# Añade semántica CHAR a VARCHAR2/NVARCHAR2/CHAR en Oracle.
# Sin CHAR, Oracle usa semántica de bytes por defecto → trunca strings multibyte (UTF-8).
# VARCHAR2(n) → VARCHAR2(n CHAR). Idempotente: el `)` tras `\d+` ya excluye VARCHAR2(n CHAR).
function Ensure-OracleChar([string]$type) {
    if (-not $type) { return $type }
    return $type -replace '(?i)(VARCHAR2|NVARCHAR2|CHAR)\((\d+)\)', '${1}(${2} CHAR)'
}

# Genera definición SQL de una columna desde el modelo
function Get-ColDef([object]$col, [string]$motor) {
    $name     = if ($col.name)      { $col.name }      else { $col.columnName }
    $type     = if ($col.type)      { $col.type }      elseif ($col.dataType)   { $col.dataType }   else { "VARCHAR2(50 CHAR)" }
    $nullable = if ($null -ne $col.nullable) { [bool]$col.nullable } else { $true }
    $nullStr  = if ($nullable) { "NULL" } else { "NOT NULL" }

    if ($motor -eq "ORACLE") {
        return "$name $(Ensure-OracleChar $type) $nullStr"
    } else {
        # SQL Server no usa semántica CHAR: VARCHAR2(n) / VARCHAR2(n CHAR) → VARCHAR(n)
        $type = $type -replace '(?i)VARCHAR2\((\d+)\s+CHAR\)', 'VARCHAR($1)' -replace 'VARCHAR2','VARCHAR' -replace 'NUMBER','DECIMAL'
        return "[$name] $type $nullStr"
    }
}

# Referencia a tabla/columna según motor
function Tref([string]$t) { if ($motor -eq "ORACLE") { "$schema.$t" } else { "[$schema].[$t]" } }
function Cref([string]$c) { if ($motor -eq "ORACLE") { $c } else { "[$c]" } }

$scripts = @()

# ─────────────────────────────────────────────────────────
# 1. Tablas en modelo que no están en BD → CREATE TABLE + FKs + INDEXes
# ─────────────────────────────────────────────────────────
foreach ($tableName in $driftJson.removed_from_db) {
    $tbl = $modelTables[$tableName]
    if (-not $tbl) { continue }

    # Columnas inline
    $colDefs = @($tbl.columns | ForEach-Object { "    " + (Get-ColDef $_ $motor) })

    # PK constraint inline
    $pkCols = @($tbl.columns | Where-Object { $_.pk } | ForEach-Object {
        if ($_.name) { $_.name } else { $_.columnName }
    })
    if ($pkCols.Count -gt 0) {
        $pkLine = "    CONSTRAINT PK_$tableName PRIMARY KEY (" + ($pkCols -join ", ") + ")"
        $colDefs += $pkLine
    }

    $sql = "-- [NUEVA TABLA] $tableName`nCREATE TABLE $(Tref $tableName) (`n" + ($colDefs -join ",`n") + "`n);"
    $scripts += [PSCustomObject]@{ operation = "CREATE_TABLE"; table = $tableName; column = $null; sql = $sql }

    # FKs
    foreach ($rel in @($tbl.relations | Where-Object { $_ })) {
        $srcCol  = $rel.source_column
        $tgtTbl  = $rel.target_table
        $tgtCol  = $rel.target_column
        if (-not $srcCol -or -not $tgtTbl -or -not $tgtCol) { continue }
        $fkName  = "FK_$($tableName)_$($srcCol)"
        $fkSql   = "ALTER TABLE $(Tref $tableName) ADD CONSTRAINT $fkName FOREIGN KEY ($(Cref $srcCol)) REFERENCES $(Tref $tgtTbl) ($(Cref $tgtCol));"
        $scripts += [PSCustomObject]@{ operation = "ADD_FK"; table = $tableName; column = $srcCol; sql = "-- [FK] $tableName.$srcCol → $tgtTbl.$tgtCol`n$fkSql" }
    }

    # Indexes
    foreach ($idx in @($tbl.indexes | Where-Object { $_ })) {
        $idxName  = $idx.name
        $idxCols  = ($idx.columns -join ', ')
        $uniqueKw = if ($idx.unique) { 'UNIQUE ' } else { '' }
        if (-not $idxName -or -not $idxCols) { continue }
        $idxSql = if ($motor -eq "ORACLE") {
            "CREATE $($uniqueKw)INDEX $schema.$idxName ON $schema.$tableName ($idxCols);"
        } else {
            "CREATE $($uniqueKw)INDEX $idxName ON [$schema].[$tableName] ($idxCols);"
        }
        $scripts += [PSCustomObject]@{ operation = "CREATE_INDEX"; table = $tableName; column = $null; sql = "-- [INDICE] $tableName.$idxName`n$idxSql" }
    }
}

# ─────────────────────────────────────────────────────────
# 2. Tablas modificadas: ADD, MODIFY, DROP (comentado)
# ─────────────────────────────────────────────────────────
foreach ($modEntry in $driftJson.modified) {
    $tableName = $modEntry.table
    $tbl = $modelTables[$tableName]

    # 2a. ADD COLUMN — columna en modelo, no en BD
    foreach ($colName in $modEntry.removed_columns) {
        $col = $null
        if ($tbl) {
            $col = @($tbl.columns) | Where-Object {
                ($_.name -as [string]).ToUpper() -eq $colName.ToUpper() -or
                ($_.columnName -as [string]).ToUpper() -eq $colName.ToUpper()
            } | Select-Object -First 1
        }
        $colDef = if ($col) { Get-ColDef $col $motor } else {
            if ($motor -eq "ORACLE") { "$colName VARCHAR2(100 CHAR) NULL  -- revisar tipo" }
            else                     { "[$colName] VARCHAR(100) NULL  -- revisar tipo" }
        }
        $sql = if ($motor -eq "ORACLE") {
            "-- [ADD COLUMN] $tableName.$colName`nALTER TABLE $(Tref $tableName) ADD ($colDef);"
        } else {
            "-- [ADD COLUMN] $tableName.$colName`nALTER TABLE $(Tref $tableName) ADD $colDef;"
        }
        $scripts += [PSCustomObject]@{ operation = "ADD_COLUMN"; table = $tableName; column = $colName; sql = $sql }
    }

    # 2b. MODIFY COLUMN — tipo o nullable difiere entre modelo y BD
    foreach ($mc in @($modEntry.modified_columns | Where-Object { $_ })) {
        $colName = $mc.column
        $col = $null
        if ($tbl) {
            $col = @($tbl.columns) | Where-Object {
                ($_.name -as [string]).ToUpper() -eq $colName.ToUpper() -or
                ($_.columnName -as [string]).ToUpper() -eq $colName.ToUpper()
            } | Select-Object -First 1
        }
        if (-not $col) { continue }
        $colDef = Get-ColDef $col $motor
        $changeDesc = @()
        if ($mc.db_type)     { $changeDesc += "tipo: BD=$($mc.db_type) → modelo=$($mc.model_type)" }
        if ($null -ne $mc.db_nullable) { $changeDesc += "nullable: BD=$($mc.db_nullable) → modelo=$($mc.model_nullable)" }
        $sql = if ($motor -eq "ORACLE") {
            "-- [MODIFY COLUMN] $tableName.$colName ($($changeDesc -join '; '))`nALTER TABLE $(Tref $tableName) MODIFY ($colDef);"
        } else {
            "-- [MODIFY COLUMN] $tableName.$colName ($($changeDesc -join '; '))`nALTER TABLE $(Tref $tableName) ALTER COLUMN $colDef;"
        }
        $scripts += [PSCustomObject]@{ operation = "MODIFY_COLUMN"; table = $tableName; column = $colName; sql = $sql }
    }

    # 2c. DROP COLUMN (comentado) — columna en BD pero no en modelo
    foreach ($colName in $modEntry.new_columns) {
        $comment = if ($motor -eq "ORACLE") {
            "-- [DROP COLUMN — VERIFICAR] $tableName.$colName`n-- Esta columna existe en BD pero no en el modelo. Verificar impacto antes de ejecutar.`n-- ALTER TABLE $(Tref $tableName) DROP COLUMN $(Cref $colName);"
        } else {
            "-- [DROP COLUMN — VERIFICAR] $tableName.$colName`n-- Esta columna existe en BD pero no en el modelo. Verificar impacto antes de ejecutar.`n-- ALTER TABLE $(Tref $tableName) DROP COLUMN $(Cref $colName);"
        }
        $scripts += [PSCustomObject]@{ operation = "DROP_COLUMN_CANDIDATE"; table = $tableName; column = $colName; sql = $comment }
    }
}

@{
    success        = $true
    drift_detected = $true
    motor          = $motor
    schema         = $schema
    script_count   = $scripts.Count
    sql_scripts    = $scripts
    warning        = "Revisar y validar scripts antes de ejecutar en produccion"
} | ConvertTo-Json -Depth 5
