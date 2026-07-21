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
} else {
    foreach ($marcador in @("Batch\Soluciones", "OnLine\Soluciones", "OnLine\AISServiceManager", "docs\.rs-databases.json")) {
        if (Test-Path (Join-Path $cwd $marcador)) { $esWorkspaceRS = $true; break }
    }
}
if (-not $esWorkspaceRS) { exit 0 }

# .sln explícita, o comando /rs-*, o nombre de solución RS conocida
if ($prompt -match '(?i)\b[\w.-]+\.sln\b' -or $prompt -match '(?i)^/rs-') {
    Write-Output "El mensaje menciona una solución .sln en un workspace uCollect/RS. OBLIGATORIO: invocar la skill 'rs-enterprise-agent' (tool Skill) ANTES de cualquier otra acción. Patrón 'Solucion.sln - cambio' = pipeline completo; auditoría/ERD/idiomas/commit/etc. = modo directo correspondiente de la skill."
}
exit 0
