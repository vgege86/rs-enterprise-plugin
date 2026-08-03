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

# Lineas de diagnostico de sqlplus/sqlcmd, ANCLADAS al principio de linea. Misma forma
# que usa la tool MCP db_query (rs-workspace-server.py). El filtro anterior era
# 'ORA-|SP2-|ERROR' sin anclar, que casa con el CONTENIDO de los datos: una consulta que
# falla a mitad de volcado sobre cualquier tabla de incidencias o de log cuyas filas
# contengan la palabra "error" seleccionaba esas filas -- en claro, incluso en enforce --
# como si fueran el mensaje de error.
$RS_RX_DIAG = '^\s*(?:ORA-\d{3,6}\b|SP2-\d{3,6}\b|PLS-\d{3,6}\b|Sqlcmd:|Msg \d+\b)'
$RS_MAX_DIAG_LINEAS = 10
$RS_MAX_DIAG_CHARS  = 300

function Get-RsDiagnostico {
    <# Mensaje de error a partir de la salida capturada del cliente SQL.

       NUNCA devuelve la salida entera. sqlplus emite las filas CSV segun las va trayendo,
       asi que un error a mitad de fetch (ORA-01555, ORA-29275, un error de conversion por
       fila) deja filas de datos ya emitidas en lo capturado. Volcar eso como "error" mete
       en el contexto justo las filas que el enmascarado nunca llega a ver -- la rama de
       error no pasa por mask_resultset. Sin lineas de diagnostico reconocibles se devuelve
       un mensaje fijo con el codigo de salida, no el volcado. #>
    param([AllowEmptyCollection()][array]$Salida, [int]$ExitCode)
    $diag = @($Salida | Where-Object { $_ -match $RS_RX_DIAG } |
              Select-Object -First $RS_MAX_DIAG_LINEAS |
              ForEach-Object {
                  $t = "$_".Trim()
                  if ($t.Length -gt $RS_MAX_DIAG_CHARS) { $t.Substring(0, $RS_MAX_DIAG_CHARS) + "..." } else { $t }
              })
    if ($diag.Count -gt 0) { return ($diag -join "; ") }
    return "la consulta fallo (exit $ExitCode) sin lineas de diagnostico reconocibles; la salida capturada no se devuelve porque puede contener filas de datos"
}

function Invoke-RsPii {
    <# Aplica la politica PII delegando en scripts/pii_cli.py.

       Devuelve @{ ok; abierto; columns; rows; pii }.

       ok = $true          -> columns/rows enmascarados segun la politica.
       ok=$false, abierto  -> el CLI no se puede ni EJECUTAR (sin python, sin fichero). Es
                              el unico fallo ABIERTO, deliberado y documentado (#5.2 del
                              documento): este hook es el camino fallback, la proteccion
                              efectiva es la tool MCP, y dejar sin servicio la consulta
                              empujaria al usuario a sqlplus directo, que es peor.
       ok=$false, cerrado  -> el CLI CORRIO y fallo. Tenia las filas y no ha podido aplicar
                              la politica: el llamante NO debe devolver ninguna fila. Antes
                              esto caia en el mismo saco que el caso anterior, asi que un
                              modelo en forma inesperada devolvia todas las filas en claro
                              con pii.mode = "error". #>
    param(
        [AllowEmptyCollection()][array]$Cabeceras,
        [AllowEmptyCollection()][array]$Matriz,
        [string]$Sql,
        [string]$Workspace,
        [AllowEmptyString()][string]$ModelPath
    )
    # Join-Path de DOS argumentos: con tres es PS 6+ y este hook corre en 5.1.
    $cli = Join-Path $PSScriptRoot "..\scripts\pii_cli.py"
    if (-not (Test-Path $cli) -or -not (Get-Command python -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; abierto = $true; pii = @{
            mode  = "error"
            error = "pii_cli no ejecutable (falta python o scripts/pii_cli.py) - datos SIN enmascarar"
        } }
    }
    try {
        $entrada = @{ columns = @($Cabeceras); rows = @($Matriz); sql = $Sql } |
                   ConvertTo-Json -Depth 6 -Compress
        if ($ModelPath) {
            $res = $entrada | python $cli $Workspace $ModelPath 2>$null
        } else {
            $res = $entrada | python $cli $Workspace 2>$null
        }
        $code = $LASTEXITCODE
    } catch {
        return @{ ok = $false; abierto = $false; pii = @{
            mode  = "error"
            error = "fallo al invocar pii_cli - la politica PII no se pudo aplicar, no se devuelven filas"
        } }
    }
    if ($code -eq 0 -and $res) {
        $obj = $res | ConvertFrom-Json
        return @{ ok = $true; abierto = $false; columns = @($obj.columns); rows = @($obj.rows); pii = $obj.pii }
    }
    return @{ ok = $false; abierto = $false; pii = @{
        mode  = "error"
        error = "pii_cli fallo (exit $code) - la politica PII no se pudo aplicar, no se devuelven filas"
    } }
}

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

# Modelo BD de LA CONEXION SELECCIONADA (no el de la principal): lleva la politica PII
# entera. Misma resolucion que get-config.ps1 -> config["model_path"] de la tool MCP.
$modelPath = Get-RsModelPath -Workspace $Workspace -Conexion $c -Proyecto $cfg.proyecto
if (-not "$($c.model)" -and -not (Test-Path $modelPath)) {
    # Ni campo "model" declarado ni el fichero por convenio: workspace sin politica.
    # Caso ordinario (mode=off), igual que _cargar_modelo() de la tool MCP. Si en cambio
    # SI hay ruta declarada y el fichero no esta, se pasa igual y pii_cli falla visible:
    # una politica declarada que no se aplica no puede pasar por "no hay politica".
    $modelPath = ""
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
            $errMsg = Get-RsDiagnostico -Salida $raw -ExitCode $exitCode
            @{ success = $false; error = $errMsg; sql = $sqlEcho } | ConvertTo-Json
            exit 0
        }

        # Primera línea = cabeceras CSV, resto = datos. Sin filas, sqlplus no emite ni la cabecera.
        $lines = @($raw | Where-Object { $_.Trim() -ne "" })
        if ($lines.Count -le 1) {
            # Sin filas no hay nada que enmascarar, pero la respuesta mantiene la MISMA forma
            # que la del camino con filas: columns/rows/pii siempre presentes, y el bloque pii
            # con sus mismas claves y el modo REAL del workspace. Antes emitia dos claves
            # (mode/reason) con mode="off" fijo, de modo que un workspace en enforce reportaba
            # "off" en cuanto una consulta no devolvia filas. Se obtiene invocando pii_cli con
            # un resultset vacio: el modo y los avisos salen de la misma politica, no de un
            # literal en PowerShell. El aviso de predicado sigue teniendo sentido aqui (un
            # WHERE DNI = '...' que no encuentra nada tambien informa sobre el valor).
            # Nota: con SET PAGESIZE 0 sqlplus no emite cabecera cuando no hay filas, asi que
            # $lines.Count es 0 en este camino; no se intenta extraer nombres de columna.
            # Sin filas que proteger, un fallo del CLI no obliga a fallar cerrado: se propaga
            # su bloque pii (con el error) y ya.
            $rPii = Invoke-RsPii -Cabeceras @() -Matriz @() -Sql $sqlNorm -Workspace $Workspace -ModelPath $modelPath
            @{
                success   = $true
                row_count = 0
                truncated = $false
                sql       = $sqlEcho
                columns   = @()
                rows      = @()
                pii       = $rPii.pii
            } | ConvertTo-Json -Depth 4
            exit 0
        }

        $todas = @($lines | ConvertFrom-Csv)
        $rows  = @($todas | Select-Object -First $MaxRows)

        # --- Enmascarado PII ---
        # Se delega en scripts/pii_cli.py y NO se reimplementa aqui: la guarda read-only ya
        # esta duplicada entre este hook y la tool MCP, y una divergencia en la politica PII
        # seria una fuga silenciosa en vez de un error visible.
        # Cabeceras desde los objetos de ConvertFrom-Csv, NO partiendo $lines[0] por comas:
        # los valores con coma van entrecomillados (SET MARKUP CSV ... QUOTE ON) y un split
        # a mano los partiria en silencio, que es el bug que ConvertFrom-Csv evita.
        $cabeceras = @($todas[0].PSObject.Properties.Name)
        $matriz    = @()
        foreach ($fila in $rows) {
            $matriz += , @($cabeceras | ForEach-Object { "$($fila.$_)" })
        }

        $rPii = Invoke-RsPii -Cabeceras $cabeceras -Matriz $matriz -Sql $sqlNorm -Workspace $Workspace -ModelPath $modelPath
        if ($rPii.ok) {
            $cabeceras = $rPii.columns
            $matriz    = $rPii.rows
            $piiMeta   = $rPii.pii
        } elseif ($rPii.abierto) {
            # Fallo ABIERTO: el filtro no se puede ni ejecutar. Se devuelven los datos sin
            # tocar con el aviso en pii.error. Ver la cabecera de Invoke-RsPii.
            $piiMeta = $rPii.pii
        } else {
            # Fallo CERRADO: el filtro corrio y no pudo aplicar la politica sobre unas filas
            # que ya tenia. Devolverlas seria devolverlas en claro.
            @{
                success   = $false
                error     = $rPii.pii.error
                sql       = $sqlEcho
                row_count = 0
                truncated = $false
                columns   = @()
                rows      = @()
                pii       = $rPii.pii
            } | ConvertTo-Json -Depth 6
            exit 0
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
