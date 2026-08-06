<#
.SYNOPSIS
    Informa de si la configuracion de los batch .NET Framework de un workspace esta CENTRALIZADA y,
    con -Aplicar, la centraliza.

    Centralizada = Batch\App.Batch.config + Batch\Directory.Build.targets, en lugar de un app.config
    por proyecto. Convencion completa: references\batch-config.md.

    ⛔ POR QUE IMPORTA (dos regresiones reales, ambas con el mismo sintoma final):
      1. Con app.config por proyecto, los bindingRedirects se mantienen A MANO y se desalinean del
         DLL desplegado -> FileLoadException en bucle -> StackOverflow al arrancar. Centralizado,
         MSBuild los GENERA en cada build con AutoGenerateBindingRedirects.
      2. Comun.dll no referencia System.Text.Json & cia en su IL: quien las usa es
         Oracle.ManagedDataAccess.dll. MSBuild sigue la cadena, no encuentra la version pedida en
         packages y DESCARTA la referencia SIN NINGUN WARNING -> el proceso muere en el primer
         acceso a BD con un TypeInitializationException de OracleCommand. El Directory.Build.targets
         las declara explicitamente con HintPath y <Private>true</Private>.
    Los dos los vigila el gate correspondiente de hooks\installer-batch.ps1.

    Modo informe (por defecto) NO escribe nada. Modo -Aplicar:
      - crea los dos ficheros desde assets\batch\*.tpl (no pisa los que ya existan),
      - retira el app.config de los proyectos CENTRALIZABLES (y su <None Include="app.config"/>),
      - respeta los proyectos EXCEPCION y los marcados REVISAR.

.PARAMETER workspace  Ruta trunk del proyecto (ej. C:\SVN\RS\<Proyecto>\trunk)
.PARAMETER Aplicar    Escribe los cambios. Sin el, solo informa.

.OUTPUTS
    JSON. status = OK | NEEDS_ACTION | BLOCKED
#>
param(
    [Parameter(Mandatory=$true)][string]$workspace,
    [switch]$Aplicar
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# Satelites de ODP.NET que DEBEN quedar declarados si. Comun.dll no los referencia en su IL, asi que
# sin declaracion explicita MSBuild los descarta en silencio. Los detectados en los csproj se anaden
# a esta base (un workspace puede arrastrar mas).
$odpRequeridas = @(
    'Oracle.ManagedDataAccess',
    'System.Text.Json',
    'System.Diagnostics.DiagnosticSource',
    'System.Text.Encodings.Web',
    'System.Collections.Immutable',
    'System.IO.Pipelines',
    'System.Formats.Asn1',
    'Microsoft.Bcl.AsyncInterfaces'
)

# Secciones de app.config que el mecanismo centralizado reproduce (App.Batch.config + los redirects
# que autogenera MSBuild). Cualquier otra seccion implica contenido propio que se perderia -> REVISAR.
$seccionesReproducibles = @('configSections','startup','runtime','system.data','oracle.manageddataaccess.client')

function Get-RelPath($desde, $hasta) {
    # [IO.Path]::GetRelativePath no existe en Windows PowerShell 5.1.
    $uDesde = New-Object System.Uri (($desde.TrimEnd('\') + '\'))
    $uHasta = New-Object System.Uri $hasta
    return [Uri]::UnescapeDataString($uDesde.MakeRelativeUri($uHasta).ToString()).Replace('/', '\')
}

function Write-TextPreservandoBom($path, $texto, $conBom) {
    [IO.File]::WriteAllText($path, $texto, (New-Object Text.UTF8Encoding $conBom))
}

function Test-TieneBom($path) {
    $b = [IO.File]::ReadAllBytes($path)
    return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

$salida = [ordered]@{
    workspace  = $workspace
    timestamp  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    aplicado   = [bool]$Aplicar
}
$avisos   = @()
$acciones = @()

if (!(Test-Path $workspace)) {
    $salida.status = "BLOCKED"; $salida.error = "workspace no encontrado: $workspace"
    $salida | ConvertTo-Json -Depth 6; exit 1
}
$proyecto = if ((Split-Path $workspace -Leaf) -eq 'trunk') { Split-Path (Split-Path $workspace -Parent) -Leaf } else { Split-Path $workspace -Leaf }
$salida.proyecto = $proyecto

$batchDir = Join-Path $workspace "Batch"
if (!(Test-Path $batchDir)) {
    $salida.status = "BLOCKED"; $salida.error = "no existe $batchDir — este workspace no tiene batch"
    $salida | ConvertTo-Json -Depth 6; exit 1
}

$appBatchConfig  = Join-Path $batchDir "App.Batch.config"
$dirBuildTargets = Join-Path $batchDir "Directory.Build.targets"
$salida.ficheros = [ordered]@{
    appBatchConfig       = [ordered]@{ path = $appBatchConfig;  existe = (Test-Path $appBatchConfig) }
    directoryBuildTargets= [ordered]@{ path = $dirBuildTargets; existe = (Test-Path $dirBuildTargets) }
}
$centralizado = (Test-Path $appBatchConfig) -and (Test-Path $dirBuildTargets)
$salida.centralizado = $centralizado

# ---------------------------------------------------------------------------------------------------
# 1. Proyectos bajo Batch\ y clasificacion de su app.config
# ---------------------------------------------------------------------------------------------------
$csprojs = @(Get-ChildItem $batchDir -Recurse -Filter *.csproj -ErrorAction SilentlyContinue)
$proyectos = @()
foreach ($cp in $csprojs) {
    $dir  = Split-Path $cp.FullName -Parent
    $acfg = @(Get-ChildItem $dir -File -Filter "app.config" -ErrorAction SilentlyContinue) | Select-Object -First 1

    $item = [ordered]@{
        csproj    = $cp.FullName
        nombre    = $cp.BaseName
        appConfig = if ($acfg) { $acfg.FullName } else { $null }
        clase     = "sin-app-config"
        motivos   = @()
    }
    if ($acfg) {
        $raw = Get-Content $acfg.FullName -Raw
        $motivos = @()
        # Excepcion legitima: lo que MSBuild NO puede autogenerar.
        if ($raw -match '<probing\b[^>]*privatePath')  { $motivos += "probing privatePath" }
        if ($raw -match 'loadFromRemoteSources')        { $motivos += "loadFromRemoteSources" }
        if ($motivos.Count -gt 0) {
            $item.clase = "excepcion"; $item.motivos = $motivos
        } else {
            # Secciones propias que se perderian al retirar el app.config.
            try {
                $xmlCfg = [xml]$raw
                $propias = @($xmlCfg.DocumentElement.ChildNodes |
                             Where-Object { $_.NodeType -eq 'Element' -and $seccionesReproducibles -notcontains $_.LocalName } |
                             ForEach-Object { $_.LocalName } | Select-Object -Unique)
                if ($propias.Count -gt 0) {
                    $item.clase = "revisar"; $item.motivos = @("secciones propias: $($propias -join ', ')")
                } else {
                    $item.clase = "centralizable"
                }
            } catch {
                $item.clase = "revisar"; $item.motivos = @("app.config ilegible: $($_.Exception.Message)")
            }
        }
    }
    $proyectos += [pscustomobject]$item
}
$salida.proyectos = @($proyectos | ForEach-Object { $_ })
$salida.resumen = [ordered]@{
    total         = $proyectos.Count
    sinAppConfig  = @($proyectos | Where-Object { $_.clase -eq 'sin-app-config' }).Count
    centralizable = @($proyectos | Where-Object { $_.clase -eq 'centralizable' }).Count
    excepcion     = @($proyectos | Where-Object { $_.clase -eq 'excepcion' }).Count
    revisar       = @($proyectos | Where-Object { $_.clase -eq 'revisar' }).Count
}

# ---------------------------------------------------------------------------------------------------
# 2. Dependencias ODP.NET: nombre -> HintPath resuelto desde los csproj que ya las referencian.
#    No se inventa ninguna ruta: si un assembly requerido no aparece con HintPath en el workspace,
#    queda como NO RESUELTO y -Aplicar se niega a escribir un .targets a medias.
# ---------------------------------------------------------------------------------------------------
$hintPorNombre = @{}
$csprojConOdp  = @()
foreach ($cp in $csprojs) {
    $raw = Get-Content $cp.FullName -Raw
    if ($raw -match 'Oracle\.ManagedDataAccess') { $csprojConOdp += $cp.FullName }
    foreach ($m in [regex]::Matches($raw, '<Reference\s+Include="([^",]+)[^"]*"\s*>\s*(.*?)</Reference>', 'Singleline,IgnoreCase')) {
        $nombre = $m.Groups[1].Value.Trim()
        $cuerpo = $m.Groups[2].Value
        $mh = [regex]::Match($cuerpo, '<HintPath>([^<]+)</HintPath>', 'IgnoreCase')
        if (-not $mh.Success) { continue }
        if ($hintPorNombre.ContainsKey($nombre)) { continue }
        try { $abs = [IO.Path]::GetFullPath((Join-Path (Split-Path $cp.FullName -Parent) $mh.Groups[1].Value.Trim())) } catch { continue }
        if (Test-Path $abs) { $hintPorNombre[$nombre] = $abs }
    }
}

# Candidatas = requeridas + las System.*/Microsoft.Bcl.* con HintPath en packages\ que ya usa el
# workspace (asi se recoge la cadena completa de ODP.NET sin inventar nombres).
$candidatas = New-Object System.Collections.Generic.List[string]
foreach ($n in $odpRequeridas) { if (-not $candidatas.Contains($n)) { [void]$candidatas.Add($n) } }
foreach ($n in $hintPorNombre.Keys) {
    if ($n -match '^(System\.|Microsoft\.Bcl\.)' -and $hintPorNombre[$n] -match '\\packages\\') {
        if (-not $candidatas.Contains($n)) { [void]$candidatas.Add($n) }
    }
}

$resueltas   = @()
$noResueltas = @()
foreach ($n in $candidatas) {
    if ($hintPorNombre.ContainsKey($n)) {
        $resueltas += [pscustomobject]@{ nombre = $n; hintPath = $hintPorNombre[$n] }
    } elseif ($odpRequeridas -contains $n) {
        $noResueltas += $n
    }
}
$salida.odp = [ordered]@{
    resueltas   = @($resueltas   | ForEach-Object { [ordered]@{ nombre = $_.nombre; hintPath = $_.hintPath } })
    noResueltas = @($noResueltas)
    csprojConOdp= @($csprojConOdp)
}
if ($noResueltas.Count -gt 0) {
    $avisos += "Sin HintPath en el workspace para: $($noResueltas -join ', '). Instala/restaura esos paquetes antes de centralizar."
}

# ---------------------------------------------------------------------------------------------------
# 3. Modo informe — sin -Aplicar no se escribe nada
# ---------------------------------------------------------------------------------------------------
if (-not $Aplicar) {
    $salida.avisos   = @($avisos)
    $salida.acciones = @()
    $salida.status   = if ($centralizado -and $salida.resumen.centralizable -eq 0) { "OK" } else { "NEEDS_ACTION" }
    $salida.siguiente= if ($salida.status -eq 'OK') { "nada que hacer" } else { "repetir con -Aplicar para centralizar" }
    $salida | ConvertTo-Json -Depth 6
    exit 0
}

# ---------------------------------------------------------------------------------------------------
# 4. -Aplicar — prerequisitos duros. Un .targets a medias es peor que no tenerlo: los assemblies que
#    falten los seguira descartando MSBuild en silencio.
# ---------------------------------------------------------------------------------------------------
if ($noResueltas.Count -gt 0) {
    $salida.avisos = @($avisos)
    $salida.status = "BLOCKED"
    $salida.error  = "no se puede centralizar: faltan HintPath para $($noResueltas -join ', ') — no se escribe nada."
    $salida | ConvertTo-Json -Depth 6
    exit 1
}

$assetsDir = Join-Path (Split-Path $PSScriptRoot -Parent) "assets\batch"
foreach ($t in @('App.Batch.config.tpl','Directory.Build.targets.tpl')) {
    if (!(Test-Path (Join-Path $assetsDir $t))) {
        $salida.status = "BLOCKED"; $salida.error = "plantilla no encontrada: $(Join-Path $assetsDir $t)"
        $salida | ConvertTo-Json -Depth 6; exit 1
    }
}

# Version y token reales del ODP.NET del workspace (no se hardcodean: varian por instalacion).
$odpDll = $hintPorNombre['Oracle.ManagedDataAccess']
try {
    $odpAsm   = [System.Reflection.AssemblyName]::GetAssemblyName($odpDll)
    $odpVer   = $odpAsm.Version.ToString()
    $odpToken = (($odpAsm.GetPublicKeyToken() | ForEach-Object { $_.ToString('x2') }) -join '')
} catch {
    $salida.status = "BLOCKED"
    $salida.error  = "no se pudo leer la identidad de $odpDll — $($_.Exception.Message)"
    $salida | ConvertTo-Json -Depth 6; exit 1
}
if (-not $odpToken) {
    $salida.status = "BLOCKED"; $salida.error = "Oracle.ManagedDataAccess sin PublicKeyToken en $odpDll"
    $salida | ConvertTo-Json -Depth 6; exit 1
}

# TargetFramework de los proyectos que usan ODP.NET (para el <supportedRuntime sku>).
$tfm = "v4.8"
foreach ($p in $csprojConOdp) {
    $mt = [regex]::Match((Get-Content $p -Raw), '<TargetFrameworkVersion>\s*(v[\d.]+)\s*</TargetFrameworkVersion>', 'IgnoreCase')
    if ($mt.Success) { $tfm = $mt.Groups[1].Value; break }
}
$salida.odp.version = $odpVer
$salida.odp.token   = $odpToken
$salida.odp.tfm     = $tfm

# --- 4a. App.Batch.config ---
if (Test-Path $appBatchConfig) {
    $acciones += "App.Batch.config ya existia — no se pisa"
} else {
    $tpl = Get-Content (Join-Path $assetsDir "App.Batch.config.tpl") -Raw -Encoding UTF8
    $tpl = $tpl.Replace('<ODP_VERSION>', $odpVer).Replace('<ODP_TOKEN>', $odpToken).Replace('<TFM>', $tfm)
    Write-TextPreservandoBom $appBatchConfig $tpl $true
    $acciones += "creado Batch\App.Batch.config (ODP $odpVer, $tfm)"
}

# --- 4b. Directory.Build.targets ---
if (Test-Path $dirBuildTargets) {
    $acciones += "Directory.Build.targets ya existia — no se pisa"
} else {
    $refs = @()
    foreach ($r in ($resueltas | Sort-Object nombre)) {
        $rel = Get-RelPath $batchDir $r.hintPath
        $refs += "    <Reference Include=`"$($r.nombre)`">"
        $refs += "      <HintPath>`$(MSBuildThisFileDirectory)$rel</HintPath>"
        $refs += "      <Private>true</Private>"
        $refs += "    </Reference>"
    }
    $tpl = Get-Content (Join-Path $assetsDir "Directory.Build.targets.tpl") -Raw -Encoding UTF8
    $tpl = $tpl.Replace('<!--REFERENCIAS-->', ($refs -join "`r`n"))
    Write-TextPreservandoBom $dirBuildTargets $tpl $true
    $acciones += "creado Batch\Directory.Build.targets ($($resueltas.Count) referencias ODP.NET)"
}

# --- 4c. Retirar el app.config de los proyectos CENTRALIZABLES (y su <None Include="app.config"/>) ---
foreach ($p in @($proyectos | Where-Object { $_.clase -eq 'centralizable' })) {
    Remove-Item $p.appConfig -Force
    $bom = Test-TieneBom $p.csproj
    $raw = [IO.File]::ReadAllText($p.csproj)
    # El salto de linea final es OPCIONAL: si el <None/> esta solo en su linea se come tambien la
    # indentacion y el salto; si va en la misma linea que otros elementos (csproj compactos), se
    # retira solo el elemento. Exigir el salto dejaba el <None/> intacto en el segundo caso.
    $nuevo = [regex]::Replace($raw, '[ \t]*<None\s+Include="[Aa]pp\.config"\s*(?:/>|>.*?</None>)[ \t]*(?:\r?\n)?', '', 'Singleline,IgnoreCase')
    if ($nuevo -ne $raw) {
        Write-TextPreservandoBom $p.csproj $nuevo $bom
        $acciones += "$($p.nombre): app.config retirado + <None Include=`"app.config`"/> eliminado del csproj"
    } else {
        $acciones += "$($p.nombre): app.config retirado (el csproj no lo declaraba)"
    }
}
foreach ($p in @($proyectos | Where-Object { $_.clase -eq 'excepcion' })) {
    $acciones += "$($p.nombre): app.config CONSERVADO — $($p.motivos -join '; ') (MSBuild no puede autogenerarlo)"
}
foreach ($p in @($proyectos | Where-Object { $_.clase -eq 'revisar' })) {
    $avisos += "$($p.nombre): app.config CONSERVADO y pendiente de revision — $($p.motivos -join '; ')"
}

$avisos += "Recompilar los batch para que MSBuild regenere cada bin\<Config>\<Exe>.exe.config con los bindingRedirects al dia."
$salida.avisos   = @($avisos)
$salida.acciones = @($acciones)
$salida.status   = if (@($proyectos | Where-Object { $_.clase -eq 'revisar' }).Count -gt 0) { "NEEDS_ACTION" } else { "OK" }
$salida | ConvertTo-Json -Depth 6
exit 0
