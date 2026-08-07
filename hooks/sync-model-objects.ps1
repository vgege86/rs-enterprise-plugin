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

.EXAMPLE
    .\sync-model-objects.ps1 "C:\SVN\RS\<Proyecto>\trunk"
.EXAMPLE
    .\sync-model-objects.ps1 "<trunk>" -DryRun
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$Proyecto = "",
    [switch]$DryRun
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
if ($DryRun) { $argumentos += '--dry-run' }

# La salida del script va TAL CUAL a la consola: lleva el inventario por seccion y el diff
# contra el modelo anterior, que es lo que hay que leer. El JSON de abajo es solo el veredicto.
& python @argumentos
$code = $LASTEXITCODE

# exit 2 = algun tipo de objeto fallo pero el resto se sincronizo. No es un fallo total: el
# modelo queda con lo que se pudo leer y conservando lo anterior de lo que no.
@{
    success  = ($code -eq 0 -or $code -eq 2)
    parcial  = ($code -eq 2)
    dry_run  = [bool]$DryRun
    proyecto = $Proyecto
    modelo   = (Join-Path $Workspace "BD\$Proyecto-model.json")
    exit     = $code
} | ConvertTo-Json

exit $(if ($code -eq 2) { 0 } else { $code })
