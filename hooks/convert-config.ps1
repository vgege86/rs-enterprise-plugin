<#
.SYNOPSIS
    Convierte docs\XMLConfig.xml → docs\.rs-databases.json. Uso único por workspace.
    NO borra el XML: el borrado se hace en un commit aparte tras verificar con /rs-env.

.PARAMETER Workspace
    Ruta raíz del proyecto (trunk).

.PARAMETER Force
    Sobrescribe el JSON si ya existe.

.EXAMPLE
    .\convert-config.ps1 "C:\SVN\RS\<Proyecto>\trunk"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [switch]$Force
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib-dbconfig.ps1")

$Workspace = Resolve-RsWorkspace $Workspace
$xmlPath   = Join-Path $Workspace "docs\XMLConfig.xml"
$jsonPath  = Join-Path $Workspace "docs\.rs-databases.json"

if (-not (Test-Path $xmlPath)) {
    @{ success = $false; error = "XMLConfig.xml no encontrado en: $xmlPath" } | ConvertTo-Json
    exit 1
}
if ((Test-Path $jsonPath) -and -not $Force) {
    @{ success = $true; skipped = $true; path = $jsonPath; message = "Ya existe — usar -Force para sobrescribir" } | ConvertTo-Json
    exit 0
}

[xml]$config = Get-Content $xmlPath -Encoding UTF8
$dbNode  = $config.SelectSingleNode("//DataBase")
$conNode = $config.SelectSingleNode("//Conexion")

$schema = ""; $database = ""

if ($dbNode) {
    $motor    = $dbNode.GetAttribute("motor")
    $rawDs    = $dbNode.GetAttribute("dataSource")
    $schema   = $dbNode.GetAttribute("schema")
    $database = $dbNode.GetAttribute("dataBase")
    $user     = $dbNode.GetAttribute("user")
    $pass     = $dbNode.GetAttribute("password")
    if (-not $motor) { $motor = "ORACLE" }
    $motor = $motor.ToUpper()
    # Atributos sueltos → recomponer cadena de conexión completa
    if ($rawDs -notmatch 'User Id\s*=') {
        if ($motor -eq "ORACLE") {
            $cadena = "Data Source=$rawDs; User Id=$user;Password=$pass"
        } else {
            $cadena = "Server=$rawDs;Database=$database;User Id=$user;Password=$pass"
        }
    } else {
        $cadena = $rawDs
    }
    if ($pass -and ($cadena -notmatch 'Password\s*=')) {
        $cadena = "$cadena;Password=$pass"
    }
} elseif ($conNode) {
    $motor  = "$($conNode.MotorDatos)"
    if (-not $motor) { $motor = "ORACLE" }
    $motor  = $motor.ToUpper()
    $cadena = "$($conNode.DataSource)"
} else {
    @{ success = $false; error = "Ni <DataBase> ni <Conexion> encontrados en $xmlPath" } | ConvertTo-Json
    exit 1
}

$cadena = $cadena.Trim()
$user   = Get-CsPart -Cadena $cadena -Clave "User Id"

$conexion = [ordered]@{
    id     = $motor.ToLower()
    motor  = $motor
    cadena = $cadena
}
if ($motor -eq "ORACLE") {
    $conexion.schema = if ($schema) { $schema } else { $user }
} else {
    $conexion.dataBase = if ($database) { $database } else { Get-CsPart -Cadena $cadena -Clave "Database" }
}

$out = [ordered]@{
    proyecto   = (Get-RsProyecto $Workspace)
    conexiones = @($conexion)
}

($out | ConvertTo-Json -Depth 5) | Set-Content $jsonPath -Encoding UTF8

@{ success = $true; path = $jsonPath; motor = $motor; id = $conexion.id } | ConvertTo-Json
