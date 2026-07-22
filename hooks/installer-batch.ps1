<#
.SYNOPSIS
    Instalador — recompila (Rebuild, no incremental) los procesos batch ACTIVOS del cliente desde
    un único snapshot de fuente y copia sus ejecutables a <destino>\EXES.

    Lista de procesos activos = docs\<proyecto>-instalador.json → campo "batch" (array de
    nombres de .sln sin extensión, bajo Batch\Soluciones\).

    ⛔ POR QUÉ Rebuild + wipe + gate (regresión real B2Impact, StackOverflow al arrancar):
    con `dotnet build` incremental por-sln quedaban DLLs compartidas (Comun/BusComun/RSModel) de
    un build anterior junto a exes recompilados de otro día. Las DLLs no tienen strong-name y su
    AssemblyVersion es 1.0.* → el CLR enlaza por nombre simple → un exe viejo llama a un método con
    firma cambiada → recursión infinita → StackOverflowException. Además `dotnet build` de una .sln
    con proyecto de Tests (p.ej. RsExtrae.Tests) fallaba y dejaba el .exe sin actualizar = el
    straggler exacto observado. Aquí: se compilan los csproj-exe con msbuild /t:Rebuild (el Tests
    queda fuera), previo wipe de todos los bin/obj del scope, y un gate final verifica que TODOS los
    .exe + DLLs compartidas desplegados son de ESTE build (nada de otra fecha).

.PARAMETER workspace  Ruta trunk del proyecto (ej. C:\SVN\RS\<Proyecto>\trunk)
.PARAMETER destino    Carpeta Instalador (ej. C:\AIS\<Proyecto>\Instalador)
#>
param(
    [Parameter(Mandatory=$true)][string]$workspace,
    [Parameter(Mandatory=$true)][string]$destino
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# Proyecto = carpeta anterior a trunk (o la propia si no es trunk)
$proyecto = if ((Split-Path $workspace -Leaf) -eq 'trunk') { Split-Path (Split-Path $workspace -Parent) -Leaf } else { Split-Path $workspace -Leaf }
$jsonPath = Join-Path $workspace "docs\$proyecto-instalador.json"

if (!(Test-Path $jsonPath)) {
    Write-Host "ERROR: Config no encontrada: $jsonPath"
    exit 1
}
$cfg = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$batch = @($cfg.batch)
if ($batch.Count -eq 0) {
    Write-Host "AVISO: no hay procesos batch activos en el JSON — nada que compilar."
    exit 0
}

# DLLs compartidas que se enlazan por nombre simple y provocan frankenbuilds si quedan de otro build.
# Override por JSON (sharedAssemblies); default = las tres del stack RS.
$sharedAssemblies = if ($cfg.sharedAssemblies) { @($cfg.sharedAssemblies) } else { @('Comun','BusComun','RSModel') }

# --- Localizar msbuild via vswhere (VS2022; no está en PATH) — mismo patrón que installer-agendaweb ---
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (!(Test-Path $vswhere)) { Write-Host "ERROR: vswhere no encontrado en $vswhere"; exit 1 }
$msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
if (!$msbuild -or !(Test-Path $msbuild)) { Write-Host "ERROR: msbuild no encontrado via vswhere"; exit 1 }
Write-Host "msbuild: $msbuild"

$exesDir = Join-Path $destino "EXES"
New-Item -ItemType Directory -Path $exesDir -Force | Out-Null

Write-Host "== Instalador BATCH — $($batch.Count) procesos =="
$fallos = @()

# ---------------------------------------------------------------------------------------------------
# Paso A — Resolver csproj de cada .sln. Separar csproj-exe (a compilar) de librerías (arrastradas).
# ---------------------------------------------------------------------------------------------------
function Get-CsprojFromSln($slnPath) {
    $slnDir = Split-Path $slnPath -Parent
    $refs = Select-String -Path $slnPath -Pattern '"([^"]+\.csproj)"' -AllMatches |
            ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    $out = @()
    foreach ($rel in $refs) {
        $abs = [System.IO.Path]::GetFullPath((Join-Path $slnDir $rel))
        if (Test-Path $abs) { $out += $abs }
    }
    return $out
}

function Test-IsExeCsproj($csproj) {
    $c = Get-Content $csproj -Raw
    return ($c -match '<OutputType>\s*(Exe|WinExe)\s*</OutputType>')
}

# Mapa: sln -> csproj-exe a compilar; y conjunto global de todos los csproj del scope (para wipe/HintPath)
$exeCsprojBySln = @{}
$allCsproj = New-Object System.Collections.Generic.HashSet[string]
foreach ($sln in $batch) {
    $slnPath = Join-Path $workspace "Batch\Soluciones\$sln.sln"
    if (!(Test-Path $slnPath)) {
        Write-Host "ERROR: .sln no encontrada: $slnPath"
        $fallos += $sln; continue
    }
    $csprojs = Get-CsprojFromSln $slnPath
    foreach ($cp in $csprojs) { [void]$allCsproj.Add($cp) }

    $exeCps = @($csprojs | Where-Object { Test-IsExeCsproj $_ })
    if ($exeCps.Count -eq 0) {
        # Fallback: csproj cuyo nombre coincide con la .sln
        $exeCps = @($csprojs | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) -eq $sln })
    }
    if ($exeCps.Count -eq 0) {
        Write-Host "ERROR: no se identificó ningún csproj-exe en $sln (¿solo librerías/Tests?)"
        $fallos += $sln; continue
    }
    $exeCsprojBySln[$sln] = $exeCps
}

# ---------------------------------------------------------------------------------------------------
# Paso B — AVISO trampa estructural: <Reference><HintPath>..\bin\Debug\X.dll de un proyecto cuya
#          fuente (X.csproj) está en el workspace → se enlaza contra una DLL de otro build en vez de
#          usar <ProjectReference>. Corregido en B2Impact r14970; aquí solo se avisa (advisory).
# ---------------------------------------------------------------------------------------------------
$wsCsprojNames = New-Object System.Collections.Generic.HashSet[string]
Get-ChildItem $workspace -Recurse -Filter *.csproj -ErrorAction SilentlyContinue |
    ForEach-Object { [void]$wsCsprojNames.Add($_.BaseName) }

$hintPathAvisos = @()
foreach ($cp in $allCsproj) {
    $content = Get-Content $cp -Raw
    $matchesHint = [regex]::Matches($content, '<HintPath>([^<]*bin\\Debug[^<]*\.dll)</HintPath>', 'IgnoreCase')
    foreach ($m in $matchesHint) {
        $dll = [System.IO.Path]::GetFileNameWithoutExtension($m.Groups[1].Value)
        if ($wsCsprojNames.Contains($dll)) {
            $hintPathAvisos += "  $([System.IO.Path]::GetFileName($cp)) -> HintPath a bin\Debug de '$dll' (existe $dll.csproj en el workspace)"
        }
    }
}
if ($hintPathAvisos.Count -gt 0) {
    Write-Host ""
    Write-Host "AVISO ⚠ trampa estructural HintPath a bin\Debug (usar <ProjectReference>, no <Reference><HintPath>):"
    $hintPathAvisos | Select-Object -Unique | ForEach-Object { Write-Host $_ }
    Write-Host "  -> estos proyectos pueden enlazar contra una DLL de otro build (riesgo de frankenbuild)."
}

# ---------------------------------------------------------------------------------------------------
# Paso C — WIPE de todos los bin/obj del scope (una sola pasada) → snapshot único, sin restos previos.
# ---------------------------------------------------------------------------------------------------
Write-Host "`n-- Wipe bin/obj del scope ($($allCsproj.Count) proyectos) --"
foreach ($cp in $allCsproj) {
    $dir = Split-Path $cp -Parent
    foreach ($sub in @('bin','obj')) {
        $p = Join-Path $dir $sub
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Marca temporal del build: todo lo desplegado debe ser >= este instante (gate de coherencia).
$buildStart = Get-Date
Write-Host "Build snapshot: $($buildStart.ToString('yyyy-MM-dd HH:mm:ss'))"

# ---------------------------------------------------------------------------------------------------
# Paso D — Compilar los csproj-exe con msbuild /t:Rebuild (arrastra sus ProjectReference; el Tests
#          queda fuera). Localizar el .exe producido y copiarlo a EXES.
# ---------------------------------------------------------------------------------------------------
foreach ($sln in ($exeCsprojBySln.Keys | Sort-Object)) {
    Write-Host "`n--- $sln ---"
    $ok = $true
    foreach ($csproj in $exeCsprojBySln[$sln]) {
        Write-Host "Rebuild: $([System.IO.Path]::GetFileName($csproj))"
        & "$msbuild" "$csproj" /t:Rebuild /p:Configuration=Release /p:VisualStudioVersion=17.0 /verbosity:minimal /nologo
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Rebuild falló para $([System.IO.Path]::GetFileName($csproj)) (exit $LASTEXITCODE)"
            $ok = $false; break
        }

        # Salida = <csprojDir>\bin\Release (framework clásico). Fallback: buscar el bin\Release del csproj.
        $csprojDir = Split-Path $csproj -Parent
        $outDir = Join-Path $csprojDir "bin\Release"
        if (!(Test-Path $outDir)) {
            $found = Get-ChildItem $csprojDir -Recurse -Directory -Filter "Release" -ErrorAction SilentlyContinue |
                     Where-Object { $_.FullName -match 'bin.Release$' } | Select-Object -First 1
            if ($found) { $outDir = $found.FullName }
        }
        if (!(Test-Path $outDir)) {
            Write-Host "ERROR: no se encontró bin\Release para $([System.IO.Path]::GetFileName($csproj))"
            $ok = $false; break
        }

        Write-Host "Binarios: $outDir  ->  $exesDir"
        Copy-Item "$outDir\*" $exesDir -Recurse -Force
    }
    if (-not $ok) { $fallos += $sln }
}

# ---------------------------------------------------------------------------------------------------
# Paso E — GATE DE COHERENCIA (bloqueante). Todo .exe + DLL compartida en EXES debe ser de ESTE build.
#          Un fichero anterior a $buildStart = straggler de un build viejo = frankenbuild → fallar.
# ---------------------------------------------------------------------------------------------------
$deployed = @(Get-ChildItem $exesDir -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Extension -eq '.exe' -or ($_.Extension -eq '.dll' -and $sharedAssemblies -contains $_.BaseName)
})
$exeCount = @($deployed | Where-Object { $_.Extension -eq '.exe' }).Count
if ($exeCount -eq 0) {
    Write-Host "`nERROR: gate de coherencia — no se desplegó ningún .exe en $exesDir"
    exit 1
}

$stragglers = @($deployed | Where-Object { $_.LastWriteTime -lt $buildStart })
if ($stragglers.Count -gt 0) {
    Write-Host "`nERROR: gate de coherencia — ficheros de OTRO build en EXES (riesgo StackOverflow):"
    $stragglers | ForEach-Object {
        Write-Host ("  {0}  [{1}]  (build actual: {2})" -f $_.Name, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), $buildStart.ToString('yyyy-MM-dd HH:mm:ss'))
    }
    Write-Host "  -> el instalador NO es coherente. Revisar wipe/Rebuild; NO desplegar."
    exit 1
}
Write-Host "`nGate de coherencia OK — $exeCount .exe + DLLs compartidas ($($sharedAssemblies -join '/')) de este build."

# ---------------------------------------------------------------------------------------------------
# Paso F — GATE DE BINDING REDIRECTS (bloqueante). En carpeta de deploy compartida, last-writer-wins
#          puede dejar un <exe>.exe.config viejo (bindingRedirect newVersion=X) junto a una
#          System.*.dll/tercero nueva (AssemblyVersion=Y). El redirect apunta a una versión que ya no
#          existe → FileLoadException en bucle → StackOverflow (RSActBD/RSCore). "Terceros
#          version-pinned = OK" es FALSO en carpeta compartida. Para cada redirect cuyo DLL está
#          físicamente desplegado, newVersion debe == AssemblyName.Version real del DLL.
# ---------------------------------------------------------------------------------------------------
$asmNs = 'urn:schemas-microsoft-com:asm.v1'
$bindingMismatch = @()
foreach ($cfgFile in @(Get-ChildItem $exesDir -File -Filter "*.exe.config" -ErrorAction SilentlyContinue)) {
    try { $xml = [xml](Get-Content $cfgFile.FullName -Raw) } catch {
        Write-Host "AVISO: no se pudo parsear $($cfgFile.Name) — se omite del gate de binding."
        continue
    }
    $nsm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $nsm.AddNamespace('a', $asmNs)
    foreach ($dep in @($xml.SelectNodes('//a:dependentAssembly', $nsm))) {
        $ident    = $dep.SelectSingleNode('a:assemblyIdentity', $nsm)
        $redirect = $dep.SelectSingleNode('a:bindingRedirect', $nsm)
        if (-not $ident -or -not $redirect) { continue }
        $name = $ident.name
        $newVer = $redirect.newVersion
        if (-not $name -or -not $newVer) { continue }

        $dll = Join-Path $exesDir "$name.dll"
        if (!(Test-Path $dll)) { continue }  # no desplegada → se resuelve de GAC, no aplica

        try { $realVer = [System.Reflection.AssemblyName]::GetAssemblyName($dll).Version } catch {
            Write-Host "AVISO: no se pudo leer la versión de $name.dll — se omite."
            continue
        }
        try { $cfgVer = [version]$newVer } catch { $cfgVer = $null }
        if ($cfgVer -eq $null -or $realVer -ne $cfgVer) {
            $bindingMismatch += ("  {0} · {1}: config newVersion={2} != DLL AssemblyVersion={3}" -f $cfgFile.Name, $name, $newVer, $realVer)
        }
    }
}
if ($bindingMismatch.Count -gt 0) {
    Write-Host "`nERROR: gate de binding redirects — config y DLL desalineados (FileLoadException → StackOverflow):"
    $bindingMismatch | ForEach-Object { Write-Host $_ }
    Write-Host "  -> el .exe.config apunta a una versión de assembly que no está desplegada. NO desplegar."
    exit 1
}
Write-Host "Gate de binding redirects OK — newVersion de cada .exe.config coincide con el DLL desplegado."

Write-Host "`n== Resumen BATCH: $($batch.Count - $fallos.Count)/$($batch.Count) OK =="
if ($fallos.Count -gt 0) {
    Write-Host "Fallos: $($fallos -join ', ')"
    exit 1
}
Write-Host "OK — EXES en $exesDir"
