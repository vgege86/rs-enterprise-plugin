param(
    [string]$InputFile = ""
)

Write-Host "====================================="
Write-Host " RS ENTERPRISE RUNNER"
Write-Host "====================================="

# Localizar hooks/ relativo a este mismo script (portable, sin rutas hardcodeadas)
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot  = Split-Path -Parent $scriptDir
$hooksRoot  = Join-Path $skillRoot "hooks"

$content = $null

# =====================================
# MODO 1: InputFile (inline / manual)
# Prioridad alta: si se pasa -InputFile no leer stdin
# =====================================
if ($InputFile) {
    if (!(Test-Path $InputFile)) {
        Write-Host "ERROR: Input file not found: $InputFile"
        exit 1
    }
    Write-Host "Mode: InputFile"
    $content = Get-Content $InputFile -Raw
}

# =====================================
# MODO 2: Stop hook (stdin JSON con transcript_path)
# Solo si NO se pasó -InputFile
# =====================================
if (-not $content) {
    try {
        $stdinContent = $input | Out-String
        if ($stdinContent -and $stdinContent.Trim()) {
            $hookData = $stdinContent | ConvertFrom-Json
            $transcriptPath = $hookData.transcript_path
            if ($transcriptPath -and (Test-Path $transcriptPath)) {
                Write-Host "Mode: Stop hook (transcript)"
                $lastText = $null
                Get-Content $transcriptPath -Encoding UTF8 | ForEach-Object {
                    $line = $_.Trim()
                    if (-not $line) { return }
                    try {
                        $msg = $line | ConvertFrom-Json
                        if ($msg.role -eq "assistant") {
                            if ($msg.content -is [string]) { $lastText = $msg.content }
                            elseif ($msg.content -is [array]) {
                                foreach ($block in $msg.content) {
                                    if ($block.type -eq "text" -and $block.text) { $lastText = $block.text }
                                }
                            }
                        }
                    } catch {}
                }
                $content = $lastText
            }
        }
    } catch {}
}

if (-not $content -or -not $content.Trim()) {
    Write-Host "No input content found"
    exit 0
}

Write-Host "Analyzing agent output..."

# =====================================
# EXTRAER TYPE
# =====================================
if ($content -match "TYPE:\s*(.+)") {
    $type = $matches[1].Trim()
    Write-Host "Detected TYPE: $type"
} else {
    Write-Host "No executable TYPE found"
    exit 0
}

# =====================================
# EXTRAER COMMAND
# =====================================
if ($content -match "COMMAND:\s*(.+)") {
    $command = $matches[1].Trim()
    Write-Host "Detected COMMAND: $command"
} else {
    Write-Host "No COMMAND found"
    exit 0
}

# =====================================
# SEGURIDAD
# =====================================

# Resolver .\hooks\ relativo → hooks/ dentro de la skill (portable)
$command = $command -replace '\.[\\/]hooks[\\/]', "$hooksRoot\"

# Separar en: ruta del script (primer token .ps1) + resto = argumentos.
# El .ps1 puede ir entre comillas si contiene espacios.
if ($command -notmatch '^\s*"?(?<script>.+?\.ps1)"?(?:\s+(?<rest>.*))?$') {
    Write-Host "SECURITY BLOCK: No .ps1 script in COMMAND"
    exit 1
}
$scriptPath = $matches['script'].Trim()
$argString  = if ($matches['rest']) { $matches['rest'].Trim() } else { "" }

# Resolver a ruta absoluta y exigir que quede DENTRO de hooks/ (bloquea ..\ escape),
# que sea .ps1 y que exista realmente.
try {
    $fullScript = [System.IO.Path]::GetFullPath($scriptPath)
} catch {
    Write-Host "SECURITY BLOCK: Invalid script path"
    exit 1
}
$hooksRootFull = [System.IO.Path]::GetFullPath($hooksRoot)
if (-not $fullScript.StartsWith($hooksRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "SECURITY BLOCK: Script not inside skill hooks path"
    exit 1
}
if ($fullScript -notmatch '\.ps1$') {
    Write-Host "SECURITY BLOCK: Not a .ps1 script"
    exit 1
}
if (-not (Test-Path -LiteralPath $fullScript -PathType Leaf)) {
    Write-Host "SECURITY BLOCK: Script not found: $fullScript"
    exit 1
}

# Tokenizar argumentos respetando comillas → lista de literales.
$argList = @()
foreach ($m in [regex]::Matches($argString, '(?:"([^"]*)"|(\S+))')) {
    if ($m.Groups[1].Success) { $argList += $m.Groups[1].Value }
    else                      { $argList += $m.Groups[2].Value }
}

# Defensa en profundidad: bloquear tokens peligrosos en script o argumentos.
$allTokens = @($fullScript) + $argList
foreach ($tok in $allTokens) {
    if ($tok -match "\brm\b|\bdel\b|\bformat\b|\bshutdown\b|Remove-Item") {
        Write-Host "SECURITY BLOCK: Dangerous token detected"
        exit 1
    }
}

# =====================================
# EJECUCIÓN
# =====================================

Set-Location $skillRoot | Out-Null

Write-Host "Executing: $fullScript $($argList -join ' ')"
Write-Host "-------------------------------------"

try {
    # Call operator con lista de argumentos: todo tras el .ps1 es argumento LITERAL,
    # nunca PowerShell → sin inyección de comandos (;/|/&&). No se evalúa la cadena.
    & $fullScript @argList
    $exitCode = $LASTEXITCODE
    Write-Host "-------------------------------------"
    if ($exitCode -ne 0) {
        Write-Host "Execution FAILED with exit code: $exitCode"
        exit $exitCode
    }
    Write-Host "Execution completed successfully"
}
catch {
    Write-Host "-------------------------------------"
    Write-Host "Execution failed: $_"
    exit 1
}

Write-Host "Runner finished"
