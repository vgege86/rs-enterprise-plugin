<#
.SYNOPSIS
    Sincroniza al model.json el inventario de objetos de BD: vistas, procedimientos, paquetes,
    funciones, triggers, sinonimos y secuencias.

    Del objeto se guarda su ficha —tipo, estado, nº de lineas, tablas que usa— y una FIRMA del
    cuerpo, nunca el cuerpo. El instalador sigue extrayendo de la BD viva, asi que la garantia
    de que un paquete no puede entregar codigo viejo se mantiene; la firma es lo que permite
    saber QUE cambio desde la ultima entrega, que es lo que le faltaba a /rs-actualizador.

    Motivo de fondo en scripts/_dbobjetos.py.

.PARAMETER Workspace
    Ruta raiz del proyecto (carpeta trunk).

.PARAMETER Proyecto
    Nombre del proyecto. Inferido del workspace si se omite.

.PARAMETER DryRun
    No escribe el modelo: solo lista el inventario y el diff contra el actual.

.PARAMETER Conexion
    Id de conexion de docs\.rs-databases.json. Si se omite, la principal (conexiones[0]).
    Leer como dueno del esquema es la unica forma de ver los sinonimos PRIVADOS y todo el
    PL/SQL: ningun GRANT los expone.

.EXAMPLE
    .\sync-model-objects.ps1 "C:\SVN\RS\<Proyecto>\trunk"
.EXAMPLE
    .\sync-model-objects.ps1 "<trunk>" -DryRun
.EXAMPLE
    .\sync-model-objects.ps1 "<trunk>" -Conexion DUENO
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$Proyecto = "",
    [switch]$DryRun,
    [string]$Conexion = ""
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"
$env:PYTHONUTF8 = "1"

if (-not $Proyecto) {
    $Proyecto = if ((Split-Path $Workspace -Leaf) -eq 'trunk') {
        Split-Path (Split-Path $Workspace -Parent) -Leaf
    } else {
        Split-Path $Workspace -Leaf
    }
}

$py = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts\model-objects.py"
if (!(Test-Path $py)) {
    @{ success = $false; error = "No se encuentra $py" } | ConvertTo-Json
    exit 1
}

$argumentos = @($py, $Workspace, $Proyecto)
if ($DryRun)   { $argumentos += '--dry-run' }
if ($Conexion) { $argumentos += @('--conexion', $Conexion) }

# La salida del script va TAL CUAL a la consola: lleva el inventario por seccion, el bloque de
# cobertura y el diff contra el modelo anterior, que es lo que hay que leer. El JSON de abajo
# es solo el veredicto.
& python @argumentos
$code = $LASTEXITCODE

# exit 2 = PARCIAL, por cualquiera de estas dos causas:
#   - algun tipo de objeto fallo al extraerse (el resto si se sincronizo), o
#   - hay hueco de cobertura: el diccionario ve mas objetos de los que esta cuenta capturo.
# En ninguno de los dos casos es un fallo total, y en ninguno se ha borrado nada del modelo.
# ⛔ Un inventario incompleto NO se puede leer como "estos objetos ya no existen": lo que
# sigue —el delta de /rs-actualizador, el contraste del instalador— tiene que tratarlo como
# "no se sabe", que es lo que significa.
@{
    success  = ($code -eq 0 -or $code -eq 2)
    parcial  = ($code -eq 2)
    dry_run  = [bool]$DryRun
    conexion = $Conexion
    proyecto = $Proyecto
    modelo   = (Join-Path $Workspace "BD\$Proyecto-model.json")
    exit     = $code
} | ConvertTo-Json

exit $(if ($code -eq 2) { 0 } else { $code })
