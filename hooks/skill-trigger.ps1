<#
.SYNOPSIS
    Hook UserPromptSubmit: si el prompt menciona una .sln (o solución RS) en un workspace RS,
    inyecta un recordatorio para invocar la skill rs-enterprise-agent.
    Registro en ~/.claude/settings.json → hooks.UserPromptSubmit.
#>
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
} catch { exit 0 }

$prompt = "$($payload.prompt)"
$cwd    = "$($payload.cwd)"

# Solo en workspaces uCollect/RS — evita falsos positivos en otros repos .NET.
# Detección estructural (no por ruta: cada instalación cuelga de una unidad/carpeta distinta).
# Override opcional: $env:RS_WORKSPACE_MATCH = regex contra la ruta del workspace.
$esWorkspaceRS = $false
if ($env:RS_WORKSPACE_MATCH) {
    $esWorkspaceRS = $cwd -match $env:RS_WORKSPACE_MATCH
} elseif ($cwd -and (Test-Path -LiteralPath $cwd -ErrorAction SilentlyContinue)) {
    # Fail-fast: si el cwd es lento/inaccesible (unidad de red caída), no bloquear el
    # UserPromptSubmit. Cada Test-Path corta con -ErrorAction SilentlyContinue.
    foreach ($marcador in @("Batch\Soluciones", "OnLine\Soluciones", "OnLine\AISServiceManager", "docs\.rs-databases.json")) {
        if (Test-Path -LiteralPath (Join-Path $cwd $marcador) -ErrorAction SilentlyContinue) { $esWorkspaceRS = $true; break }
    }
}
if (-not $esWorkspaceRS) { exit 0 }

# Solo por .sln explícita.
#
# El disparo por '^/rs-' que había aquí sobraba y desde 3.13.0 además estorba: cuando el usuario
# escribe un comando, Claude Code ya carga commands/rs-<x>.md, que dice literalmente a qué
# subagente despachar y con qué. Los comandos que necesitan la skill (los que resuelven una .sln,
# los que escriben, el pipeline) lo piden ellos mismos en su propio texto; los de solo lectura
# que no resuelven ruta declaran lo contrario ("⛔ Self-contained — do NOT invoke the skill",
# ~7k tokens de SKILL.md que no aportan nada a un despacho mecánico). Inyectar aquí un
# "OBLIGATORIO invocar la skill" para todo /rs-* pisaba esa decisión y contradecía al comando.
if ($prompt -match '(?i)\b[\w.-]+\.sln\b') {
    Write-Output "El mensaje menciona una solución .sln en un workspace uCollect/RS. OBLIGATORIO: invocar la skill 'rs-enterprise-agent' (tool Skill) ANTES de cualquier otra acción. Patrón 'Solucion.sln - cambio' = pipeline completo; auditoría/ERD/idiomas/commit/etc. = modo directo correspondiente de la skill."
}
exit 0
