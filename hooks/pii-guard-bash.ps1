<#
.SYNOPSIS
    Guarda PreToolUse sobre Bash: impide invocar clientes de BD saltandose db_query.

.DESCRIPTION
    GUARDARRAIL, NO CONTROL DE SEGURIDAD. Filtra por patron de comando y se elude
    escribiendo un script intermedio o invocando el binario por otra ruta. Frena el
    descuido, no a un agente decidido. El control real para este vector es la
    credencial de BD (ver docs/proteccion-pii-consultas-bd.md #3.1 y #5.2b).

    Registro en ~/.claude/settings.json bajo hooks.PreToolUse con matcher "Bash".
    Salida 2 = bloquear, 0 = permitir.
#>
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
# Solo por Repair-RsTextoUtf8/Read-RsStdinUtf8: esta guarda no usa los patrones de forma.
. (Join-Path $PSScriptRoot "lib-pii.ps1")

try {
    # Claude Code invoca el hook como proceso real con el JSON del evento por stdin real.
    # En un test Pester, "'json' | & script.ps1" no toca esa stream -- va por el pipeline de
    # objetos de PowerShell ($input) dentro del mismo proceso. Se admite cualquiera de las
    # dos vias para que el hook sea el mismo en produccion y en test.
    #
    # Las dos vias pasan por UTF-8 explicito: Read-RsStdinUtf8 lee el handle por bytes, y
    # Repair-RsTextoUtf8 deshace la descodificacion en pagina de codigos OEM que hace
    # PowerShell cuando la stdin del proceso llega por $input (que es lo que ocurre con
    # "powershell -File", la forma en que Claude Code lanza este hook). Ver lib-pii.ps1.
    $textoEvento = Repair-RsTextoUtf8 ([string]::Join("`n", @($input)))
    if (-not $textoEvento) { $textoEvento = Read-RsStdinUtf8 }
    $evento  = $textoEvento | ConvertFrom-Json
    $comando = "$($evento.tool_input.command)"
    $origen  = "$($evento.cwd)"
} catch {
    exit 0   # Sin evento parseable no hay nada que bloquear.
}

# La guarda sigue al modo del WORKSPACE (ver Get-RsPiiEstadoGuarda). Un comando de Bash no dice
# sobre que workspace actua, asi que se usa el cwd de la sesion: es la unica senal disponible.
# Corolario documentado en #5.2b: un comando lanzado desde el workspace A contra la BD del B se
# mide con el modo de A. Sigue siendo un guardarrail, no una frontera.
$estado = Get-RsPiiEstadoGuarda $origen
if (-not $estado.activa) { exit 0 }

# Clientes de BD invocados directamente. \b evita que "mysqlplus" o una ruta que
# contenga la palabra disparen por accidente.
$prohibidos = '\b(sqlplus|sqlcmd|osql|bcp|sqlldr|impdp|expdp)\b'

if ($comando -match $prohibidos) {
    # Solo se reporta el NOMBRE del cliente detectado, nunca el comando completo: el
    # comando de un cliente de BD lleva casi siempre la credencial inline (ej. "sqlplus
    # -S usuario/contrasena@ORCL", "sqlcmd ... -P contrasena"), y ecoarlo aqui pondria
    # esa contrasena en un mensaje visible para el usuario y potencialmente logueado --
    # justo lo que esta guarda existe para evitar. Mismo criterio que hooks/db-query.ps1
    # y el servidor MCP, que pasan la credencial por fichero temporal, nunca en claro.
    $cliente = $Matches[1]
    Write-Error @"
BLOQUEADO: cliente de BD invocado directamente ($cliente).

Las consultas a BD deben pasar por la tool MCP db_query, que aplica la politica de
proteccion de datos personales del workspace. Un cliente directo la evita por completo.

Si necesitas una consulta, usa db_query. Si el dato que necesitas sale enmascarado,
declara la columna como segura en BD/<proyecto>-model.json en vez de rodear el filtro.
"@
    exit 2
}

exit 0
