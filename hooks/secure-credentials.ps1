<#
.SYNOPSIS
    Cifra en reposo (DPAPI, CurrentUser) los secretos del plugin que hoy están en texto plano:
    el Password de docs\.rs-databases.json y los tokens de ~/.claude/rs-jira-credentials.json y
    ~/.claude/rs-mantis-credentials.json. Idempotente (salta lo ya cifrado) y no imprime secretos.

.DESCRIPTION
    Sustituye el valor por `enc:<base64 del blob DPAPI>`. Los lectores (Unprotect-RsSecret en PS,
    _unprotect_secret en Python) descifran al vuelo; un valor sin el prefijo se trata como texto
    plano, así que ficheros ya migrados o mezclados siguen funcionando. ⛔ El secreto cifrado solo lo
    descifra la MISMA cuenta de Windows en la MISMA máquina.

.PARAMETER Workspace
    Ruta del workspace (trunk) para localizar docs\.rs-databases.json. Si se omite, no se toca la BD.

.PARAMETER SkipJira / .PARAMETER SkipMantis
    Omite el fichero de token correspondiente.

.EXAMPLE
    .\secure-credentials.ps1 -Workspace "C:\SVN\RS\<Proyecto>\trunk"
#>
param(
    [string]$Workspace = "",
    [switch]$SkipJira,
    [switch]$SkipMantis
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib-crypto.ps1")
. (Join-Path $PSScriptRoot "lib-dbconfig.ps1")

$result = [ordered]@{ success = $true; changed = @(); skipped = @(); errors = @() }

# --- 1) Password de la BD (docs\.rs-databases.json) ---
if ($Workspace) {
    try {
        $ws = Resolve-RsWorkspace $Workspace
        $dbPath = Join-Path $ws "docs\.rs-databases.json"
        if (Test-Path $dbPath) {
            $cfg = Get-Content $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $touched = 0
            foreach ($c in @($cfg.conexiones)) {
                $cadena = "$($c.cadena)"
                if (-not $cadena) { continue }
                # Reemplaza SOLO el valor de Password=... (hasta el ; o fin), si no está ya cifrado.
                $new = [regex]::Replace($cadena, '(?i)(Password\s*=\s*)([^;]*)', {
                    param($m)
                    $val = $m.Groups[2].Value
                    if ((-not $val) -or (Test-RsEncrypted $val)) { return $m.Value }
                    return $m.Groups[1].Value + (Protect-RsSecret $val)
                })
                if ($new -ne $cadena) { $c.cadena = $new; $touched++ }
            }
            if ($touched -gt 0) {
                ($cfg | ConvertTo-Json -Depth 10) | Set-Content $dbPath -Encoding UTF8
                $result.changed += "db: $touched conexión(es) cifradas en $dbPath"
            } else {
                $result.skipped += "db: nada que cifrar (ya cifrado o sin password) en $dbPath"
            }
        } else {
            $result.skipped += "db: no existe $dbPath"
        }
    } catch {
        $result.errors += "db: $($_.Exception.Message)"
    }
} else {
    $result.skipped += "db: sin -Workspace, no se toca la config BD"
}

# --- 2) Token de fichero JSON en ~/.claude (Jira / Mantis) ---
function Protect-TokenFile {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) { $script:result.skipped += "${Label}: no existe $Path"; return }
    try {
        $j = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $tok = "$($j.token)"
        if (-not $tok) { $script:result.skipped += "${Label}: sin token en $Path"; return }
        if (Test-RsEncrypted $tok) { $script:result.skipped += "${Label}: ya cifrado"; return }
        $j.token = Protect-RsSecret $tok
        ($j | ConvertTo-Json -Depth 10) | Set-Content $Path -Encoding UTF8
        $script:result.changed += "${Label}: token cifrado en $Path"
    } catch {
        $script:result.errors += "${Label}: $($_.Exception.Message)"
    }
}

if (-not $SkipJira)   { Protect-TokenFile (Join-Path $env:USERPROFILE ".claude\rs-jira-credentials.json")   "jira" }
if (-not $SkipMantis) { Protect-TokenFile (Join-Path $env:USERPROFILE ".claude\rs-mantis-credentials.json") "mantis" }

if ($result.errors.Count -gt 0) { $result.success = $false }
$result | ConvertTo-Json -Depth 5
