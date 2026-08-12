<#
.SYNOPSIS
    Guarda PreToolUse sobre Write/Edit: impide escribir identificadores de cliente en el
    repo del PLUGIN.

.DESCRIPTION
    docs/plugin-architecture.md #10 lo dice desde hace tiempo: en este repo no van nombres
    de cliente, ni sus derivados identificables (esquema de BD, usuario de conexion, ruta
    de instalacion, dominio corporativo). El plugin es generico y su repo se comparte. Aun
    asi, en 3.22.2 hubo que limpiar tres identificadores reales de references/jira.md, que
    viaja dentro del plugin instalado. Una regla que solo vive en un documento se salta sin
    enterarse; esta guarda la hace efectiva.

    AMBITO. Solo actua si el fichero a escribir cae DENTRO del repo del plugin. Fuera de
    ahi sale por 0 sin mirar nada. No es una excepcion comoda: en el workspace del cliente
    los nombres propios son legitimos y necesarios -- la propia regla del #10 lo dice. Una
    guarda que bloqueara ahi seria un estorbo diario y acabaria desactivada.

    DOS CAPAS, con severidad distinta a proposito:

    | Capa | Origen                          | Falsos positivos | Accion  |
    |------|---------------------------------|------------------|---------|
    | 1    | lista declarada por el usuario  | ninguno          | BLOQUEA |
    | 2    | heuristica estructural          | algunos          | avisa   |

    La capa 1 no puede vivir en el repo -- seria exactamente la fuga que intenta evitar --,
    asi que se lee de ~/.claude/rs-clientes.json, fuera de cualquier repo (mismo criterio
    que rs-jira-credentials.json). Sin ese fichero, la capa 1 queda inactiva y la guarda no
    bloquea nada: es una decision consciente, no un fallo silencioso.

    Bloquear tambien la capa 2 era la otra opcion y se descarto por el mismo motivo que
    pii-guard-write.ps1 exige checksum al DNI en vez de conformarse con la forma: una
    guarda que salta de mas se acaba apagando, y entonces no protege nada.

    NO depende del modo PII del workspace (Get-RsPiiEstadoGuarda). Son ejes distintos: PII
    protege datos personales segun lo que diga cada workspace; esto protege la identidad de
    cliente en un unico repo. Un "off" de PII no debe abrir este agujero.

    Registro en .claude-plugin/plugin.json bajo hooks.PreToolUse con matcher "Write|Edit".
    Salida 2 = bloquear, 0 = permitir.
#>
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot "lib-pii.ps1")

try {
    # Misma dualidad que pii-guard-write.ps1: stdin real cuando Claude Code lanza el hook
    # como proceso, $input cuando un test Pester lo invoca via pipe dentro del mismo proceso.
    $textoEvento = Repair-RsTextoUtf8 ([string]::Join("`n", @($input)))
    if (-not $textoEvento) { $textoEvento = Read-RsStdinUtf8 }
    $evento    = $textoEvento | ConvertFrom-Json
    $ruta      = "$($evento.tool_input.file_path)"
    $contenido = "$($evento.tool_input.content)$($evento.tool_input.new_string)"
} catch {
    exit 0
}

if (-not $ruta) { exit 0 }

function Find-RsPluginRaiz {
    <# Sube desde $Desde hasta encontrar un .claude-plugin/plugin.json cuyo "name" sea
       rs-enterprise-agent. "" si no aparece.

       Se comprueba el NOMBRE, no solo la existencia del fichero: el repo lleva tambien
       plugins/rs-validador/ con su propio manifest (#9.5), y ese es otro plugin -- pero
       cuelga del mismo arbol, asi que la busqueda sigue subiendo y acaba encontrando el
       manifest raiz. Es lo correcto: la regla del #10 aplica a todo el repo. #>
    param([string]$Desde)

    $dir = $Desde
    if (Test-Path -LiteralPath $dir -PathType Leaf -ErrorAction SilentlyContinue) {
        $dir = Split-Path -Parent $dir
    } elseif (-not (Test-Path -LiteralPath $dir -ErrorAction SilentlyContinue)) {
        # Fichero aun inexistente (Write de uno nuevo): partir de su carpeta igualmente.
        $dir = Split-Path -Parent $dir
    }

    while ($dir) {
        $manifest = Join-Path $dir ".claude-plugin/plugin.json"
        if (Test-Path -LiteralPath $manifest -ErrorAction SilentlyContinue) {
            try {
                $j = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
                if ("$($j.name)" -eq "rs-enterprise-agent") { return $dir }
            } catch { }
        }
        $padre = Split-Path -Parent $dir
        if ($padre -eq $dir) { break }
        $dir = $padre
    }
    return ""
}

$raiz = Find-RsPluginRaiz $ruta
if (-not $raiz) { exit 0 }

# --------------------------------------------------------------------------------------
# Capa 1 -- lista declarada. BLOQUEA.
# --------------------------------------------------------------------------------------

$hogar = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
# RS_CLIENTES_PATH permite apuntar la lista a otro sitio; los tests lo usan para no
# depender del fichero real del usuario que ejecuta la suite.
$listaPath = if ($env:RS_CLIENTES_PATH) { $env:RS_CLIENTES_PATH }
             else { Join-Path $hogar ".claude/rs-clientes.json" }

$tokens = @()
if (Test-Path -LiteralPath $listaPath -ErrorAction SilentlyContinue) {
    try {
        $lista = Get-Content -LiteralPath $listaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($campo in @("nombres", "dominios", "esquemas")) {
            foreach ($v in @($lista.$campo)) {
                $s = "$v".Trim()
                # Un token de 1-2 caracteres casaria con medio repo. Se ignora en vez de
                # convertir la guarda en un bloqueo permanente.
                if ($s.Length -ge 3) { $tokens += ,@{ valor = $s; campo = $campo } }
            }
        }
    } catch {
        # Lista ilegible: avisar y seguir. No se bloquea todo por un JSON roto, pero
        # tampoco se calla -- si no, la proteccion desaparece sin que nadie lo note.
        Write-Output "AVISO rs-clientes: '$listaPath' no se pudo leer como JSON; la capa 1 de cliente-guard esta inactiva."
    }
}

foreach ($t in $tokens) {
    # Frontera de palabra a los dos lados para no casar dentro de otra palabra, e
    # insensible a mayusculas: el mismo nombre aparece como Cliente, CLIENTE y cliente.
    #
    # El guion NO cuenta como parte de la palabra a proposito. Con el dentro de la clase
    # ([\w-]) la guarda se saltaba "informe-<cliente>.md" y "<cliente>-config.json", que son
    # justo dos de las formas en que el nombre acaba en el repo -- lo destapo el test de la
    # ruta. Fuera de la clase, "<cliente>ter" (otra palabra que empieza igual) sigue sin casar,
    # que era lo que se queria evitar.
    $patron = '(?i)(?<!\w)' + [regex]::Escape($t.valor) + '(?!\w)'
    if ($contenido -match $patron -or $ruta -match $patron) {
        $donde = if ($ruta -match $patron) { "la ruta del fichero" } else { "el contenido a escribir" }
        Write-Error @"
BLOQUEADO: $donde contiene un identificador de cliente declarado.

Fichero: $ruta
Token:   '$($t.valor)'  (campo '$($t.campo)' de $listaPath)

Este es el repo del plugin y se comparte: no puede llevar nombres de cliente ni sus
derivados identificables (esquema de BD, usuario de conexion, ruta de instalacion,
dominio). Ver docs/plugin-architecture.md #10.

Salidas:
  - Ejemplo o plantilla        -> marcador generico: <PROYECTO>, <ESQUEMA>, <tu-site>.
  - Caso real en prosa         -> "una instalacion de cliente" / "el proyecto donde se
                                  detecto"; si hace falta la referencia concreta (una
                                  revision, un ticket), va sin el nombre.
  - Documento para terceros    -> los valores reales viajan en un anexo aparte.

Esto NO aplica a lo que los agentes escriben en el workspace del cliente: ahi los nombres
propios son legitimos y esta guarda no actua.
"@
        exit 2
    }
}

# --------------------------------------------------------------------------------------
# Capa 2 -- heuristica estructural. AVISA, no bloquea.
# --------------------------------------------------------------------------------------

# Esta guarda y su suite son los unicos ficheros del repo que contienen los patrones a
# proposito. Sin esta exclusion, mantenerlas dispararia el aviso en cada edicion.
$rutaNorm = $ruta -replace '\\', '/'
if ($rutaNorm -match '(?i)/hooks/cliente-guard-write\.ps1$' -or
    $rutaNorm -match '(?i)/tests/ClienteGuard\.Tests\.ps1$') { exit 0 }

# Segmentos que son del propio autor o genericos del stack, no de un cliente.
$segmentosPropios = @("Agentes", "RSStandard", "SkillsClaude", "Utils", "Comun", "Common")

$avisos = @()

foreach ($m in [regex]::Matches($contenido, '(?i)[A-Z]:[\\/](?:SVN|GIT)[\\/]RS[\\/]([\w.-]+)[\\/]')) {
    $seg = $m.Groups[1].Value
    if ($segmentosPropios -notcontains $seg -and $seg -notmatch '^<') {
        $avisos += "ruta de workspace de cliente: '$($m.Value)' (segmento '$seg')"
    }
}

foreach ($m in [regex]::Matches($contenido, '(?i)https://([\w-]+)\.atlassian\.net')) {
    $site = $m.Groups[1].Value
    if ($site -notmatch '^(tu-site|mi-site|ejemplo|example)$') {
        $avisos += "site Atlassian concreto: '$($m.Value)' -- usar https://<tu-site>.atlassian.net"
    }
}

foreach ($m in [regex]::Matches($contenido, '(?i)User\s+Id\s*=\s*([\w$#]+)')) {
    $u = $m.Groups[1].Value
    if ($u.Length -ge 4 -and $u -notmatch '^(usuario|user|demo|test)$') {
        $avisos += "usuario de conexion concreto: 'User Id=$u'"
    }
}

foreach ($m in [regex]::Matches($contenido, '(?i)"schema"\s*:\s*"([\w$#]+)"')) {
    $e = $m.Groups[1].Value
    if ($e.Length -ge 4 -and $e -notmatch '^(demo|test|esquema|schema)$') {
        $avisos += "esquema de BD concreto: '`"schema`": `"$e`"'"
    }
}

if ($avisos.Count -gt 0) {
    $detalle = ($avisos | Select-Object -Unique | ForEach-Object { "  - $_" }) -join "`n"
    Write-Output @"
AVISO cliente-guard: lo que se va a escribir en el repo del plugin tiene forma de
identificador concreto. No se bloquea (es heuristica, puede ser un falso positivo), pero
revisalo antes de dar el cambio por bueno.

Fichero: $ruta
$detalle

Si es real, sustituyelo por un marcador (<PROYECTO>, <ESQUEMA>, <USUARIO_CONEXION>,
<workspace>). Ver docs/plugin-architecture.md #10.
"@
}

exit 0
