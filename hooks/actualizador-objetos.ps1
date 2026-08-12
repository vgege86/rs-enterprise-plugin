<#
.SYNOPSIS
    Genera el .sql de los objetos de BD que han cambiado desde la ultima entrega, para que viaje
    en el paquete de /rs-actualizador.

    El delta de una entrega es por VCS y un procedimiento, vista o trigger modificados EN BD no
    estan en el repo: se detectaban (desde la 3.10.0 el model.json guarda una firma de cada
    objeto) pero el script habia que escribirlo a mano. Esto lo escribe, con el mismo texto que
    entregaria el instalador.

    La linea base es el inventario `objetos` del model.json. Si el modelo no lo trae todavia, no
    hay contra que comparar y el script lo dice en vez de inventarlo.

    ⛔ Una SECUENCIA modificada no viaja: su DDL es CREATE (en SQL Server, DROP + CREATE) y
    contra el cliente o falla o reinicia el contador en la posicion de NUESTRA base de datos.
    Sale listada aparte para resolverla con un ALTER a mano.

    ⛔ De lo eliminado no se emite ningun DROP activo: va comentado al final del fichero.

    ⛔ Con hueco de COBERTURA (la cuenta no ve todo el esquema) NO se escribe nada. El PL/SQL
    exige GRANT EXECUTE, no SELECT: con cero grants el diccionario devuelve cero procedimientos
    SIN ERROR, y ese diff diria "se han eliminado todos". Aqui eso no es un aviso: es la entrada
    de un fichero que alguien ejecuta contra la BD de un cliente. -SinCobertura lo fuerza.

.PARAMETER Workspace
    Ruta raiz del proyecto (carpeta trunk).

.PARAMETER Destino
    Carpeta scripts\ de la entrega, donde se escribe el .sql.

.PARAMETER Proyecto
    Nombre del proyecto. Inferido del workspace si se omite.

.PARAMETER Prefijo
    Numero de orden del fichero. Por defecto, el primer hueco de la franja 90-98: despues de los
    scripts de las tareas y antes del 99-RVERSIONES.

.PARAMETER Nombre
    Nombre completo del fichero de salida. Manda sobre -Prefijo.

.PARAMETER Sincronizar
    Avanza la linea base del modelo tras generar. ⛔ Solo cuando la entrega este cerrada: un
    delta generado y luego descartado dejaria el modelo diciendo que eso ya se entrego.

.PARAMETER DryRun
    No escribe nada: solo lista lo que cambio y lo que entraria en el script.

.PARAMETER Conexion
    Id de conexion de docs\.rs-databases.json. Sin ella, la principal.

.PARAMETER SinCobertura
    Continua aunque la cuenta no vea todo el esquema. ⛔ Solo cuando se sabe que el hueco es
    legitimo: revisa el delta objeto a objeto antes de entregarlo.

.EXAMPLE
    .\actualizador-objetos.ps1 "C:\SVN\RS\<Proyecto>\trunk" "C:\AIS\<Proyecto>\Actualizador\TEST_20260812\scripts"
.EXAMPLE
    .\actualizador-objetos.ps1 "<trunk>" "<destino>\scripts" -DryRun
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Destino,
    [string]$Proyecto = "",
    [string]$Prefijo = "",
    [string]$Nombre = "",
    [string]$Conexion = "",
    [switch]$Sincronizar,
    [switch]$DryRun,
    [switch]$SinCobertura
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

$py = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts\delta-objects.py"
if (!(Test-Path $py)) {
    @{ success = $false; error = "No se encuentra $py" } | ConvertTo-Json
    exit 1
}

$argumentos = @($py, $Workspace, $Proyecto, $Destino)
if ($Prefijo)      { $argumentos += @('--prefijo', $Prefijo) }
if ($Nombre)       { $argumentos += @('--nombre', $Nombre) }
if ($Conexion)     { $argumentos += @('--conexion', $Conexion) }
if ($Sincronizar)  { $argumentos += '--sincronizar' }
if ($DryRun)       { $argumentos += '--dry-run' }
if ($SinCobertura) { $argumentos += '--sin-cobertura' }

# La salida del script va TAL CUAL a la consola: lleva el detalle de que cambio, que entra en el
# script y que queda retenido. El JSON de abajo es solo el veredicto.
& python @argumentos
$code = $LASTEXITCODE

# exit 2 = se genero el script pero algun tipo de objeto fallo al extraerse: lo que viaja es
# correcto, pero incompleto, y hay que revisar a mano el tipo que fallo.
@{
    success  = ($code -eq 0 -or $code -eq 2)
    parcial  = ($code -eq 2)
    dry_run  = [bool]$DryRun
    proyecto = $Proyecto
    destino  = $Destino
    exit     = $code
} | ConvertTo-Json

exit $(if ($code -eq 2) { 0 } else { $code })
