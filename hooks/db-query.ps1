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

# --- Guarda solo-lectura (misma validación que la tool MCP db_query, rs-workspace-server.py) ---
# Este hook es el fallback 1:1 de esa tool; sin esta guarda ejecutaría cualquier sentencia
# (DROP/DELETE/bloque PL/SQL) interpolada directamente en el script sqlplus.
$sqlTrim  = $Sql.Trim()
$sqlUpper = $sqlTrim.ToUpper()
if (-not ($sqlUpper.StartsWith("SELECT") -or $sqlUpper.StartsWith("WITH"))) {
    @{ success = $false; error = "Solo se permiten consultas SELECT o CTE (WITH ... SELECT)" } | ConvertTo-Json
    exit 1
}
# Un CTE puede colgar un verbo de escritura tras el bloque ("WITH x AS (...) DELETE FROM ...");
# StartsWith("WITH") no lo pilla. Bloquear si aparece cualquier verbo de escritura.
if ($sqlUpper.StartsWith("WITH") -and $sqlUpper -match '\b(INSERT|UPDATE|DELETE|MERGE)\b') {
    @{ success = $false; error = "CTE con verbo de escritura no permitido" } | ConvertTo-Json
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

# Eco de SQL saneado: UNA sola vez, para toda salida que incluya "sql" (error de sqlplus,
# sin filas, o resultado con filas). Un literal con dato personal (ej. WHERE DNI =
# '12345678Z') no debe quedar persistido en NINGUNA respuesta, y una consulta que no
# encuentra filas es justo la forma de una busqueda dirigida a una persona concreta.
$sqlEcho = ($Sql -replace "'[^']*'", "'?'")

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
            # Sin columns/pii a proposito: una consulta que nunca llego a ejecutarse no tiene
            # nada que enmascarar. Solo se sanea el eco de SQL, igual que en el resto de salidas.
            $errMsg = ($raw | Where-Object { $_ -match 'ORA-|SP2-|ERROR' }) -join "; "
            if (-not $errMsg) { $errMsg = $raw -join " " }
            @{ success = $false; error = $errMsg.Trim(); sql = $sqlEcho } | ConvertTo-Json
            exit 0
        }

        # Primera línea = cabeceras CSV, resto = datos. Sin filas, sqlplus no emite ni la cabecera.
        $lines = @($raw | Where-Object { $_.Trim() -ne "" })
        if ($lines.Count -le 1) {
            # Sin filas no hay nada que enmascarar (no se llama a pii_cli para un resultset
            # vacio), pero la forma de la respuesta se mantiene igual que la del camino con
            # filas: columns/rows/pii siempre presentes, para que el consumidor no tenga que
            # distinguir "vacio" de "con datos" por la forma del JSON.
            # Cabeceras vía ConvertFrom-Csv, NUNCA partiendo la linea por comas a mano: un
            # alias de columna entre comillas con una coma dentro se corromperia en silencio.
            # Truco: la propia linea de cabecera sirve de "fila" tambien, asi el objeto que
            # produce ConvertFrom-Csv trae los nombres reales en sus propiedades; el valor de
            # cada propiedad se descarta (es igual al nombre) y solo se usan las Properties.Name.
            $cabeceras = @()
            if ($lines.Count -eq 1 -and $lines[0]) {
                $filaCabecera = @($lines[0], $lines[0]) | ConvertFrom-Csv
                $cabeceras = @($filaCabecera[0].PSObject.Properties.Name)
            }
            @{
                success   = $true
                row_count = 0
                truncated = $false
                sql       = $sqlEcho
                columns   = $cabeceras
                rows      = @()
                pii       = @{ mode = "off"; reason = "sin filas" }
            } | ConvertTo-Json -Depth 4
            exit 0
        }

        $todas = @($lines | ConvertFrom-Csv)
        $rows  = @($todas | Select-Object -First $MaxRows)

        # --- Enmascarado PII ---
        # Se delega en scripts/pii_cli.py y NO se reimplementa aqui: la guarda read-only ya
        # esta duplicada entre este hook y la tool MCP, y una divergencia en la politica PII
        # seria una fuga silenciosa en vez de un error visible.
        # Fallo ABIERTO a proposito: si el enmascarado revienta se devuelven los datos sin
        # tocar. Este hook es el camino fallback; la proteccion efectiva es la tool MCP, y
        # dejar sin servicio la consulta ante un fallo del filtro empujaria al usuario a
        # sqlplus directo, que es peor. El aviso pii.error lo deja constar.
        # Cabeceras desde los objetos de ConvertFrom-Csv, NO partiendo $lines[0] por comas:
        # los valores con coma van entrecomillados (SET MARKUP CSV ... QUOTE ON) y un split
        # a mano los partiria en silencio, que es el bug que ConvertFrom-Csv evita.
        $cabeceras = @($todas[0].PSObject.Properties.Name)
        $matriz    = @()
        foreach ($fila in $rows) {
            $matriz += , @($cabeceras | ForEach-Object { "$($fila.$_)" })
        }

        $piiMeta = @{ mode = "error" }
        # Join-Path de DOS argumentos: con tres es PS 6+ y este hook corre en 5.1.
        $cli     = Join-Path $PSScriptRoot "..\scripts\pii_cli.py"
        try {
            $entrada = @{ columns = $cabeceras; rows = $matriz; sql = $sqlNorm } |
                       ConvertTo-Json -Depth 6 -Compress
            $res = $entrada | python $cli $Workspace 2>$null
            if ($LASTEXITCODE -eq 0 -and $res) {
                $obj       = $res | ConvertFrom-Json
                $cabeceras = @($obj.columns)
                $matriz    = @($obj.rows)
                $piiMeta   = $obj.pii
            } else {
                $piiMeta = @{ mode = "error"; error = "pii_cli fallo (exit $LASTEXITCODE) - datos SIN enmascarar" }
            }
        } catch {
            $piiMeta = @{ mode = "error"; error = "pii_cli no ejecutable - datos SIN enmascarar" }
        }

        @{
            success   = $true
            row_count = $matriz.Count
            truncated = $todas.Count -gt $MaxRows
            sql       = $sqlEcho   # ya saneado arriba, una sola vez para todas las salidas
            columns   = @($cabeceras)
            rows      = @($matriz)
            pii       = $piiMeta
        } | ConvertTo-Json -Depth 6
    } else {
        @{ success = $false; error = "Motor '$motor' no soportado por este hook. Usar sqlcmd manualmente." } | ConvertTo-Json
    }
} finally {
    Remove-Item $tempSql, $tempOut -Force -ErrorAction SilentlyContinue
}
