<#
.SYNOPSIS
    Compila la solución y devuelve errores/warnings como JSON estructurado. Sustituye la validación
    heurística del LLM por salida real del compilador.

    El compilador se AUTODETECTA leyendo los proyectos de la .sln (hooks\lib-msbuild.ps1): MSBuild
    de Visual Studio si algún proyecto es .NET Framework / web / COM, CLI `dotnet` si todos son
    SDK-style modernos. No hay listas de nombres de solución ni de proceso: la decisión sale de lo
    que declara cada .csproj.

.PARAMETER SlnPath
    Ruta completa al archivo .sln

.PARAMETER NoRestore
    Si se especifica, omite restore de paquetes NuGet (más rápido, usar cuando restore ya se hizo)

.PARAMETER Builder
    auto (default) | dotnet | msbuild. Impone el compilador en vez de autodetectarlo.

.EXAMPLE
    .\compile-check.ps1 "C:\...\RSProcIN.sln"
    .\compile-check.ps1 "C:\...\RSProcIN.sln" -NoRestore
    .\compile-check.ps1 "C:\...\RSProcIN.sln" -Builder msbuild
#>
param(
    [Parameter(Mandatory=$true)][string]$SlnPath,
    [switch]$NoRestore,
    [ValidateSet('auto','dotnet','msbuild')][string]$Builder = 'auto'
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib-msbuild.ps1")

if (-not (Test-Path $SlnPath)) {
    @{ success = $false; error = "Archivo no encontrado: $SlnPath" } | ConvertTo-Json
    exit 1
}

# Qué compilador toca. Ver lib-msbuild.ps1: el CLI dotnet no compila .NET Framework, y forzarlo
# devolvía un falso "no compila" (MSB4019) sobre código correcto.
$toolchain = Get-RsBuildToolchain -SlnPath $SlnPath -Preferencia $Builder

# ⛔ Falta el compilador que hace falta -> se falla CERRADO y con el motivo, sin caer al otro en
# silencio. "No se ha podido verificar" y "no compila" son cosas distintas y el agente tiene que
# poder distinguirlas: builder_error existe exactamente para eso.
if ($toolchain.error) {
    @{
        success       = $false
        builder       = $toolchain.builder
        builder_error = $toolchain.error
        builder_reason = $toolchain.reason
        error_count   = 0
        warning_count = 0
        errors        = @()
        warnings      = @()
    } | ConvertTo-Json -Depth 4
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
    if ($toolchain.builder -eq 'msbuild') {
        # -v:minimal (no quiet): MSBuild en quiet suprime los warnings y el JSON saldría con
        # warning_count = 0 sin que nada fallara. -nodeReuse:false evita dejar procesos MSBuild
        # vivos reteniendo los binarios de la siguiente corrida.
        $buildArgs = @($SlnPath, "-t:Build", "-v:minimal", "-nologo", "-nodeReuse:false")
        if (-not $NoRestore) { $buildArgs = @("-restore") + $buildArgs }
    }
    else {
        $buildArgs = @("build", $SlnPath, "-v", "quiet", "--nologo")
        if ($NoRestore) { $buildArgs += "--no-restore" }
    }

    # Misma cautela que en test-runner-check.ps1: con $ErrorActionPreference = "Stop", cualquier
    # línea que el compilador escriba por stderr sería un error terminante y el hook moriría sin
    # JSON justo cuando hay algo que reportar. El veredicto lo da $LASTEXITCODE, no el stderr.
    $eapPrevio = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $raw = & $toolchain.builder_path @buildArgs 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $eapPrevio
}
finally {
    $env:DOTNET_CLI_UI_LANGUAGE = $idiomaPrevio
    $env:VSLANG = $vslangPrevio
}

# Parsear líneas de error/warning del compilador
# Formato con posición: <archivo>(<linea>,<col>): <severity> <CS####>: <mensaje> [<proyecto>]
# Formato sin posición:  <archivo|MSBUILD> : <severity> <MSB####>: <mensaje>
#
# ⛔ El código NO se limita a `CS####`. Los fallos de infraestructura del build salen como `MSB####`
# (MSB4019: falta un .targets), `NU####` (restore) o `MSB3644` (falta el targeting pack), y el
# patrón anterior los ignoraba: la solución no compilaba, exit_code era 1 y el JSON decía
# error_count = 0. Un fallo invisible se lee como "compila".
#
# La severidad traducida (advertencia/aviso) se acepta y se normaliza: el env var de arriba debería
# bastar, pero un SDK antiguo que lo ignore no puede volver a dejar los warnings en cero callando.
$diagnostics = @()
foreach ($line in $raw) {
    $texto = "$line"
    if ($texto -match '^(.+)\((\d+),(\d+)\):\s+(error|warning|advertencia|aviso)\s+([A-Za-z]+\d+):\s+(.+?)(\s+\[.+\])?$') {
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
    elseif ($texto -match '^(?:(.+?)\s*:\s*)?(error|warning|advertencia|aviso)\s+([A-Za-z]+\d+):\s+(.+?)(\s+\[.+\])?$') {
        $severidad = $Matches[2].ToLowerInvariant()
        if ($severidad -eq "advertencia" -or $severidad -eq "aviso") { $severidad = "warning" }
        $diagnostics += @{
            file     = if ($Matches[1]) { $Matches[1].Trim() } else { "" }
            line     = 0
            col      = 0
            severity = $severidad
            code     = $Matches[3]
            message  = $Matches[4].Trim()
        }
    }
}

$errors   = @($diagnostics | Where-Object { $_.severity -eq "error" })
$warnings = @($diagnostics | Where-Object { $_.severity -eq "warning" })

@{
    success        = ($exitCode -eq 0)
    exit_code      = $exitCode
    builder        = $toolchain.builder
    builder_path   = $toolchain.builder_path
    builder_reason = $toolchain.reason
    builder_forced = $toolchain.forced
    projects       = $toolchain.projects
    error_count    = $errors.Count
    warning_count  = $warnings.Count
    errors         = $errors
    warnings       = $warnings
    raw_lines      = if ($exitCode -ne 0 -and $diagnostics.Count -eq 0) { @($raw | Where-Object { $_ -match '\S' }) } else { @() }
} | ConvertTo-Json -Depth 4
