<#
.SYNOPSIS
    Comprueba que la copia del plugin que se EJECUTA coincide con la fuente de la que dice venir.

.DESCRIPTION
    El plugin se ejecuta desde el cache:

        ~\.claude\plugins\cache\rs-enterprise-agent\rs-enterprise-agent\<version>\

    NO desde `~\.claude\plugins\marketplaces\rs-enterprise-agent\`, que es el checkout git de
    donde sale. Los dos árboles son copias independientes y nada los mantiene sincronizados
    salvo `/plugin marketplace update`. Editar la fuente y no actualizar deja el plugin
    corriendo la versión anterior; editar el cache directamente deja el arreglo fuera de git y
    lo borra la siguiente actualización.

    ⛔ Por qué existe esto y no basta con acordarse. Pasó de verdad: un arreglo del script de
    instalación que viaja al cliente se aplicó en la fuente y se copió al cache A MANO, fichero
    a fichero. Se copiaron nueve de diez. El que se quedó atrás fue el de tests, así que el
    cache ejecutaba el código corregido contra la suite vieja — incluido el test que fijaba el
    bug que se acababa de arreglar. Todo daba verde y nada era cierto. Una sincronización
    manual no se olvida "si se tiene cuidado": se olvida.

    QUÉ COMPRUEBA, EN ORDEN

    1. Que la `version` de `plugin.json` del cache y de la fuente coincidan. Si no, el cache
       está entero desfasado y sobra comparar fichero a fichero.
    2. Fichero a fichero, por hash SHA-256, en las carpetas que el plugin ejecuta. Se comparan
       los bytes normalizando el fin de línea: git puede materializar CRLF en un árbol y LF en
       el otro sin que eso sea una diferencia real.

    Lo que NO hace: copiar nada. Sincronizar es cosa de `/plugin marketplace update`, y hacerlo
    por debajo dejaría el cache en un estado que Claude Code no sabe que existe.

    Sale SIEMPRE por 0 en modo -Quiet: es un aviso de arranque, no un gate. Sin -Quiet devuelve
    1 si hay desajuste, para poder encadenarlo en la verificación de /rs-plugin-dev.

.PARAMETER Fuente
    Checkout del plugin con el que comparar. Por defecto,
    `~\.claude\plugins\marketplaces\rs-enterprise-agent`.

.PARAMETER Cache
    Copia en ejecución. Por defecto, la carpeta del propio script (que ES el cache cuando lo
    lanza el hook de SessionStart).

.PARAMETER Quiet
    Modo hook: sin salida si todo cuadra, y exit 0 pase lo que pase.

.EXAMPLE
    .\verificar-sync.ps1 -Quiet
.EXAMPLE
    .\verificar-sync.ps1
#>
param(
    [string]$Fuente = "",
    [string]$Cache  = "",
    [switch]$Quiet
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# Carpetas que el plugin EJECUTA o carga. `docs/` y los .docx quedan fuera a propósito: pesan,
# cambian por otras razones y una diferencia ahí no altera lo que hace el plugin.
$CARPETAS = @('agents','commands','hooks','scripts','skills','references','assets','mcp','runner','tests')

function Get-RsHashNormalizado {
    <#  SHA-256 del contenido con los fines de línea normalizados a LF.

        Sin normalizar, un árbol materializado con CRLF y otro con LF darían distinto en todos
        los ficheros de texto y el informe sería inútil. Los binarios se comparan tal cual: si
        no decodifican como UTF-8 se usan los bytes.  #>
    param([string]$Ruta)
    $bytes = [System.IO.File]::ReadAllBytes($Ruta)
    try {
        $estricto = [System.Text.UTF8Encoding]::new($false, $true)
        $txt   = $estricto.GetString($bytes).Replace("`r`n", "`n")
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($txt)
    } catch {
        # Binario (o no UTF-8): se compara byte a byte, que es lo correcto para un .docx o un .png.
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-RsVersionPlugin {
    param([string]$Raiz)
    $f = Join-Path $Raiz ".claude-plugin\plugin.json"
    if (!(Test-Path $f)) { return "" }
    try { return "$((Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json).version)" } catch { return "" }
}

function Get-RsInventarioArbol {
    <#  {ruta relativa -> hash} de las carpetas que importan. Devuelve $null si la raíz no
        existe, que es distinto de "existe y está vacía".  #>
    param([string]$Raiz, [string[]]$Carpetas)
    if (!(Test-Path $Raiz)) { return $null }
    $inv = @{}
    foreach ($c in $Carpetas) {
        $dir = Join-Path $Raiz $c
        if (!(Test-Path $dir)) { continue }
        foreach ($f in (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue)) {
            # __pycache__ lo genera Python al ejecutar: diferir ahí no significa nada.
            if ($f.FullName -match '\\__pycache__\\') { continue }
            $rel = $f.FullName.Substring($Raiz.Length).TrimStart('\','/')
            $inv[$rel] = Get-RsHashNormalizado -Ruta $f.FullName
        }
    }
    return $inv
}

# --- Resolver las dos raíces ----------------------------------------------
if (-not $Cache)  { $Cache  = Split-Path $PSScriptRoot -Parent }
if (-not $Fuente) { $Fuente = Join-Path $env:USERPROFILE ".claude\plugins\marketplaces\rs-enterprise-agent" }

if (!(Test-Path $Fuente)) {
    # Instalación normal de un tercero: no hay checkout de la fuente, no hay nada que comparar.
    if (-not $Quiet) { Write-Host "No hay checkout de la fuente en $Fuente - nada que comparar." }
    exit 0
}
if ((Resolve-Path $Fuente).Path -eq (Resolve-Path $Cache).Path) {
    if (-not $Quiet) { Write-Host "Fuente y copia en ejecucion son la misma carpeta - nada que comparar." }
    exit 0
}

$vFuente = Get-RsVersionPlugin -Raiz $Fuente
$vCache  = Get-RsVersionPlugin -Raiz $Cache

# --- 1. Versión ------------------------------------------------------------
if ($vFuente -and $vCache -and $vFuente -ne $vCache) {
    Write-Host "AVISO RS: el plugin en ejecucion es la $vCache y la fuente ya va por la $vFuente."
    Write-Host "          Ejecuta '/plugin marketplace update rs-enterprise-agent' y reinicia Claude Code."
    Write-Host "          Hasta entonces los hooks y scripts que se ejecuten seran los de la $vCache."
    exit $(if ($Quiet) { 0 } else { 1 })
}

# --- 2. Fichero a fichero --------------------------------------------------
$invF = Get-RsInventarioArbol -Raiz $Fuente -Carpetas $CARPETAS
$invC = Get-RsInventarioArbol -Raiz $Cache  -Carpetas $CARPETAS

$distintos = @(); $soloFuente = @(); $soloCache = @()
foreach ($k in $invF.Keys) {
    if (-not $invC.ContainsKey($k)) { $soloFuente += $k }
    elseif ($invC[$k] -ne $invF[$k]) { $distintos += $k }
}
foreach ($k in $invC.Keys) { if (-not $invF.ContainsKey($k)) { $soloCache += $k } }

$total = $distintos.Count + $soloFuente.Count + $soloCache.Count

if ($total -eq 0) {
    if (-not $Quiet) {
        Write-Host "OK - la copia en ejecucion coincide con la fuente ($vCache, $($invF.Count) ficheros)."
    }
    exit 0
}

Write-Host "AVISO RS: la copia del plugin que se EJECUTA no coincide con su fuente ($total fichero(s))."
Write-Host "          En ejecucion: $Cache"
Write-Host "          Fuente      : $Fuente"
if ($distintos.Count -gt 0) {
    Write-Host "          $($distintos.Count) con contenido distinto:"
    foreach ($f in ($distintos | Sort-Object | Select-Object -First 15)) { Write-Host "            $f" }
    if ($distintos.Count -gt 15) { Write-Host "            ... y $($distintos.Count - 15) mas" }
}
if ($soloFuente.Count -gt 0) {
    Write-Host "          $($soloFuente.Count) que estan en la fuente y NO se ejecutan:"
    foreach ($f in ($soloFuente | Sort-Object | Select-Object -First 10)) { Write-Host "            $f" }
    if ($soloFuente.Count -gt 10) { Write-Host "            ... y $($soloFuente.Count - 10) mas" }
}
if ($soloCache.Count -gt 0) {
    # Editado directamente en el cache: fuera de git y condenado a desaparecer en la siguiente
    # actualizacion. Es el caso que mas caro sale, porque el arreglo existe y funciona.
    Write-Host "          $($soloCache.Count) que se ejecutan y NO estan en la fuente (se perderan al actualizar):"
    foreach ($f in ($soloCache | Sort-Object | Select-Object -First 10)) { Write-Host "            $f" }
    if ($soloCache.Count -gt 10) { Write-Host "            ... y $($soloCache.Count - 10) mas" }
}
Write-Host "          Ejecuta '/plugin marketplace update rs-enterprise-agent' y reinicia Claude Code."
Write-Host "          Si el cambio esta solo en el cache, llevalo antes a la fuente y commitealo."

exit $(if ($Quiet) { 0 } else { 1 })
