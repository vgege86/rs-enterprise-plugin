<#
.SYNOPSIS
    Diagnostico de visibilidad de una conexion sobre su esquema: si la cuenta es duena, que
    GRANTs tiene y cuantos objetos de cada tipo ve el diccionario.

    Responde a la pregunta que ningun hook podia responder por su cuenta: cuando una consulta
    devuelve menos objetos de los esperados, ¿es que no existen o es que esta cuenta no los ve?

    La logica esta en hooks\lib-dbvisibilidad.ps1. Este hook existe para que los scripts Python
    (installer-objects.py, model-objects.py) usen la MISMA implementacion en vez de reescribir
    las consultas por su cuenta — mismo patron que installer-inserts.py::read_db_config con
    get-config.ps1, cacheado en la variable de entorno RS_DB_VISIBILIDAD_JSON.

.PARAMETER Workspace
    Ruta raiz del proyecto (carpeta trunk).

.PARAMETER Conexion
    Id de conexion de docs\.rs-databases.json. Si se omite, la principal (conexiones[0]).

.EXAMPLE
    .\db-visibilidad.ps1 "C:\SVN\RS\<Proyecto>\trunk"
.EXAMPLE
    .\db-visibilidad.ps1 "<trunk>" -Conexion DUENO
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$Conexion = ""
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

trap {
    @{ ok = $false; soportado = $false; error = $_.Exception.Message; step = "db-visibilidad" } | ConvertTo-Json -Depth 5
    exit 1
}

$hooksDir = Split-Path $PSCommandPath -Parent
. (Join-Path $hooksDir "lib-dbconfig.ps1")
. (Join-Path $hooksDir "lib-dbvisibilidad.ps1")

$Workspace = Resolve-RsWorkspace $Workspace

$cfg = Read-RsDatabases $Workspace
if (-not $cfg.ok) {
    @{ ok = $false; soportado = $false; error = $cfg.error } | ConvertTo-Json -Depth 5
    exit 1
}

$c = Select-RsConexion -Config $cfg -Id $Conexion
if (-not $c) {
    $validas = ($cfg.conexiones | ForEach-Object { "$($_.id)" }) -join ", "
    @{ ok = $false; soportado = $false; error = "Conexion '$Conexion' no existe. Validas: $validas" } | ConvertTo-Json -Depth 5
    exit 1
}

$motor  = "$($c.motor)".ToUpper()
$cadena = "$($c.cadena)"

$dataSource = Get-CsPart -Cadena $cadena -Clave "Data Source"
if (-not $dataSource) { $dataSource = Get-CsPart -Cadena $cadena -Clave "Server" }
$user     = Get-CsPart -Cadena $cadena -Clave "User Id"
$password = Unprotect-RsSecret (Get-CsPart -Cadena $cadena -Clave "Password")

# El owner real de las tablas puede no ser el usuario de conexion. Si el modelo ya existe, su
# campo "schema" es la fuente de verdad — misma regla que get-config.ps1 y sync-from-db.ps1.
$schema = if ($c.schema) { "$($c.schema)" } else { $user }
if ($motor -eq "ORACLE" -and $schema -eq $user) {
    $modelPath = Get-RsModelPath -Workspace $Workspace -Conexion $c -Proyecto $cfg.proyecto
    if (Test-Path $modelPath) {
        try {
            $ms = (Get-Content $modelPath -Raw -Encoding UTF8 | ConvertFrom-Json).schema
            if ($ms) { $schema = $ms }
        } catch { }
    }
}

$vis = Get-RsVisibilidad -Motor $motor -Esquema $schema -DataSource $dataSource `
                         -Usuario $user -Password $password

# `conexion` en la salida: el guardarrail de trazabilidad del parametro -Conexion. Sin el, una
# lectura hecha como dueno es indistinguible de una hecha con la cuenta de consulta.
$vis.conexion = "$($c.id)"
$vis.motor    = $motor
$vis | ConvertTo-Json -Depth 5
