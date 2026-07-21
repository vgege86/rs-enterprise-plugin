<#
.SYNOPSIS
    Lee docs\.rs-databases.json del workspace y devuelve la configuración de BD como JSON.
    Campos planos = conexión principal (conexiones[0]); además conexiones[] y motores[].
    NUNCA incluye el password — la tool get_db_config devuelve este dict tal cual al agente.

.PARAMETER Workspace
    Ruta raíz del proyecto (ej: C:\SVN\RS\<Proyecto>\trunk)

.EXAMPLE
    .\get-config.ps1 "C:\SVN\RS\<Proyecto>\trunk"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib-dbconfig.ps1")

$Workspace = Resolve-RsWorkspace $Workspace

$cfg = Read-RsDatabases $Workspace
if (-not $cfg.ok) {
    @{ error = $cfg.error } | ConvertTo-Json
    exit 1
}

$proyecto  = $cfg.proyecto
$resueltas = @()

foreach ($c in $cfg.conexiones) {
    $motor  = "$($c.motor)".ToUpper()
    $cadena = "$($c.cadena)"

    $ds = Get-CsPart -Cadena $cadena -Clave "Data Source"
    if (-not $ds) { $ds = Get-CsPart -Cadena $cadena -Clave "Server" }
    $user = Get-CsPart -Cadena $cadena -Clave "User Id"

    if ($motor -eq "ORACLE") {
        $schema = if ($c.schema) { "$($c.schema)" } else { $user }
    } else {
        $schema = if ($c.dataBase) { "$($c.dataBase)" } else { Get-CsPart -Cadena $cadena -Clave "Database" }
    }

    if ($c.model) {
        $modelPath = if ([System.IO.Path]::IsPathRooted("$($c.model)")) { "$($c.model)" } else { Join-Path $Workspace "$($c.model)" }
    } else {
        $modelPath = Join-Path $Workspace "BD\$proyecto-model.json"
    }
    $modelExists = Test-Path $modelPath

    # Si el schema cayó al fallback (= usuario de conexión) y ya existe model.json, su campo
    # "schema" es la fuente de verdad real: el owner de las tablas puede no ser el usuario de
    # conexión (ej. un usuario de solo-consulta cross-schema).
    if ($motor -eq "ORACLE" -and $schema -eq $user -and $modelExists) {
        try {
            $modelSchema = (Get-Content $modelPath -Raw -Encoding UTF8 | ConvertFrom-Json).schema
            if ($modelSchema) { $schema = $modelSchema }
        } catch { }
    }

    $resueltas += [ordered]@{
        id           = "$($c.id)"
        motor        = $motor
        datasource   = $ds
        schema       = $schema
        user         = $user
        model_path   = $modelPath
        model_exists = $modelExists
    }
}

$principal = $resueltas[0]

@{
    proyecto     = $proyecto
    workspace    = $Workspace
    motor        = $principal.motor
    datasource   = $principal.datasource
    schema       = $principal.schema
    user         = $principal.user
    model_path   = $principal.model_path
    model_exists = $principal.model_exists
    conexiones   = @($resueltas)
    motores      = @($resueltas | ForEach-Object { $_.motor } | Select-Object -Unique)
} | ConvertTo-Json -Depth 5
