<#
.SYNOPSIS
    Comprueba los requisitos que el plugin NO puede instalar por sí mismo: Python y el paquete `mcp`.

.DESCRIPTION
    `.mcp.json` arranca el servidor con `python <plugin>/mcp/rs-workspace-server.py`. Ni el plugin ni
    Claude Code instalan Python ni el paquete `mcp`: es un paso manual previo del README. Cuando falta,
    el fallo es SILENCIOSO — los hooks PowerShell siguen vivos, los agentes despachan y el plugin
    parece instalado, pero ninguna tool MCP responde. Le pasó a una instalación nueva: el compañero
    siguió los pasos del marketplace y se saltó el paso 1.

    `/rs-env` no puede cubrirlo solo: se sirve de `check_env`, que es justo una tool MCP. Por eso esta
    comprobación es PowerShell puro y corre en `SessionStart`, antes de que nadie necesite el servidor.

    Trampa específica de Windows: sin Python instalado, `python` NO falta del PATH — resuelve al stub
    de la Microsoft Store (`...\WindowsApps\python.exe`), que no ejecuta nada y abre la tienda. Un
    `Get-Command python` a secas da OK y el diagnóstico se va por el desagüe, así que aquí se detecta
    aparte.

    ⛔ Nunca instala nada por su cuenta ni bloquea la sesión: sale por 0 siempre. La reparación
    (`-Reparar`) muta la máquina del usuario, así que la pide él explícitamente.

.PARAMETER Quiet
    Modo hook: sin salida si todo está en orden. Respeta el marcador (no spawnea Python en cada
    arranque de sesión).

.PARAMETER Reparar
    Instala `mcp>=1.2.0,<2` con el pip del Python detectado y vuelve a verificar. Solo bajo petición
    explícita del usuario.

.PARAMETER Force
    Ignora el marcador y rehace la comprobación completa.
#>
param(
    [switch]$Quiet,
    [switch]$Reparar,
    [switch]$Force
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# Versión del plugin: el marcador la lleva en el contenido, de modo que cada actualización rehace la
# comprobación una vez. Lectura textual (regex) y no ConvertFrom-Json: esto corre en cada SessionStart.
function Get-VersionPlugin {
    $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) ".claude-plugin\plugin.json"
    if (Test-Path $manifest) {
        $t = Get-Content $manifest -Raw -Encoding UTF8
        if ($t -match '"version"\s*:\s*"([^"]+)"') { return $Matches[1] }
    }
    return "desconocida"
}

# ¿Es el stub de la Microsoft Store? Ese ejecutable existe, pesa ~0 y no interpreta nada: abre la
# tienda. Se reconoce por la ruta (WindowsApps) y se confirma pidiéndole la versión.
function Test-StubStore([string]$Ruta) {
    if ($Ruta -notmatch '(?i)[\\/]WindowsApps[\\/]') { return $false }
    try { return ((Get-Item $Ruta).Length -lt 1024) } catch { return $true }
}

# Ejecuta un binario capturando salida y código, sin que un fallo aborte el script.
function Invoke-Capturado([string]$Exe, [string[]]$Argumentos) {
    $salida = ""
    $codigo = 1
    try {
        $salida = (& $Exe @Argumentos 2>&1 | Out-String).Trim()
        $codigo = $LASTEXITCODE
        if ($null -eq $codigo) { $codigo = 0 }
    } catch {
        $salida = "$_"
        $codigo = 1
    }
    return @{ salida = $salida; codigo = $codigo }
}

$version   = Get-VersionPlugin
$marcador  = Join-Path $env:USERPROFILE ".claude\.rs-requisitos-ok"

# El marcador solo lo respeta el modo hook. Invocado a mano (/rs-env, -Reparar) siempre se comprueba
# de verdad: quien lo lanza es porque sospecha que algo va mal.
if ($Quiet -and -not $Force -and -not $Reparar -and (Test-Path $marcador)) {
    try {
        if ((Get-Content $marcador -Raw -Encoding UTF8).Trim() -eq $version) { exit 0 }
    } catch { }
}

# ── 1. ¿Hay un Python usable? ────────────────────────────────────────────────
$py      = $null
$rutaPy  = $null
$motivo  = $null
$arreglo = $null

$cmd = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cmd) { $rutaPy = $cmd.Source }

if (-not $rutaPy) {
    $motivo  = "no hay ningún 'python' en el PATH"
} elseif (Test-StubStore $rutaPy) {
    $motivo  = "'python' resuelve al marcador de la Microsoft Store ($rutaPy), que no ejecuta nada"
    $rutaPy  = $null
} else {
    $v = Invoke-Capturado $rutaPy @("--version")
    # `-match` explícito (no `-notmatch` negado): solo `-match` garantiza $Matches poblado.
    $m = [regex]::Match($v.salida, 'Python\s+(\d+)\.(\d+)')
    if ($v.codigo -ne 0 -or -not $m.Success) {
        $motivo = "'python' ($rutaPy) no responde a --version"
        $rutaPy = $null
    } else {
        $mayor = [int]$m.Groups[1].Value; $menor = [int]$m.Groups[2].Value
        $verPy = "$mayor.$menor"
        if ($mayor -lt 3 -or ($mayor -eq 3 -and $menor -lt 11)) {
            $motivo = "Python $verPy es anterior al mínimo 3.11 ($rutaPy)"
            $rutaPy = $null
        } else {
            $py = $rutaPy
        }
    }
}

if (-not $py -and -not $arreglo) {
    # Con el lanzador `py` disponible, Python SÍ está instalado: lo que falta es que `python` lo
    # resuelva en el PATH, que es lo único que sabe invocar `.mcp.json`. Distinguirlo ahorra una
    # reinstalación innecesaria.
    $lanzador = Invoke-Capturado "py" @("-3", "--version")
    if ($lanzador.codigo -eq 0 -and $lanzador.salida -match 'Python\s+3\.') {
        $arreglo = @(
            "Python está instalado ($($lanzador.salida)) pero 'python' no lo resuelve en el PATH, y el",
            "servidor MCP invoca literalmente 'python'. Reejecuta el instalador de Python con",
            "'Add python.exe to PATH' marcado, o añade su carpeta al PATH del usuario."
        ) -join "`n   "
    } else {
        $arreglo = @(
            "Instala Python 3.11+ desde https://www.python.org/downloads/windows/ marcando",
            "'Add python.exe to PATH'. Después: pip install ""mcp>=1.2.0,<2""."
        ) -join "`n   "
    }
}

# ── 2. ¿Está el paquete `mcp` y en la línea 1.x? ─────────────────────────────
# El paquete no expone `__version__` de forma fiable, así que la versión sale de los metadatos de
# instalación y es solo informativa: quien manda es el import real del submódulo que usa el servidor.
function Get-VersionMcp([string]$Exe) {
    $r = Invoke-Capturado $Exe @("-c", "import importlib.metadata as m,sys;sys.stdout.write(m.version('mcp'))")
    if ($r.codigo -eq 0 -and $r.salida) { return $r.salida }
    return "versión desconocida"
}

$verMcp = $null
if ($py) {
    # Sonda decisiva primero: es exactamente el import que hace `mcp/rs-workspace-server.py`. En el
    # camino bueno —el normal— basta un spawn.
    $f = Invoke-Capturado $py @("-c", "import mcp.server.fastmcp")
    if ($f.codigo -ne 0) {
        $r = Invoke-Capturado $py @("-c", "import mcp")
        if ($r.codigo -ne 0) {
            $motivo  = "el paquete Python 'mcp' no está instalado en $py"
            $arreglo = "pip install ""mcp>=1.2.0,<2""   (con el mismo python: & ""$py"" -m pip install ""mcp>=1.2.0,<2"")"
        } else {
            # El major 2.0.0 ELIMINÓ `mcp.server.fastmcp`. El paquete está, pero es el equivocado.
            $verMcp  = Get-VersionMcp $py
            $motivo  = "el paquete 'mcp' instalado ($verMcp) no expone 'mcp.server.fastmcp' — la línea 2.x lo eliminó"
            $arreglo = "pip install ""mcp>=1.2.0,<2""   (degrada a la línea 1.x, que es la que usa el servidor)"
        }
    } elseif (-not $Quiet) {
        $verMcp = Get-VersionMcp $py
    }
}

# ── 3. Reparación (solo a petición explícita) ────────────────────────────────
if ($Reparar -and $motivo) {
    if (-not $py) {
        Write-Output "⛔ No se puede reparar sin un Python usable: $motivo"
        Write-Output "   $arreglo"
        exit 0
    }
    Write-Output "Instalando mcp>=1.2.0,<2 en $py ..."
    $i = Invoke-Capturado $py @("-m", "pip", "install", "--upgrade", "mcp>=1.2.0,<2")
    Write-Output $i.salida
    if ($i.codigo -eq 0) {
        $f = Invoke-Capturado $py @("-c", "import mcp.server.fastmcp")
        if ($f.codigo -eq 0) {
            $motivo = $null
            $verMcp = Get-VersionMcp $py
            Write-Output "✅ Reparado: mcp $verMcp en $py"
            Write-Output "⚠️ REINICIA Claude Code — los servidores MCP se resuelven al arrancar."
        } else {
            Write-Output "⛔ pip terminó bien pero el import sigue fallando: $($f.salida)"
        }
    } else {
        Write-Output "⛔ pip falló (código $($i.codigo)). Ejecútalo a mano en una terminal."
    }
}

# ── 4. Informe ───────────────────────────────────────────────────────────────
if (-not $motivo) {
    try { Set-Content -Path $marcador -Value $version -Encoding UTF8 } catch { }
    if (-not $Quiet) {
        Write-Output "── RS Enterprise Agent — requisitos ──"
        Write-Output "  ✅ Python: $py"
        Write-Output "  ✅ Paquete mcp: $verMcp (línea 1.x, con mcp.server.fastmcp)"
    }
    exit 0
}

# Falta algo: el marcador se retira para que el aviso vuelva en la siguiente sesión.
if (Test-Path $marcador) { Remove-Item $marcador -Force -ErrorAction SilentlyContinue }

Write-Output "── RS Enterprise Agent — requisitos ──"
Write-Output "⛔ El servidor MCP 'rs-workspace' NO puede arrancar: $motivo"
Write-Output "   $arreglo"
Write-Output "   Después: reinicia Claude Code y comprueba con /rs-help (si responde, el MCP está vivo)."
Write-Output "   Mientras tanto el plugin funciona a medias: los comandos despachan, pero ninguna tool MCP responde."
if (-not $Reparar) {
    Write-Output "   Reparación asistida: /rs-env (te ofrecerá instalar el paquete) — no instala nada sin tu confirmación."
}
if ($Quiet) {
    Write-Output ""
    Write-Output "AVISO PARA CLAUDE: comunica esto al usuario en tu primera respuesta de la sesión, antes de nada más."
}
exit 0
