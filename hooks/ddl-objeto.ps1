<#
.SYNOPSIS
    Devuelve el DDL de UN objeto de BD (vista, procedimiento, paquete, funcion, trigger, sinonimo
    o secuencia) leyendolo de la base de datos viva.

    El model.json guarda de cada objeto su ficha y una firma, NUNCA el cuerpo — el instalador
    tiene que seguir extrayendo de la BD viva o un modelo desactualizado entregaria codigo viejo.
    Eso deja al desarrollo con el inventario pero sin el codigo: se sabe que un procedimiento
    existe, cuantas lineas tiene y que tablas toca, pero para leerlo habia que abrir un cliente
    de BD. Esto lo lee cuando se pide, y no lo guarda.

    Es el mismo texto que entregaria el instalador: los mismos extractores y el mismo maquetado.

    Si el objeto esta en el inventario, compara la firma de la BD con la del modelo y avisa si no
    coinciden — alguien lo toco despues de la ultima sincronizacion.

.PARAMETER Workspace
    Ruta raiz del proyecto (carpeta trunk).

.PARAMETER Objeto
    Nombre del objeto. No distingue mayusculas.

.PARAMETER Proyecto
    Nombre del proyecto. Inferido del workspace si se omite.

.PARAMETER Seccion
    Limita la busqueda a un tipo (secuencias, vistas, funciones, procedimientos, paquetes,
    triggers, sinonimos). Sin esto se usa el inventario del modelo para saber donde mirar, y si
    el objeto no esta en el se barren los siete tipos.

.PARAMETER Out
    Escribe el DDL en un fichero en vez de volcarlo por consola.

.EXAMPLE
    .\ddl-objeto.ps1 "C:\SVN\RS\<Proyecto>\trunk" P_ALTA_CLIENTE
.EXAMPLE
    .\ddl-objeto.ps1 "<trunk>" MIPKG -Seccion paquetes -Out "C:\temp\MIPKG.sql"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Objeto,
    [string]$Proyecto = "",
    [string]$Seccion = "",
    [string]$Out = ""
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

$py = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts\object-ddl.py"
if (!(Test-Path $py)) {
    @{ success = $false; error = "No se encuentra $py" } | ConvertTo-Json
    exit 1
}

$argumentos = @($py, $Workspace, $Proyecto, $Objeto)
if ($Seccion) { $argumentos += @('--seccion', $Seccion) }
if ($Out)     { $argumentos += @('--out', $Out) }

# El DDL sale TAL CUAL por consola (o al fichero de -Out): es lo que se ha venido a leer.
& python @argumentos
exit $LASTEXITCODE
