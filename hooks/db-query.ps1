<#
.SYNOPSIS
    Ejecuta una consulta SQL contra la BD del workspace y devuelve resultados como JSON.

.PARAMETER Workspace
    Ruta raíz del proyecto (trunk).

.PARAMETER Sql
    Sentencia SQL SELECT a ejecutar.

.PARAMETER MaxRows
    Máximo de filas a devolver (defecto 200).

.PARAMETER Conexion
    Id de conexión de docs\.rs-databases.json. Si se omite, la principal (conexiones[0]).
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Sql,
    [int]$MaxRows = 200,
    [string]$Conexion = ""
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "lib-dbconfig.ps1")

# --- Guarda SELECT-only (misma validación que la tool MCP db_query, rs-workspace-server.py) ---
# Este hook es el fallback 1:1 de esa tool; sin esta guarda ejecutaría cualquier sentencia
# (DROP/DELETE/bloque PL/SQL) interpolada directamente en el script sqlplus.
$sqlTrim = $Sql.Trim()
if (-not $sqlTrim.ToUpper().StartsWith("SELECT")) {
    @{ success = $false; error = "Solo se permiten consultas SELECT" } | ConvertTo-Json
    exit 1
}
# Bloquea multi-statement ("SELECT 1; DROP TABLE x"): quita el ; final habitual y cuenta los ;
# que queden fuera de literales de string.
$sqlNorm = $sqlTrim.TrimEnd(';')
$inStr = $false
$semiCount = 0
foreach ($ch in $sqlNorm.ToCharArray()) {
    if ($ch -eq "'") { $inStr = -not $inStr }
    elseif ($ch -eq ';' -and -not $inStr) { $semiCount++ }
}
if ($semiCount -gt 0) {
    @{ success = $false; error = "Multi-statement SQL no permitido" } | ConvertTo-Json
    exit 1
}

$Workspace = Resolve-RsWorkspace $Workspace

# --- Leer docs\.rs-databases.json ---
$cfg = Read-RsDatabases $Workspace
if (-not $cfg.ok) {
    @{ success = $false; error = $cfg.error } | ConvertTo-Json
    exit 1
}

if ($Conexion) {
    $c = $cfg.conexiones | Where-Object { "$($_.id)" -eq $Conexion } | Select-Object -First 1
    if (-not $c) {
        $validas = ($cfg.conexiones | ForEach-Object { "$($_.id)" }) -join ", "
        @{ success = $false; error = "Conexión '$Conexion' no existe. Válidas: $validas" } | ConvertTo-Json
        exit 1
    }
} else {
    $c = $cfg.conexiones[0]
}

$motor      = "$($c.motor)".ToUpper()
$cadena     = "$($c.cadena)"
$dataSource = Get-CsPart -Cadena $cadena -Clave "Data Source"
if (-not $dataSource) { $dataSource = Get-CsPart -Cadena $cadena -Clave "Server" }
$user       = Get-CsPart -Cadena $cadena -Clave "User Id"
$password   = Get-CsPart -Cadena $cadena -Clave "Password"

# --- Ejecutar SQL ---
# Rutas temp propias (no GetTempFileName() + ".sql": eso crea un fichero de 0 bytes en OTRA ruta
# que quedaba huérfano — el finally solo limpiaba las rutas con sufijo). [Guid] existe en PS5.1.
$tmpDir  = [System.IO.Path]::GetTempPath()
$tempSql = Join-Path $tmpDir ("rsdbq-" + [Guid]::NewGuid().ToString("N") + ".sql")
$tempOut = Join-Path $tmpDir ("rsdbq-" + [Guid]::NewGuid().ToString("N") + ".txt")

try {
    if ($motor -eq "ORACLE") {
        # Credenciales en el script SQL (CONNECT), no en la línea de comando: con sqlplus -S
        # "user/pass@ds" la password queda visible en la lista de procesos toda la ejecución.
        # Mismo patrón que la tool MCP db_query (rs-workspace-server.py): /nolog + CONNECT.
        # WHENEVER SQLERROR va ANTES del CONNECT para que un login fallido salga con el SQLCODE.
        if ($password) {
            $connectLine = "CONNECT $user/$password@$dataSource`n"
            $sqlplusConn = "/nolog"
        } else {
            $connectLine = ""
            $sqlplusConn = "$user/@$dataSource"
        }
        # MARKUP CSV (sqlplus 12.2+) en vez de COLSEP: las cabeceras salen con el nombre completo
        # de la columna. Con salida tabular sqlplus las trunca al ancho del campo, así que un
        # SELECT 'a' AS C1 devolvía la cabecera "C". Además QUOTE ON escapa los valores que
        # contienen el separador, que partidos a mano corrompían las filas en silencio.
        @"
SET MARKUP CSV ON DELIMITER , QUOTE ON
SET PAGESIZE 0
SET FEEDBACK OFF
SET LINESIZE 32767
SET TRIMSPOOL ON
WHENEVER SQLERROR EXIT SQL.SQLCODE
$connectLine$sqlNorm;
EXIT;
"@ | ForEach-Object { [System.IO.File]::WriteAllText($tempSql, $_, (New-Object System.Text.UTF8Encoding($false))) }

        # UTF8 sin BOM a propósito: Set-Content -Encoding UTF8 (PS 5.1) antepone el BOM, sqlplus lo
        # lee como parte del primer comando y el primer SET falla con SP2-0734.
        sqlplus -S "$sqlplusConn" "@$tempSql" > $tempOut 2>&1
        $exitCode = $LASTEXITCODE
        # @() en todas las colecciones: con una sola línea/columna PowerShell colapsa a escalar y
        # $lines[0] / $headers[$i] devuelven un [char], que ConvertTo-Json rechaza como clave.
        $raw = @(Get-Content $tempOut -Encoding UTF8 -ErrorAction SilentlyContinue)

        if ($exitCode -ne 0) {
            $errMsg = ($raw | Where-Object { $_ -match 'ORA-|SP2-|ERROR' }) -join "; "
            if (-not $errMsg) { $errMsg = $raw -join " " }
            @{ success = $false; error = $errMsg.Trim(); sql = $Sql } | ConvertTo-Json
            exit 0
        }

        # Primera línea = cabeceras CSV, resto = datos. Sin filas, sqlplus no emite ni la cabecera.
        $lines = @($raw | Where-Object { $_.Trim() -ne "" })
        if ($lines.Count -le 1) {
            @{ success = $true; rows = @(); row_count = 0; truncated = $false; sql = $Sql } | ConvertTo-Json
            exit 0
        }

        $todas = @($lines | ConvertFrom-Csv)
        $rows  = @($todas | Select-Object -First $MaxRows)

        @{
            success   = $true
            row_count = $rows.Count
            truncated = $todas.Count -gt $MaxRows
            sql       = $Sql
            rows      = @($rows)
        } | ConvertTo-Json -Depth 4
    } else {
        @{ success = $false; error = "Motor '$motor' no soportado por este hook. Usar sqlcmd manualmente." } | ConvertTo-Json
    }
} finally {
    Remove-Item $tempSql, $tempOut -Force -ErrorAction SilentlyContinue
}
