<#
.SYNOPSIS
    Decide con qué compilador hay que construir una .sln —el MSBuild real de Visual Studio o el
    CLI `dotnet`— leyendo los proyectos de la propia solución. Librería: dot-sourcear desde el
    hook que la necesite (hoy compile-check.ps1 y test-runner-check.ps1), no se invoca sola.

.DESCRIPTION
    ⛔ POR QUÉ EXISTE. `compile-check.ps1` y `test-runner-check.ps1` llamaban SIEMPRE al CLI
    `dotnet`. En un workspace mixto —web y procesos batch en .NET Framework, servicios y sus
    módulos en .NET moderno— eso falla en la mitad de las soluciones: el SDK de `dotnet` no trae
    `Microsoft.WebApplication.targets` ni sabe generar interops COM, así que revienta con MSB4019
    sobre código que compila perfectamente en Visual Studio. Y como el parser de diagnósticos solo
    reconocía `CS####`, el `MSB####` real quedaba invisible: `error_count = 0` con `exit_code = 1`.
    Resultado operativo: el validator daba "compilación no verificada" una y otra vez y el humano
    tenía que compilar a mano.

    La decisión NO puede depender de nombres de solución, de proyecto ni de rutas: un plugin
    genérico no sabe cómo se llaman los procesos de cada cliente, y una lista blanca envejece mal.
    Se decide por lo único que es un hecho verificable: lo que declara cada `.csproj`/`.vbproj`.

    Reparto de responsabilidades, igual que en lib-deploy-gates.ps1:
      - Aquí: DECIDIR. Estas funciones no imprimen ni terminan el proceso; devuelven el veredicto.
      - En el hook: EJECUTAR y PRESENTAR (armar la línea de comandos, emitir el JSON, exit).
    Así el detector se puede ejercitar contra .csproj de prueba en un temp, sin Visual Studio y sin
    workspace de cliente: tests\MsBuild.Tests.ps1.

    ⛔ Ante la duda, MSBuild. MSBuild de Visual Studio compila también los proyectos SDK-style; el
    CLI `dotnet` NO compila los de .NET Framework. Sobre-detectar cuesta unos segundos de arranque;
    infra-detectar devuelve un falso "no compila" sobre código correcto.
#>

# Cache de proceso: vswhere tarda ~200 ms y una misma corrida puede pedir el compilador dos veces
# (compile + test). No persiste entre invocaciones del hook, que es lo correcto: si el usuario
# instala Visual Studio a media sesión, la siguiente llamada lo encuentra.
$script:RsMsBuildPath = $null
$script:RsVsTestPath  = $null

# ---------------------------------------------------------------------------------------------------
# ¿El TFM declarado es .NET Framework?
#
# `v4.8`, `v3.5`  -> TargetFrameworkVersion, que solo existe en proyectos .NET Framework.
# `net48`, `net472`, `net40` -> TFM sin punto = .NET Framework.
# `net8.0`, `net10.0-windows`, `netstandard2.0`, `netcoreapp3.1` -> .NET moderno, lo compila dotnet.
#
# La distinción "sin punto" no es un truco frágil: es la regla oficial de nomenclatura de TFMs.
# net5+ SIEMPRE lleva la versión menor (`net5.0`), y .NET Framework NUNCA la lleva (`net48`).
# ---------------------------------------------------------------------------------------------------
function Test-RsTfmFramework {
    param([string]$Tfm)

    if ([string]::IsNullOrWhiteSpace($Tfm)) { return $false }

    # <TargetFrameworks> puede traer varios separados por ';': basta con que UNO sea Framework.
    foreach ($t in ($Tfm -split ';')) {
        $valor = $t.Trim()
        if (-not $valor) { continue }
        if ($valor -match '^(?i)v\d')      { return $true }
        if ($valor -match '^(?i)net\d+$')  { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------------------------------
# Lee UN proyecto y devuelve lo que declara. No juzga: solo constata.
# ---------------------------------------------------------------------------------------------------
function Get-RsProyectoInfo {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectPath,
        [string]$Nombre = ""
    )

    if (-not $Nombre) { $Nombre = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath) }

    $info = [ordered]@{
        name             = $Nombre
        project          = $ProjectPath
        exists           = $false
        sdk_style        = $false
        legacy           = $false
        target_framework = ""
        framework_full   = $false
        com              = $false
        web              = $false
    }

    if (-not (Test-Path -LiteralPath $ProjectPath)) { return [pscustomobject]$info }
    $info.exists = $true

    $xml = Get-Content -LiteralPath $ProjectPath -Encoding UTF8 -Raw
    if (-not $xml) { return [pscustomobject]$info }

    # SDK-style: <Project Sdk="Microsoft.NET.Sdk"> o el <Import Sdk="..."/> equivalente.
    $info.sdk_style = ($xml -match '(?i)<Project[^>]*\sSdk\s*=') -or ($xml -match '(?i)<Import[^>]*\sSdk\s*=')
    $info.legacy    = -not $info.sdk_style

    if     ($xml -match '(?i)<TargetFrameworks?>\s*([^<]+?)\s*</TargetFrameworks?>')          { $info.target_framework = $Matches[1] }
    elseif ($xml -match '(?i)<TargetFrameworkVersion>\s*([^<]+?)\s*</TargetFrameworkVersion>') { $info.target_framework = $Matches[1] }

    $info.framework_full = Test-RsTfmFramework -Tfm $info.target_framework

    # COMReference: informativo. Fuerza MSBuild solo a través de `legacy` (desde .NET 5 el SDK
    # moderno sí sabe generar interops COM en Windows, así que un SDK-style con COM no basta).
    $info.com = ($xml -match '(?i)<COMReference|<COMFileReference')

    # Proyecto web (WebForms/MVC clásico): el import de WebApplication.targets es la causa literal
    # del MSB4019, y el ProjectTypeGuid lo declara aunque el import venga por otra vía.
    $info.web = ($xml -match '(?i)Microsoft\.WebApplication\.targets') -or
                ($xml -match '(?i)\{349c5851-65df-11da-9384-00065b846f21\}')

    return [pscustomobject]$info
}

# ---------------------------------------------------------------------------------------------------
# Todos los proyectos de una .sln, ya resueltos a ruta absoluta.
#
# Se aceptan .csproj y .vbproj. Los .vdproj (Setup Projects) se ignoran a propósito: no los compila
# MSBuild —los construye devenv, ver hooks\service-build.ps1— y en un build de solución solo emiten
# un aviso de "no soportado" que no debe contaminar la decisión.
# ---------------------------------------------------------------------------------------------------
function Get-RsProyectosSln {
    param([Parameter(Mandatory=$true)][string]$SlnPath)

    $slnDir     = Split-Path -Parent $SlnPath
    $proyectos  = @()

    foreach ($linea in (Get-Content -LiteralPath $SlnPath -Encoding UTF8)) {
        if ($linea -notmatch 'Project\([^)]+\)\s*=\s*"([^"]+)",\s*"([^"]+\.(?:csproj|vbproj))"') { continue }
        $nombre = $Matches[1].Trim()
        $rel    = $Matches[2].Trim().Replace('/', '\')
        # GetFullPath normaliza los "..\" — Join-Path solo concatena y dejaría rutas sin resolver.
        $ruta   = [System.IO.Path]::GetFullPath((Join-Path $slnDir $rel))
        $proyectos += (Get-RsProyectoInfo -ProjectPath $ruta -Nombre $nombre)
    }

    return ,@($proyectos)
}

# ---------------------------------------------------------------------------------------------------
# Localiza el MSBuild real de Visual Studio. Devuelve la ruta o $null (nunca lanza).
#
# `-products *` es deliberado: una máquina de build con solo Build Tools instalado no tiene ninguno
# de los productos que vswhere devuelve por defecto, y sin ese argumento saldría vacía en silencio.
#
# ⛔ `-sort`, NO `-latest`. `-products *` mete en el saco a todo lo que se instala sobre el shell de
# Visual Studio —SSMS, por ejemplo— y `-latest` se queda con UNA instancia, la de versión más alta:
# en una máquina con SSMS 22 y VS 2022 elegía SSMS, que no trae vstest.console, y el hook concluía
# "no está instalado" con Visual Studio delante. Con `-sort` vswhere devuelve TODAS las instancias
# ordenadas de más nueva a más antigua y `-find` filtra solas las que no tienen el fichero.
# ---------------------------------------------------------------------------------------------------
function Find-RsMsBuild {
    if ($script:RsMsBuildPath) { return $script:RsMsBuildPath }

    foreach ($vswhere in (Get-RsVsWherePaths)) {
        try {
            $ruta = & $vswhere -products * -sort -requires Microsoft.Component.MSBuild `
                        -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null | Select-Object -First 1
        }
        catch { $ruta = $null }
        if ($ruta -and (Test-Path -LiteralPath $ruta)) {
            $script:RsMsBuildPath = $ruta
            return $ruta
        }
    }

    # Developer Command Prompt: msbuild.exe ya viene en el PATH.
    $enPath = Get-Command 'msbuild.exe' -ErrorAction SilentlyContinue
    if ($enPath) {
        $script:RsMsBuildPath = $enPath.Source
        return $script:RsMsBuildPath
    }

    return $null
}

# ---------------------------------------------------------------------------------------------------
# Localiza vstest.console.exe (el runner que sí ejecuta tests de .NET Framework). $null si no hay.
# ---------------------------------------------------------------------------------------------------
function Find-RsVsTestConsole {
    if ($script:RsVsTestPath) { return $script:RsVsTestPath }

    foreach ($vswhere in (Get-RsVsWherePaths)) {
        try {
            $ruta = & $vswhere -products * -sort `
                        -find 'Common7\IDE\CommonExtensions\Microsoft\TestWindow\vstest.console.exe' 2>$null |
                        Select-Object -First 1
        }
        catch { $ruta = $null }
        if ($ruta -and (Test-Path -LiteralPath $ruta)) {
            $script:RsVsTestPath = $ruta
            return $ruta
        }
    }

    $enPath = Get-Command 'vstest.console.exe' -ErrorAction SilentlyContinue
    if ($enPath) {
        $script:RsVsTestPath = $enPath.Source
        return $script:RsVsTestPath
    }

    return $null
}

# ---------------------------------------------------------------------------------------------------
# Ensamblado ya compilado de un proyecto de test. `vstest.console.exe` no acepta un .csproj: hay que
# darle el .dll. $null si no se encuentra —normalmente porque nunca se compiló—, y quien llama debe
# tratarlo como ausencia de evidencia, nunca como "no hay tests que fallen".
#
# Se coge el MÁS RECIENTE: bin\Debug y bin\Release conviven, y el que refleja el código de ahora es
# el último escrito, no el que salga primero por orden alfabético.
# ---------------------------------------------------------------------------------------------------
function Get-RsTestAssembly {
    param([Parameter(Mandatory=$true)][string]$ProjectPath)

    if (-not (Test-Path -LiteralPath $ProjectPath)) { return $null }

    $nombre = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
    $xml    = Get-Content -LiteralPath $ProjectPath -Encoding UTF8 -Raw
    if ($xml -and $xml -match '(?i)<AssemblyName>\s*([^<]+?)\s*</AssemblyName>') { $nombre = $Matches[1] }

    $binDir = Join-Path (Split-Path -Parent $ProjectPath) 'bin'
    if (-not (Test-Path -LiteralPath $binDir)) { return $null }

    $dll = Get-ChildItem -LiteralPath $binDir -Recurse -Filter "$nombre.dll" -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($dll) { return $dll.FullName }
    return $null
}

function Get-RsVsWherePaths {
    return @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Join-Path $env:ProgramFiles        'Microsoft Visual Studio\Installer\vswhere.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
}

# ---------------------------------------------------------------------------------------------------
# EL VEREDICTO. Devuelve un hashtable con qué compilador usar, por qué, y el error si el que hace
# falta no está instalado.
#
#   builder          'msbuild' | 'dotnet'
#   builder_path     ruta a MSBuild.exe, o 'dotnet'; $null si falta
#   requires_msbuild $true si algún proyecto NO lo puede construir el CLI dotnet
#   reason           frase con los proyectos concretos que lo obligan (para el JSON del hook)
#   forced           el llamante impuso el compilador (-Builder), no se autodetectó
#   projects         lo leído de cada proyecto, para diagnóstico
#   error            $null, o el motivo por el que NO se puede compilar en esta máquina
#
# ⛔ `error` != "el código no compila". Es "no se ha podido verificar". El hook debe distinguirlo:
# reportarlo como fallo de compilación sería peor que no comprobar nada.
# ---------------------------------------------------------------------------------------------------
function Get-RsBuildToolchain {
    param(
        [Parameter(Mandatory=$true)][string]$SlnPath,
        [ValidateSet('auto','dotnet','msbuild')][string]$Preferencia = 'auto'
    )

    $proyectos = @(Get-RsProyectosSln -SlnPath $SlnPath)
    $legibles  = @($proyectos | Where-Object { $_.exists })
    $motivos   = @()

    foreach ($p in $legibles) {
        if ($p.framework_full)     { $motivos += "$($p.name): TFM '$($p.target_framework)' (.NET Framework)" }
        elseif ($p.legacy)         { $motivos += "$($p.name): .csproj en formato antiguo (no SDK-style)" }
        if ($p.web)                { $motivos += "$($p.name): proyecto web (Microsoft.WebApplication.targets)" }
        if ($p.com -and $p.legacy) { $motivos += "$($p.name): COMReference" }
    }
    $motivos  = @($motivos | Select-Object -Unique)
    $requiere = $motivos.Count -gt 0

    $builder = if ($Preferencia -eq 'auto') { if ($requiere) { 'msbuild' } else { 'dotnet' } } else { $Preferencia }

    if ($requiere) {
        # Cap a 5: con una solución de 30 proyectos Framework la lista sería ruido en el contexto.
        $muestra = @($motivos | Select-Object -First 5) -join '; '
        if ($motivos.Count -gt 5) { $muestra += " (y $($motivos.Count - 5) más)" }
        $reason = "MSBuild de Visual Studio — $muestra"
    }
    elseif ($legibles.Count -eq 0) {
        $reason = "No se pudo leer ningún proyecto de la solución; se asume el CLI dotnet"
    }
    else {
        $reason = "CLI dotnet — todos los proyectos ($($legibles.Count)) son SDK-style con TFM .NET moderno"
    }

    $resultado = [ordered]@{
        builder            = $builder
        builder_path       = $null
        requires_msbuild   = $requiere
        reason             = $reason
        forced             = ($Preferencia -ne 'auto')
        projects_unreadable = @($proyectos | Where-Object { -not $_.exists }).Count
        projects           = @($proyectos | ForEach-Object {
            [ordered]@{
                name             = $_.name
                target_framework = $_.target_framework
                sdk_style        = $_.sdk_style
                web              = $_.web
                com              = $_.com
                exists           = $_.exists
            }
        })
        error              = $null
    }

    if ($builder -eq 'msbuild') {
        $ruta = Find-RsMsBuild
        if ($ruta) {
            $resultado.builder_path = $ruta
        }
        else {
            $resultado.error = "Esta solución necesita el MSBuild de Visual Studio ($reason) y no se ha encontrado " +
                               "en esta máquina: ni vswhere.exe en 'Microsoft Visual Studio\Installer', ni msbuild.exe " +
                               "en el PATH. Instala Visual Studio (o Build Tools con la carga de trabajo de MSBuild), " +
                               "o ejecuta desde un Developer Command Prompt. ⛔ La compilación NO se ha verificado: " +
                               "esto es un problema de entorno, NO un fallo del código."
        }
    }
    else {
        $enPath = Get-Command 'dotnet' -ErrorAction SilentlyContinue
        if ($enPath) {
            $resultado.builder_path = $enPath.Source
        }
        else {
            $resultado.error = "dotnet CLI no encontrado en PATH. ⛔ La compilación NO se ha verificado: " +
                               "problema de entorno, NO un fallo del código."
        }
    }

    return $resultado
}
