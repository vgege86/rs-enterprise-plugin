<#
.SYNOPSIS
    Actualiza tablas específicas en model.json desde el esquema real de BD.
    Usar después de aplicar scripts de migración para cerrar el loop drift → migración → model sync.
    Preserva description y relations/indexes existentes de las tablas tocadas.

.PARAMETER Workspace
    Ruta raíz del proyecto.

.PARAMETER Tables
    Nombres de tablas a sincronizar, separados por coma.

.EXAMPLE
    .\sync-model-tables.ps1 "C:\...\trunk" "RNUEVATABLA,RCLIENTES"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Tables
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
$hooksDir = Split-Path $PSCommandPath -Parent
. (Join-Path $hooksDir "lib-dbconfig.ps1")

# Config BD
$configJson = & "$hooksDir\get-config.ps1" $Workspace | ConvertFrom-Json
if ($configJson.error) {
    @{ success = $false; error = $configJson.error } | ConvertTo-Json; exit 1
}

$motor     = $configJson.motor
$schema    = $configJson.schema
$user      = $configJson.user
$dataSource = $configJson.datasource
$modelPath = $configJson.model_path

# Password: no se expone vía get-config.ps1/get_db_config — leer directo de .rs-databases.json
$dbCfg = Read-RsDatabases (Resolve-RsWorkspace $Workspace)
if (-not $dbCfg.ok) {
    @{ success = $false; error = $dbCfg.error } | ConvertTo-Json; exit 1
}
$password = Get-CsPart -Cadena "$($dbCfg.conexiones[0].cadena)" -Clave "Password"

if (-not (Test-Path $modelPath)) {
    @{ success = $false; error = "Modelo BD no encontrado: $modelPath" } | ConvertTo-Json; exit 1
}

# Nota: la lista de tablas pedidas se guarda en $requestedTables (nunca reusar "$tables"/"$Tables" como
# nombre de variable para otra cosa — PowerShell no distingue mayúsculas/minúsculas en nombres de
# variable, así que colisionaría con el parámetro -Tables y forzaría todo a [string] silenciosamente).
$requestedTables = $Tables -split "," | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ -ne "" }

# model.tables y cada table.columns son objetos JSON con clave = nombre (PSCustomObject con
# NoteProperty dinámicas), no arrays — igual que en sync-from-db.ps1. Cargar y manipular con
# Add-Member -Force, nunca como ArrayList/array de {name:...}.
$model = Get-Content $modelPath -Raw -Encoding UTF8 | ConvertFrom-Json

$tempSql = [System.IO.Path]::GetTempFileName() + ".sql"
$tempOut = [System.IO.Path]::GetTempFileName() + ".csv"
$found   = @{}

if ($motor -eq "ORACLE") {
    $schemaFilter = if ($schema) { $schema.ToUpper() } else { $user.ToUpper() }
    $tableInList  = ($requestedTables | ForEach-Object { "'$_'" }) -join ","
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
WHERE t.OWNER = '$schemaFilter' AND t.TABLE_NAME IN ($tableInList)
ORDER BY t.TABLE_NAME, c.COLUMN_ID;
EXIT;
"@ | Set-Content $tempSql -Encoding ASCII

    sqlplus -S /nolog "@$tempSql" > $tempOut 2>&1
    $rows = Get-Content $tempOut | Where-Object { $_ -match '\|' }

    foreach ($row in $rows) {
        $parts = $row.Trim() -split '\|'
        if ($parts.Count -lt 5) { continue }
        $tableName = $parts[0].Trim()
        $colName   = $parts[1].Trim()
        $colType   = $parts[2].Trim()
        $nullable  = $parts[3].Trim() -eq 'Y'
        $isPk      = $parts[4].Trim() -eq 'Y'
        if (-not $tableName -or -not $colName) { continue }
        $found[$tableName] = $true

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

} elseif ($motor -eq "SQLSERVER") {
    $tableInList = ($requestedTables | ForEach-Object { "'$_'" }) -join ","
    @"
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
WHERE t.TABLE_TYPE = 'BASE TABLE' AND t.TABLE_NAME IN ($tableInList)
ORDER BY t.TABLE_NAME, c.ORDINAL_POSITION;
"@ | Set-Content $tempSql -Encoding ASCII

    sqlcmd -S $dataSource -d $schema -U $user -P $password -i $tempSql -s "|" -W -h -1 > $tempOut 2>&1
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
        $found[$tableName] = $true

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
    Remove-Item $tempSql, $tempOut -Force -ErrorAction SilentlyContinue
    @{ success = $false; error = "Motor no soportado: $motor" } | ConvertTo-Json; exit 1
}

Remove-Item $tempSql, $tempOut -Force -ErrorAction SilentlyContinue

$updated  = @($requestedTables | Where-Object { $found.ContainsKey($_) })
$notInDb  = @($requestedTables | Where-Object { -not $found.ContainsKey($_) })

# Guardar modelo actualizado (escritura atómica: tmp -> rename, igual que sync-from-db.ps1)
$model.updated_at = (Get-Date -Format "o")
$tmpPath = $modelPath + ".tmp"
$model | ConvertTo-Json -Depth 10 | Set-Content $tmpPath -Encoding UTF8
Move-Item $tmpPath $modelPath -Force

@{
    success    = $true
    model_path = $modelPath
    updated    = $updated
    not_in_db  = $notInDb
    message    = if ($updated.Count -gt 0) { "Modelo actualizado para: $($updated -join ', ')" } else { "Sin cambios -- tablas no encontradas en BD: $($notInDb -join ', ')" }
} | ConvertTo-Json -Depth 3
