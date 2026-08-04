<#
.SYNOPSIS
    Lectura y parseo de docs\.rs-databases.json — formato de config BD del plugin.
    Único sitio que conoce el formato. Dot-sourcear desde los hooks que lo necesiten.
#>

# Cripto de secretos (Unprotect-RsSecret): el password de la cadena puede venir cifrado con DPAPI
# (enc:<base64>). Se carga aquí para que todo hook que use la config BD pueda descifrarlo.
. (Join-Path $PSScriptRoot "lib-crypto.ps1")

function Get-CsPart {
    <# Extrae el valor de una clave de una cadena de conexión. "" si no está.
       Asunción: el split por ';' no lleva control de profundidad de paréntesis, así que un ';'
       dentro de un segmento entre paréntesis (ej. un TNS descriptor contrivado con
       "(SERVICE_NAME=PDB1;Region=EU)") trunca el valor silenciosamente. Se acepta porque los
       TNS descriptors reales de Oracle no llevan ';' sueltos dentro de paréntesis. Cuatro hooks
       dependen de esta función — si esa asunción deja de cumplirse, revisar aquí primero. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Cadena,
        [Parameter(Mandatory=$true)][string]$Clave
    )
    if (-not $Cadena) { return "" }
    $esc   = [regex]::Escape($Clave)
    $parts = $Cadena -split ';\s*(?=[A-Za-z])'
    $hit   = $parts | Where-Object { $_ -match "^\s*$esc\s*=" } | Select-Object -First 1
    if ($hit) { return ($hit -replace "^\s*$esc\s*=", "").Trim() }
    return ""
}

function Get-RsProyecto {
    <# Nombre de proyecto desde la ruta del workspace: carpeta anterior a trunk\. #>
    param([Parameter(Mandatory=$true)][string]$Workspace)
    $item = Get-Item $Workspace
    if ($item.Name -eq "trunk") { return $item.Parent.Name }
    return $item.Name
}

function Read-RsDatabases {
    <# Lee y valida docs\.rs-databases.json. Devuelve hashtable con ok/error/proyecto/conexiones/path. #>
    param([Parameter(Mandatory=$true)][string]$Workspace)

    $path = Join-Path $Workspace "docs\.rs-databases.json"
    if (-not (Test-Path $path)) {
        $legacy = Join-Path $Workspace "docs\XMLConfig.xml"
        $msg = "Config BD no encontrada: $path"
        if (Test-Path $legacy) {
            $msg += ". Workspace sin migrar — ejecutar: hooks\convert-config.ps1 `"$Workspace`""
        }
        return @{ ok = $false; error = $msg; proyecto = ""; conexiones = @(); path = $path }
    }

    try {
        $cfg = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return @{ ok = $false; error = "JSON no parseable en ${path}: $($_.Exception.Message)"; proyecto = ""; conexiones = @(); path = $path }
    }

    $conexiones = @($cfg.conexiones | Where-Object { $_ -ne $null })
    if ($conexiones.Count -eq 0) {
        return @{ ok = $false; error = "Sin conexiones declaradas en $path"; proyecto = ""; conexiones = @(); path = $path }
    }

    $ids = @()
    foreach ($c in $conexiones) {
        if (-not $c.id)     { return @{ ok = $false; error = "Conexión sin 'id' en $path"; proyecto = ""; conexiones = @(); path = $path } }
        if (-not $c.motor)  { return @{ ok = $false; error = "Conexión '$($c.id)' sin 'motor' en $path"; proyecto = ""; conexiones = @(); path = $path } }
        if (-not $c.cadena) { return @{ ok = $false; error = "Conexión '$($c.id)' sin 'cadena' en $path"; proyecto = ""; conexiones = @(); path = $path } }
        $motor = "$($c.motor)".ToUpper()
        if ($motor -ne "ORACLE" -and $motor -ne "SQLSERVER") {
            return @{ ok = $false; error = "Conexión '$($c.id)': motor '$($c.motor)' no soportado. Válidos: ORACLE, SQLSERVER"; proyecto = ""; conexiones = @(); path = $path }
        }
        if ($ids -contains $c.id) {
            return @{ ok = $false; error = "id duplicado '$($c.id)' en $path"; proyecto = ""; conexiones = @(); path = $path }
        }
        $ids += $c.id
    }

    $proyecto = if ($cfg.proyecto) { "$($cfg.proyecto)" } else { Get-RsProyecto $Workspace }

    return @{ ok = $true; error = ""; proyecto = $proyecto; conexiones = $conexiones; path = $path }
}

function Get-RsModelPath {
    <# Ruta del modelo BD de UNA conexion. Unico sitio que resuelve el campo "model".

       Lo usan get-config.ps1 (que la publica como model_path, y de ahi la consume la tool
       MCP db_query) y db-query.ps1 (que se la pasa a scripts/pii_cli.py). Tiene que ser
       una sola implementacion: el modelo NO es solo el esquema, lleva pii_policy entera
       (mode, transform, patterns_add/remove y las tablas parametricas). Si los dos caminos
       resuelven modelos distintos, uno enmascara y el otro no, y la respuesta del que no
       enmascara es indistinguible de la de un workspace sin politica declarada.

       Sin campo "model" en la conexion cae al convenio BD\<proyecto>-model.json. #>
    param(
        [Parameter(Mandatory=$true)][string]$Workspace,
        [Parameter(Mandatory=$true)]$Conexion,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Proyecto
    )
    $declarado = "$($Conexion.model)"
    if ($declarado) {
        if ([System.IO.Path]::IsPathRooted($declarado)) { return $declarado }
        return (Join-Path $Workspace $declarado)
    }
    return (Join-Path $Workspace "BD\$Proyecto-model.json")
}

function Test-RsModelDeclarado {
    <# $true si la conexion DECLARA su modelo (campo "model"); $false si la ruta que
       devuelve Get-RsModelPath sale del convenio BD\<proyecto>-model.json.

       Get-RsModelPath devuelve SIEMPRE una ruta, asi que tenerla no dice nada sobre si
       alguien declaro una politica. Esa distincion es la que decide que pasa cuando el
       fichero no esta:

         declarado y ausente -> workspace ROTO. Hay una politica declarada que no se
                                puede aplicar; devolver las filas seria devolverlas en
                                claro etiquetadas como "workspace sin politica", que es
                                indistinguible de uno que nunca configuro nada. Error.
         convenio y ausente  -> workspace que nunca declaro politica. Caso ordinario:
                                mode=off, datos en claro. Es lo que garantiza que un
                                workspace que actualiza no cambie de comportamiento.

       Unico sitio que conoce la regla, igual que Get-RsModelPath: la publica
       get-config.ps1 como model_declarado (de ahi la consume la tool MCP db_query) y la
       usa db-query.ps1 para decirselo a scripts/pii_cli.py. Si cada camino la dedujera
       por su cuenta volverian a divergir. #>
    param([Parameter(Mandatory=$true)]$Conexion)
    return [bool]"$($Conexion.model)"
}

function Resolve-RsWorkspace {
    <# Si el agente pasó una subcarpeta (docs, BD, Batch, OnLine) sube al trunk. #>
    param([Parameter(Mandatory=$true)][string]$Workspace)
    if ($Workspace.TrimEnd('\') -match '\\(docs|BD|Batch|OnLine)$') {
        return (Split-Path $Workspace -Parent)
    }
    return $Workspace
}
