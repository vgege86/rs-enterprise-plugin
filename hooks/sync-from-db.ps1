<#
.SYNOPSIS
    Sincroniza estructura de tablas y columnas desde la BD real al modelo JSON.
    No modifica relaciones (la BD no tiene FKs declaradas).

.PARAMETER Workspace
    Ruta raiz del proyecto (ej: C:\SVN\RS\<Proyecto>\trunk)

.PARAMETER Proyecto
    Nombre del proyecto AIS (ej: <Proyecto>)
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Proyecto
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

trap {
    @{ success = $false; error = $_.Exception.Message; step = "sync-from-db" } | ConvertTo-Json
    exit 1
}

# --- Leer configuracion BD desde docs\.rs-databases.json ---
$hooksDir = Split-Path $PSCommandPath -Parent
. (Join-Path $hooksDir "lib-dbconfig.ps1")

$Workspace = Resolve-RsWorkspace $Workspace

$cfg = Read-RsDatabases $Workspace
if (-not $cfg.ok) { throw $cfg.error }

$c      = $cfg.conexiones[0]
$motor  = "$($c.motor)".ToUpper()
$cadena = "$($c.cadena)"

$dataSource = Get-CsPart -Cadena $cadena -Clave "Data Source"
if (-not $dataSource) { $dataSource = Get-CsPart -Cadena $cadena -Clave "Server" }
$user     = Get-CsPart -Cadena $cadena -Clave "User Id"
$password = Get-CsPart -Cadena $cadena -Clave "Password"

if ($motor -eq "ORACLE") {
    $schema = if ($c.schema) { "$($c.schema)" } else { $user }
} else {
    $schema = if ($c.dataBase) { "$($c.dataBase)" } else { Get-CsPart -Cadena $cadena -Clave "Database" }
}
# NOTA migración: $database nunca se asignaba en el XML legacy (bug preexistente, variable
# leída-sin-asignar más abajo) — se fija aquí al mismo valor que $schema, que ya es la fuente
# de verdad para "nombre de BD/schema" tanto en Oracle como en SQL Server (ver get-config.ps1).
$database = $schema

# --- Ruta del modelo JSON ---
$bdDir    = Join-Path $Workspace "BD"
$modelPath = Join-Path $bdDir "$Proyecto-model.json"

if (-not (Test-Path $bdDir)) {
    New-Item -ItemType Directory -Force $bdDir | Out-Null
}

# Cargar modelo existente o crear nuevo
if (Test-Path $modelPath) {
    $model = Get-Content $modelPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # El owner real de las tablas puede no ser el usuario de conexión (ej. usuario de
    # solo-consulta cross-schema) — si el modelo ya existe, su "schema" es la fuente de verdad.
    if ($motor -eq "ORACLE" -and $schema -eq $user -and $model.schema) {
        $schema = $model.schema
    }
} else {
    $model = [PSCustomObject]@{
        version    = "1.0"
        project    = $Proyecto
        engine     = $motor
        datasource = $dataSource
        schema     = if ($motor -eq "ORACLE") { $schema } else { $database }
        updated_at = (Get-Date -Format "o")
        tables     = [PSCustomObject]@{}
    }
}

# --- Normalizar arrays de relations (fix PS 5.1: ConvertFrom-Json deserializa arrays de 1 elemento
#     como PSCustomObject en vez de array. Al serializar de vuelta con ConvertTo-Json se pierde la
#     estructura de array y las relaciones quedan corrompidas o desaparecen) ---
foreach ($tName in ($model.tables | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
    $t = $model.tables.$tName
    # Normalizar relations (PS 5.1: array de 1 elemento deserializa como PSCustomObject)
    $rels = $t.relations
    if ($null -eq $rels) {
        $t | Add-Member -Force -NotePropertyName 'relations' -NotePropertyValue @()
    } elseif ($rels -isnot [System.Array]) {
        $t | Add-Member -Force -NotePropertyName 'relations' -NotePropertyValue @($rels)
    }
    # Normalizar indexes — mismo problema + inicializar si tabla antigua no lo tenía
    $idxs = $t.indexes
    if ($null -eq $idxs) {
        $t | Add-Member -Force -NotePropertyName 'indexes' -NotePropertyValue @()
    } elseif ($idxs -isnot [System.Array]) {
        $t | Add-Member -Force -NotePropertyName 'indexes' -NotePropertyValue @($idxs)
    }
}

# --- Extraer esquema segun motor ---
$tempSql = [System.IO.Path]::GetTempFileName() + ".sql"
$tempOut = [System.IO.Path]::GetTempFileName() + ".csv"

if ($motor -eq "ORACLE") {
    $schemaFilter = if ($schema) { $schema.ToUpper() } else { $user.ToUpper() }
    @"
SET HEADING OFF
SET PAGESIZE 0
SET FEEDBACK OFF
SET LINESIZE 500
SET COLSEP '|'
CONNECT $user/$password@$dataSource
SELECT t.TABLE_NAME,
       c.COLUMN_NAME,
       c.DATA_TYPE || CASE
           WHEN c.DATA_TYPE IN ('VARCHAR2','NVARCHAR2','CHAR') THEN '(' || c.CHAR_LENGTH || ')'
           WHEN c.DATA_TYPE = 'NUMBER' AND c.DATA_PRECISION IS NOT NULL THEN '(' || c.DATA_PRECISION || CASE WHEN c.DATA_SCALE > 0 THEN ',' || c.DATA_SCALE ELSE '' END || ')'
           ELSE ''
       END AS FULL_TYPE,
       c.NULLABLE,
       CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 'Y' ELSE 'N' END AS IS_PK
FROM ALL_TABLES t
JOIN ALL_TAB_COLUMNS c ON c.OWNER = t.OWNER AND c.TABLE_NAME = t.TABLE_NAME
LEFT JOIN (
    SELECT cc.TABLE_NAME, cc.COLUMN_NAME
    FROM ALL_CONSTRAINTS con
    JOIN ALL_CONS_COLUMNS cc ON cc.CONSTRAINT_NAME = con.CONSTRAINT_NAME AND cc.OWNER = con.OWNER
    WHERE con.CONSTRAINT_TYPE = 'P' AND con.OWNER = '$schemaFilter'
) pk ON pk.TABLE_NAME = c.TABLE_NAME AND pk.COLUMN_NAME = c.COLUMN_NAME
WHERE t.OWNER = '$schemaFilter'
ORDER BY t.TABLE_NAME, c.COLUMN_ID;
EXIT;
"@ | Set-Content $tempSql -Encoding ASCII

    sqlplus -S /nolog "@$tempSql" > $tempOut 2>&1
    $rows = Get-Content $tempOut | Where-Object { $_ -match '\|' }

    foreach ($row in $rows) {
        $parts = $row.Trim() -split '\|'
        if ($parts.Count -lt 5) { continue }
        $tableName  = $parts[0].Trim()
        $colName    = $parts[1].Trim()
        $colType    = $parts[2].Trim()
        $nullable   = $parts[3].Trim() -eq 'Y'
        $isPk       = $parts[4].Trim() -eq 'Y'

        if (-not $tableName -or -not $colName) { continue }

        # Tabla
        if (-not ($model.tables | Get-Member -Name $tableName)) {
            $model.tables | Add-Member -NotePropertyName $tableName -NotePropertyValue ([PSCustomObject]@{
                description = ""
                source      = "db"
                columns     = [PSCustomObject]@{}
                relations   = @()
                indexes     = @()
            })
        }

        # Columna (preservar description si ya existe)
        $existingDesc = ""
        if ($model.tables.$tableName.columns | Get-Member -Name $colName) {
            $existingDesc = $model.tables.$tableName.columns.$colName.description
        }
        $model.tables.$tableName.columns | Add-Member -Force -NotePropertyName $colName -NotePropertyValue ([PSCustomObject]@{
            type        = $colType
            nullable    = $nullable
            pk          = $isPk
            description = $existingDesc
            source      = "db"
        })
    }

} elseif ($motor -eq "SQLSERVER") {
    $query = @"
SET NOCOUNT ON;
SELECT
    t.TABLE_NAME,
    c.COLUMN_NAME,
    c.DATA_TYPE + CASE
        WHEN c.DATA_TYPE IN ('varchar','nvarchar','char','nchar') AND c.CHARACTER_MAXIMUM_LENGTH IS NOT NULL
            THEN '(' + CAST(c.CHARACTER_MAXIMUM_LENGTH AS VARCHAR) + ')'
        WHEN c.DATA_TYPE IN ('decimal','numeric') AND c.NUMERIC_PRECISION IS NOT NULL
            THEN '(' + CAST(c.NUMERIC_PRECISION AS VARCHAR) + ',' + CAST(c.NUMERIC_SCALE AS VARCHAR) + ')'
        ELSE ''
    END AS FULL_TYPE,
    c.IS_NULLABLE,
    CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 'YES' ELSE 'NO' END AS IS_PK
FROM INFORMATION_SCHEMA.TABLES t
JOIN INFORMATION_SCHEMA.COLUMNS c ON c.TABLE_NAME = t.TABLE_NAME AND c.TABLE_SCHEMA = t.TABLE_SCHEMA
LEFT JOIN (
    SELECT ku.TABLE_NAME, ku.COLUMN_NAME
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE ku ON ku.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
    WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
) pk ON pk.TABLE_NAME = c.TABLE_NAME AND pk.COLUMN_NAME = c.COLUMN_NAME
WHERE t.TABLE_TYPE = 'BASE TABLE'
ORDER BY t.TABLE_NAME, c.ORDINAL_POSITION;
"@

    $query | Set-Content $tempSql -Encoding ASCII
    sqlcmd -S $dataSource -d $database -U $user -P $password -i $tempSql -s "|" -W -h -1 > $tempOut 2>&1
    $rows = Get-Content $tempOut | Where-Object { $_ -match '\|' }

    foreach ($row in $rows) {
        $parts = $row.Trim() -split '\|'
        if ($parts.Count -lt 5) { continue }
        $tableName = $parts[0].Trim()
        $colName   = $parts[1].Trim()
        $colType   = $parts[2].Trim()
        $nullable  = $parts[3].Trim() -eq 'YES'
        $isPk      = $parts[4].Trim() -eq 'YES'

        if (-not $tableName -or -not $colName) { continue }

        if (-not ($model.tables | Get-Member -Name $tableName)) {
            $model.tables | Add-Member -NotePropertyName $tableName -NotePropertyValue ([PSCustomObject]@{
                description = ""
                source      = "db"
                columns     = [PSCustomObject]@{}
                relations   = @()
                indexes     = @()
            })
        }

        $existingDesc = ""
        if ($model.tables.$tableName.columns | Get-Member -Name $colName) {
            $existingDesc = $model.tables.$tableName.columns.$colName.description
        }
        $model.tables.$tableName.columns | Add-Member -Force -NotePropertyName $colName -NotePropertyValue ([PSCustomObject]@{
            type        = $colType
            nullable    = $nullable
            pk          = $isPk
            description = $existingDesc
            source      = "db"
        })
    }
} else {
    throw "Motor no soportado: $motor (esperado: ORACLE o SQLSERVER)"
}

# --- Guardar JSON actualizado (escritura atómica: tmp → rename) ---
$model.updated_at = (Get-Date -Format "o")
$tmpPath = $modelPath + ".tmp"
$model | ConvertTo-Json -Depth 10 | Set-Content $tmpPath -Encoding UTF8
Move-Item $tmpPath $modelPath -Force

# Cleanup
Remove-Item $tempSql, $tempOut -Force -ErrorAction SilentlyContinue

$tableCount = ($model.tables | Get-Member -MemberType NoteProperty).Count
@{
    success     = $true
    motor       = $motor
    schema      = if ($motor -eq "ORACLE") { $schema } else { $database }
    table_count = $tableCount
    model_path  = $modelPath
    updated_at  = $model.updated_at
} | ConvertTo-Json
