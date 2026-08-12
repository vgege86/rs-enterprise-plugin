<#
.SYNOPSIS
    Sincroniza índices de la BD real (ALL_INDEXES) al modelo JSON.
    Reemplaza índices con source="db"; preserva source="manual".
    Output JSON: success, table_count, index_count, model_path.

.PARAMETER Workspace
    Ruta raíz del proyecto (trunk).

.PARAMETER Proyecto
    Nombre del proyecto. Inferido del workspace si se omite.

.PARAMETER Conexion
    Id de conexion de docs\.rs-databases.json. Si se omite, la principal (conexiones[0]).
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$Proyecto = "",
    [string]$Conexion = ""
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

trap {
    @{ success = $false; error = $_.Exception.Message; step = "sync-indexes" } | ConvertTo-Json
    exit 1
}

$hooksDir = Split-Path $PSCommandPath -Parent
. (Join-Path $hooksDir "lib-dbconfig.ps1")
. (Join-Path $hooksDir "lib-dbvisibilidad.ps1")
. (Join-Path $hooksDir "lib-modeljson.ps1")

$Workspace = Resolve-RsWorkspace $Workspace
if (-not $Proyecto) { $Proyecto = Split-Path (Split-Path $Workspace -Parent) -Leaf }

$cfg = Read-RsDatabases $Workspace
if (-not $cfg.ok) { throw $cfg.error }

$c = Select-RsConexion -Config $cfg -Id $Conexion
if (-not $c) {
    $validas = ($cfg.conexiones | ForEach-Object { "$($_.id)" }) -join ", "
    throw "Conexion '$Conexion' no existe en .rs-databases.json. Validas: $validas"
}
$motor  = "$($c.motor)".ToUpper()
$cadena = "$($c.cadena)"

$rawDs = Get-CsPart -Cadena $cadena -Clave "Data Source"
if (-not $rawDs) { $rawDs = Get-CsPart -Cadena $cadena -Clave "Server" }
$user     = Get-CsPart -Cadena $cadena -Clave "User Id"
$password = Unprotect-RsSecret (Get-CsPart -Cadena $cadena -Clave "Password")
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
#
# ⛔ SOLO se tocan las tablas que ESTA lectura ha visto. Antes se recorrian TODAS las del modelo
# y se les reescribia `indexes` con lo que hubiera en $dbIndexes — que para una tabla sin GRANT
# esta vacio. Resultado medido en una instalacion de cliente: seis tablas reales que la cuenta
# de consulta no veia se quedaron con 0 indices, y el modelo salio de la sincronizacion PEOR de
# como entro, en silencio. Una tabla que no se ve conserva sus indices tal cual y se marca.
$ahora        = (Get-Date -Format "o")
$totalIndexes = 0
$sinIndices   = @()
foreach ($tName in ($model.tables | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
    $t = $model.tables.$tName

    if (-not $dbIndexes.ContainsKey($tName)) {
        # No visible en esta lectura, o visible y sin ningun indice: en los dos casos la lectura
        # no aporta nada sobre esta tabla, asi que sus indices se quedan como estaban.
        $sinIndices += $tName
        continue
    }
    Set-RsTablaVisible -Tabla $t -Vista $true

    # Conservar índices manuales
    $manual = @()
    if ($t.indexes) {
        $manual = @($t.indexes | Where-Object { $_.source -eq "manual" })
    }

    # Construir nuevos índices desde BD
    $newIdxs = @()
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

    $merged = @($manual) + @($newIdxs)
    $t | Add-Member -Force -NotePropertyName 'indexes' -NotePropertyValue $merged
}

# --- Cobertura ---
# El diccionario cuenta INDICES; aqui se cuentan los capturados con source=db. Un hueco es o un
# GRANT que falta, o un tipo de indice que la consulta descarta a proposito (la WHERE filtra
# INDEX_TYPE='NORMAL' y STATUS='VALID': los funcionales, de dominio o inutilizables no se
# scriptan). Se declara como exclusion para que no se lea como perdida.
$cobertura = $null
$vis = Get-RsVisibilidad -Motor $motor -Esquema $schemaFilter -DataSource $rawDs `
                         -Usuario $user -Password $password
if ($vis.soportado) {
    $cobertura = New-RsCobertura -Visibilidad $vis -Capturado @{ indices = $totalIndexes } `
                                 -Excluido @{ indices = @{ n = 0; motivo = "solo INDEX_TYPE=NORMAL y STATUS=VALID" } }
    $cobertura.conexion = "$($c.id)"
    Merge-RsCobertura -Model $model -Cobertura $cobertura -Origen "sync-indexes" | Out-Null
    Format-RsCobertura -Cobertura $cobertura | ForEach-Object { Write-Host $_ }
} elseif ($vis.error) {
    Write-Host "AVISO: sin diagnostico de cobertura ($($vis.error))"
}
if ($sinIndices.Count -gt 0) {
    Write-Host "   $($sinIndices.Count) tabla(s) sin indices en esta lectura: se CONSERVAN los que ya tenian en el modelo."
}

# Guardar (formato canonico, atomico y verificado)
$model.updated_at = $ahora
Save-RsModelJson -Model $model -Path $modelPath | Out-Null

Remove-Item $tempSql, $tempOut -Force -ErrorAction SilentlyContinue

$tableCount = ($model.tables | Get-Member -MemberType NoteProperty).Count
$parcial = [bool]($cobertura -and $cobertura.parcial)
@{
    success          = $true
    parcial          = $parcial
    conexion         = "$($c.id)"
    motor            = $motor
    schema           = $schemaFilter
    table_count      = $tableCount
    index_count      = $totalIndexes
    tablas_con_indices = $dbIndexes.Count
    tablas_intactas  = @($sinIndices).Count
    cobertura        = $cobertura
    model_path       = $modelPath
    updated_at       = $model.updated_at
} | ConvertTo-Json -Depth 6

if ($parcial) { exit 2 }
