<#
.SYNOPSIS
    Compila la solución con dotnet build y devuelve errores/warnings como JSON estructurado.
    Sustituye la validación heurística del LLM por salida real del compilador.

.PARAMETER SlnPath
    Ruta completa al archivo .sln

.PARAMETER NoRestore
    Si se especifica, omite restore de paquetes NuGet (más rápido, usar cuando restore ya se hizo)

.EXAMPLE
    .\compile-check.ps1 "C:\...\RSProcIN.sln"
    .\compile-check.ps1 "C:\...\RSProcIN.sln" -NoRestore
#>
param(
    [Parameter(Mandatory=$true)][string]$SlnPath,
    [switch]$NoRestore
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

if (-not (Test-Path $SlnPath)) {
    @{ success = $false; error = "Archivo no encontrado: $SlnPath" } | ConvertTo-Json
    exit 1
}

# Verificar dotnet
if (-not (Get-Command "dotnet" -ErrorAction SilentlyContinue)) {
    @{ success = $false; error = "dotnet CLI no encontrado en PATH" } | ConvertTo-Json
    exit 1
}

# Idioma del compilador: con el CLI localizado, MSBuild/Roslyn emiten "advertencia CS0168" en vez
# de "warning CS0168" y el parseo de abajo perdía TODOS los warnings sin que nada fallara (los
# errores colaban de casualidad: en español la palabra se escribe igual). Mismo origen que el
# falso verde de test-runner-check.ps1 — ver hooks/lib-trx.ps1.
$idiomaPrevio = $env:DOTNET_CLI_UI_LANGUAGE
$vslangPrevio = $env:VSLANG
$env:DOTNET_CLI_UI_LANGUAGE = "en"
$env:VSLANG = "1033"

try {
    # Operador de llamada con array de argumentos (no Invoke-Expression sobre una cadena): así $SlnPath
    # se pasa como UN argumento literal y una ruta con comillas/`;` no puede romper el quoting e inyectar
    # comandos. Ver PSScriptAnalyzer PSAvoidUsingInvokeExpression (gate en CI).
    $dotnetArgs = @("build", $SlnPath, "-v", "quiet", "--nologo")
    if ($NoRestore) { $dotnetArgs += "--no-restore" }

    # Misma cautela que en test-runner-check.ps1: con $ErrorActionPreference = "Stop", cualquier
    # línea que dotnet escriba por stderr sería un error terminante y el hook moriría sin JSON
    # justo cuando hay algo que reportar. El veredicto lo da $LASTEXITCODE, no el stderr.
    $eapPrevio = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $raw = & dotnet @dotnetArgs 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $eapPrevio
}
finally {
    $env:DOTNET_CLI_UI_LANGUAGE = $idiomaPrevio
    $env:VSLANG = $vslangPrevio
}

# Parsear líneas de error/warning del compilador
# Formato: <archivo>(<linea>,<col>): <severity> <CS####>: <mensaje> [<proyecto>]
# La severidad traducida (advertencia/aviso) se acepta y se normaliza: el env var de arriba debería
# bastar, pero un SDK antiguo que lo ignore no puede volver a dejar los warnings en cero callando.
$diagnostics = @()
foreach ($line in $raw) {
    if ($line -match '^(.+)\((\d+),(\d+)\):\s+(error|warning|advertencia|aviso)\s+(CS\w+):\s+(.+?)(\s+\[.+\])?$') {
        $severidad = $Matches[4].ToLowerInvariant()
        if ($severidad -eq "advertencia" -or $severidad -eq "aviso") { $severidad = "warning" }
        $diagnostics += @{
            file     = $Matches[1].Trim()
            line     = [int]$Matches[2]
            col      = [int]$Matches[3]
            severity = $severidad
            code     = $Matches[5]
            message  = $Matches[6].Trim()
        }
    }
}

$errors   = @($diagnostics | Where-Object { $_.severity -eq "error" })
$warnings = @($diagnostics | Where-Object { $_.severity -eq "warning" })

@{
    success       = ($exitCode -eq 0)
    exit_code     = $exitCode
    error_count   = $errors.Count
    warning_count = $warnings.Count
    errors        = $errors
    warnings      = $warnings
    raw_lines     = if ($exitCode -ne 0 -and $diagnostics.Count -eq 0) { @($raw | Where-Object { $_ -match '\S' }) } else { @() }
} | ConvertTo-Json -Depth 4
