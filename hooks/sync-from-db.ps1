<#
.SYNOPSIS
    Sincroniza estructura de tablas y columnas desde la BD real al modelo JSON.
    No modifica relaciones (la BD no tiene FKs declaradas).

.PARAMETER Workspace
    Ruta raiz del proyecto (ej: C:\SVN\RS\<Proyecto>\trunk)

.PARAMETER Proyecto
    Nombre del proyecto AIS (ej: <Proyecto>)

.PARAMETER Conexion
    Id de conexion de docs\.rs-databases.json. Si se omite, la principal (conexiones[0]).
    Sirve para leer con una cuenta distinta a la de consulta (p.ej. la duena del esquema, que
    es la unica que ve TODO) sin tener que editar a mano el fichero de credenciales.
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Proyecto,
    [string]$Conexion = ""
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
. (Join-Path $hooksDir "lib-dbmodel.ps1")
. (Join-Path $hooksDir "lib-dbvisibilidad.ps1")
. (Join-Path $hooksDir "lib-modeljson.ps1")

$Workspace = Resolve-RsWorkspace $Workspace

$cfg = Read-RsDatabases $Workspace
if (-not $cfg.ok) { throw $cfg.error }

$c = Select-RsConexion -Config $cfg -Id $Conexion
if (-not $c) {
    $validas = ($cfg.conexiones | ForEach-Object { "$($_.id)" }) -join ", "
    throw "Conexion '$Conexion' no existe en .rs-databases.json. Validas: $validas"
}
$motor  = "$($c.motor)".ToUpper()
$cadena = "$($c.cadena)"

$dataSource = Get-CsPart -Cadena $cadena -Clave "Data Source"
if (-not $dataSource) { $dataSource = Get-CsPart -Cadena $cadena -Clave "Server" }
$user     = Get-CsPart -Cadena $cadena -Clave "User Id"
$password = Unprotect-RsSecret (Get-CsPart -Cadena $cadena -Clave "Password")

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
# Indice O(1) de tablas/columnas existentes: sin el, el loop de sync haria un `Get-Member -Name`
# por fila (tablas x columnas) sobre un PSCustomObject que crece → O(n²). Se construye en la misma
# pasada que la normalizacion de relations/indexes. $tblIdx[$tabla] = @{ obj = <PSCustomObject tabla>;
# cols = @{ <col>: <PSCustomObject col> } }.
$tblIdx = @{}
# Tablas que ESTA lectura ha visto. Lo que no esté aquí al terminar no se borra ni se degrada:
# con una cuenta que solo ve por GRANT, "no ha salido en la consulta" no significa "ya no
# existe". Ver hooks\lib-dbvisibilidad.ps1.
$vistas = @{}
foreach ($tp in $model.tables.PSObject.Properties) {
    $tName = $tp.Name
    $t     = $tp.Value
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
    # Index de columnas existentes de esta tabla (para preservar description en O(1))
    $colSet = @{}
    if ($t.columns) {
        foreach ($cp in $t.columns.PSObject.Properties) { $colSet[$cp.Name] = $cp.Value }
    }
    $tblIdx[$tName] = @{ obj = $t; cols = $colSet }
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
       NVL(pk.POSITION, 0) AS PK_POS
FROM ALL_TABLES t
JOIN ALL_TAB_COLUMNS c ON c.OWNER = t.OWNER AND c.TABLE_NAME = t.TABLE_NAME
LEFT JOIN (
    -- POSITION = orden de la columna DENTRO de la clave primaria. No es lo mismo que
    -- COLUMN_ID (orden en la tabla) y es el que manda: es el del indice que respalda la PK.
    SELECT cc.TABLE_NAME, cc.COLUMN_NAME, cc.POSITION
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
        $pkPos      = ConvertTo-RsPkPosicion $parts[4]

        if (-not $tableName -or -not $colName) { continue }
        $vistas[$tableName] = $true

        # Tabla (lookup O(1) via indice)
        $entry = $tblIdx[$tableName]
        if (-not $entry) {
            $newTbl = [PSCustomObject]@{
                description = ""
                source      = "db"
                columns     = [PSCustomObject]@{}
                relations   = @()
                indexes     = @()
            }
            $model.tables | Add-Member -NotePropertyName $tableName -NotePropertyValue $newTbl
            $entry = @{ obj = $newTbl; cols = @{} }
            $tblIdx[$tableName] = $entry
        }

        # Columna. Lo que la BD no conoce (description, marcas pii/safe) lo conserva
        # New-RsColumnaModelo — ver hooks\lib-dbmodel.ps1. El lookup del anterior es O(1).
        $newCol = New-RsColumnaModelo -Tipo $colType -Nullable $nullable -PkPosicion $pkPos `
                                      -Existente $entry.cols[$colName]
        $entry.obj.columns | Add-Member -Force -NotePropertyName $colName -NotePropertyValue $newCol
        $entry.cols[$colName] = $newCol
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
    ISNULL(pk.ORDINAL_POSITION, 0) AS PK_POS
FROM INFORMATION_SCHEMA.TABLES t
JOIN INFORMATION_SCHEMA.COLUMNS c ON c.TABLE_NAME = t.TABLE_NAME AND c.TABLE_SCHEMA = t.TABLE_SCHEMA
LEFT JOIN (
    -- ORDINAL_POSITION de KEY_COLUMN_USAGE = orden de la columna DENTRO de la constraint,
    -- no dentro de la tabla. El schema entra en los dos JOIN: sin el, dos tablas homonimas
    -- en schemas distintos se cruzaban entre si y duplicaban filas.
    SELECT ku.TABLE_SCHEMA, ku.TABLE_NAME, ku.COLUMN_NAME, ku.ORDINAL_POSITION
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE ku
      ON ku.CONSTRAINT_NAME = tc.CONSTRAINT_NAME AND ku.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
    WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
) pk ON pk.TABLE_NAME = c.TABLE_NAME AND pk.COLUMN_NAME = c.COLUMN_NAME
    AND pk.TABLE_SCHEMA = c.TABLE_SCHEMA
WHERE t.TABLE_TYPE = 'BASE TABLE'
ORDER BY t.TABLE_NAME, c.ORDINAL_POSITION;
"@

    $query | Set-Content $tempSql -Encoding ASCII
    # Password por variable de entorno SQLCMDPASSWORD, no en argv: -P queda visible en la lista de
    # procesos durante toda la ejecución. Mismo patrón que la tool MCP db_query (rs-workspace-server.py).
    $env:SQLCMDPASSWORD = $password
    try {
        sqlcmd -S $dataSource -d $database -U $user -i $tempSql -s "|" -W -h -1 > $tempOut 2>&1
    } finally {
        Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
    }
    $rows = Get-Content $tempOut | Where-Object { $_ -match '\|' }

    foreach ($row in $rows) {
        $parts = $row.Trim() -split '\|'
        if ($parts.Count -lt 5) { continue }
        $tableName = $parts[0].Trim()
        $colName   = $parts[1].Trim()
        $colType   = $parts[2].Trim()
        $nullable  = $parts[3].Trim() -eq 'YES'
        $pkPos     = ConvertTo-RsPkPosicion $parts[4]

        if (-not $tableName -or -not $colName) { continue }
        $vistas[$tableName] = $true

        # Tabla (lookup O(1) via indice)
        $entry = $tblIdx[$tableName]
        if (-not $entry) {
            $newTbl = [PSCustomObject]@{
                description = ""
                source      = "db"
                columns     = [PSCustomObject]@{}
                relations   = @()
                indexes     = @()
            }
            $model.tables | Add-Member -NotePropertyName $tableName -NotePropertyValue $newTbl
            $entry = @{ obj = $newTbl; cols = @{} }
            $tblIdx[$tableName] = $entry
        }

        # Columna. Lo que la BD no conoce (description, marcas pii/safe) lo conserva
        # New-RsColumnaModelo — ver hooks\lib-dbmodel.ps1. El lookup del anterior es O(1).
        $newCol = New-RsColumnaModelo -Tipo $colType -Nullable $nullable -PkPosicion $pkPos `
                                      -Existente $entry.cols[$colName]
        $entry.obj.columns | Add-Member -Force -NotePropertyName $colName -NotePropertyValue $newCol
        $entry.cols[$colName] = $newCol
    }
} else {
    throw "Motor no soportado: $motor (esperado: ORACLE o SQLSERVER)"
}

# --- Valores DEFAULT de columna (pasada aparte) ---
# En Oracle DATA_DEFAULT es LONG y no se puede concatenar ni limpiar dentro del SELECT
# principal (ver hooks/lib-dbmodel.ps1). Sin este campo en el modelo,
# scripts/installer-ddl.py no puede emitirlo y el <Proyecto>-CreacionTablas.sql del
# instalador sale sin valores por defecto: en el cliente, toda columna con DEFAULT queda a
# NULL en el primer INSERT que no la nombre.
# ⛔ No es fatal: un fallo aqui deja el modelo sin defaults, no lo corrompe. Se avisa y se sigue.
$defaultsCount = 0
$defaultsAviso = ""
$defRes = Get-RsColumnDefaults -Motor $motor -Esquema $(if ($motor -eq "ORACLE") { $schema } else { $database }) `
                               -DataSource $dataSource -Usuario $user -Password $password
if ($defRes.ok) {
    foreach ($clave in @($defRes.defaults.Keys)) {
        $partes = $clave -split '\.', 2
        if ($partes.Count -lt 2) { continue }
        $entry = $tblIdx[$partes[0]]
        if (-not $entry) { continue }
        $col = $entry.cols[$partes[1]]
        if (-not $col) { continue }
        $col | Add-Member -Force -NotePropertyName 'default' -NotePropertyValue $defRes.defaults[$clave]
        $defaultsCount++
    }
} else {
    $defaultsAviso = "no se pudieron leer los valores DEFAULT: $($defRes.error)"
}

# --- Tablas que NO han salido en esta lectura ---
# ⛔ No se borran. Con una cuenta que solo ve por GRANT, una tabla sin conceder es
# indistinguible de una borrada, y de las dos lecturas posibles solo una destruye informacion.
# Se conservan enteras —columnas, relaciones e indices intactos— y se marcan como no visibles.
$ahora     = (Get-Date -Format "o")
$noVisibles = @()
foreach ($tName in @($tblIdx.Keys)) {
    $vista = $vistas.ContainsKey($tName)
    Set-RsTablaVisible -Tabla $tblIdx[$tName].obj -Vista $vista -Fecha $ahora
    if (-not $vista) { $noVisibles += $tName }
}

# --- Cobertura: cuantas tablas dice el diccionario que hay, frente a las que se capturaron ---
$cobertura = $null
$vis = Get-RsVisibilidad -Motor $motor -Esquema $(if ($motor -eq "ORACLE") { $schema } else { $database }) `
                         -DataSource $dataSource -Usuario $user -Password $password
if ($vis.soportado) {
    $cobertura = New-RsCobertura -Visibilidad $vis -Capturado @{ tablas = $vistas.Count }
    $cobertura.conexion = "$($c.id)"
    Merge-RsCobertura -Model $model -Cobertura $cobertura -Origen "sync-from-db" | Out-Null
    Format-RsCobertura -Cobertura $cobertura | ForEach-Object { Write-Host $_ }
} elseif ($vis.error) {
    Write-Host "AVISO: sin diagnostico de cobertura ($($vis.error))"
}
if ($noVisibles.Count -gt 0) {
    Write-Host "   $($noVisibles.Count) tabla(s) del modelo no visibles en esta lectura, CONSERVADAS: $(($noVisibles | Select-Object -First 10) -join ', ')$(if ($noVisibles.Count -gt 10) { ' ...' })"
}

# --- Guardar JSON actualizado (formato canonico, atomico y verificado) ---
$model.updated_at = $ahora
Save-RsModelJson -Model $model -Path $modelPath | Out-Null

# Cleanup
Remove-Item $tempSql, $tempOut -Force -ErrorAction SilentlyContinue

$tableCount = ($model.tables | Get-Member -MemberType NoteProperty).Count
# parcial = hay hueco entre el diccionario y lo capturado, o tablas del modelo que no se ven.
# El llamante debe tratarlo como "el modelo esta incompleto", NO como "estas tablas ya no estan".
$parcial = [bool](($cobertura -and $cobertura.parcial) -or $noVisibles.Count -gt 0)
@{
    success      = $true
    parcial      = $parcial
    conexion     = "$($c.id)"
    motor        = $motor
    schema       = if ($motor -eq "ORACLE") { $schema } else { $database }
    table_count  = $tableCount
    tablas_leidas = $vistas.Count
    no_visibles  = @($noVisibles)
    cobertura    = $cobertura
    defaults     = $defaultsCount
    warning      = $defaultsAviso
    model_path   = $modelPath
    updated_at   = $model.updated_at
} | ConvertTo-Json -Depth 6

if ($parcial) { exit 2 }
