<#
.SYNOPSIS
    Ejecuta una consulta SQL de solo lectura contra la BD del workspace y devuelve el resultado
    como JSON, con la politica PII aplicada.

.DESCRIPTION
    Envoltorio de la herramienta db_query (scripts/rs_core.py) a traves de la CLI scripts/rs.py:
    misma guarda de solo lectura, mismo enmascarado y misma salida que la tool MCP. Desde la
    3.30.0 este hook no lleva logica propia; hasta entonces duplicaba en PowerShell la guarda y
    el tratamiento de la salida de sqlplus/sqlcmd.

    ⛔ Sin Python falla CERRADO: no hay consulta. Antes devolvia los datos sin enmascarar con un
    aviso (fallo abierto); con la politica PII en enforce eso era justo la fuga que se evita.

.PARAMETER Workspace
    Ruta raiz del proyecto (trunk).

.PARAMETER Sql
    Sentencia SQL SELECT a ejecutar.

.PARAMETER MaxRows
    Maximo de filas a devolver (defecto 200).

.PARAMETER Conexion
    Id de conexion de docs\.rs-databases.json. Si se omite, la principal (conexiones[0]).

.NOTES
    $env:RS_PYTHON elige el interprete (ruta o nombre). Si esta definida y no es ejecutable,
    falla cerrado: no se cae en silencio a otro Python.
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Sql,
    [int]$MaxRows = 200,
    [string]$Conexion = ""
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"
$env:PYTHONUTF8 = "1"

function Get-RsPython {
    <#
    .SYNOPSIS
        Localiza el interprete de Python: $env:RS_PYTHON si esta definida, si no python,
        python3 o el lanzador py.
    .OUTPUTS
        Array con el ejecutable y sus argumentos previos (@('python') o @('py','-3')); $null si
        no hay ninguno.
    #>
    if ($env:RS_PYTHON) {
        if (Get-Command $env:RS_PYTHON -CommandType Application -ErrorAction SilentlyContinue) { return , @($env:RS_PYTHON) }
        return $null
    }
    foreach ($nombre in @('python', 'python3')) {
        if (Get-Command $nombre -CommandType Application -ErrorAction SilentlyContinue) { return , @($nombre) }
    }
    if (Get-Command 'py' -CommandType Application -ErrorAction SilentlyContinue) { return , @('py', '-3') }
    return $null
}

$cli = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) "scripts") "rs.py"
$python = Get-RsPython

if (-not $python -or -not (Test-Path $cli)) {
    $motivo = if ($python) { "no se encuentra scripts\rs.py" }
              elseif ($env:RS_PYTHON) { "RS_PYTHON='$($env:RS_PYTHON)' no es un ejecutable" }
              else { "falta python en el PATH" }
    @{
        success = $false
        error   = "db_query no disponible: $motivo. Sin Python no se consulta: la politica PII no se podria aplicar."
        columns = @(); rows = @(); row_count = 0; rows_truncated = $false
        pii     = @{ mode = "error"; error = "motor de enmascarado no disponible - no se devuelven filas" }
    } | ConvertTo-Json -Depth 4
    exit 1
}

# Parametros en JSON por stdin: el SQL viaja intacto (comillas, saltos de linea, $) sin
# depender del escapado de la linea de comandos.
$argumentos = @{ workspace = $Workspace; sql = $Sql; max_rows = $MaxRows; conexion = $Conexion } |
              ConvertTo-Json -Compress
$exe   = $python[0]
$extra = @($python | Select-Object -Skip 1)
$salida = $argumentos | & $exe @extra $cli db_query --args-json -
$codigo = $LASTEXITCODE

# Salida vacia = Python no llego a ejecutar la CLI (p. ej. el alias de la Microsoft Store, que
# no hace nada). Mismo fallo cerrado que sin Python.
if (-not ($salida -join "").Trim()) {
    @{
        success = $false
        error   = "db_query no disponible: '$exe' no ejecuto scripts\rs.py (exit $codigo). Sin Python no se consulta."
        columns = @(); rows = @(); row_count = 0; rows_truncated = $false
        pii     = @{ mode = "error"; error = "motor de enmascarado no disponible - no se devuelven filas" }
    } | ConvertTo-Json -Depth 4
    exit 1
}
$salida
exit $codigo
