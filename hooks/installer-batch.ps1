<#
.SYNOPSIS
    Instalador — recompila (Rebuild, no incremental) los procesos batch ACTIVOS del cliente desde
    un único snapshot de fuente y copia sus ejecutables a <destino>\EXES.

    Lista de procesos activos = docs\<proyecto>-instalador.json → campo "batch" (array de
    nombres de .sln sin extensión, bajo Batch\Soluciones\).

    ⛔ POR QUÉ Rebuild + wipe + gate (regresión real en una instalación de cliente, StackOverflow al arrancar):
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
.PARAMETER OmitirProcesosExes  No auditar C:\ais\<Proyecto>\Procesos\Exes en los gates de binding
                      redirects y ODP.NET. Salida de emergencia: por defecto esa carpeta SI se
                      audita (ver Paso F).
.PARAMETER LimpiarDllConfig    Borra los *.dll.config huerfanos de las carpetas de despliegue en
                      vez de solo listarlos. Opt-in: es destructivo sobre carpetas compartidas.
#>
param(
    [Parameter(Mandatory=$true)][string]$workspace,
    [Parameter(Mandatory=$true)][string]$destino,
    [switch]$OmitirProcesosExes,
    [switch]$LimpiarDllConfig
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# Los gates (coherencia, binding redirects, ODP.NET, *.dll.config huérfanos) viven en la librería:
# ahí DECIDEN y aquí se PRESENTA el resultado. Separados para poder probarlos sin msbuild ni
# workspace de cliente — ver hooks\lib-deploy-gates.ps1 y tests\DeployGates.Tests.ps1.
. (Join-Path $PSScriptRoot "lib-deploy-gates.ps1")

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

# ---------------------------------------------------------------------------------------------------
# Paso 0 — ¿Está centralizada la configuración de los batch en este workspace?
#          Centralizada = Batch\App.Batch.config + Batch\Directory.Build.targets (ver
#          references\batch-config.md). Con ese mecanismo, MSBuild GENERA cada <Exe>.exe.config en
#          bin\<Config>\ con los bindingRedirects al día; sin él, cada app.config por proyecto se
#          mantiene a mano y se desincroniza del DLL desplegado — justo lo que caza el gate F.
#          Advisory, no bloqueante: los workspaces que aún no lo han adoptado deben seguir compilando.
# ---------------------------------------------------------------------------------------------------
$batchDir        = Join-Path $workspace "Batch"
$appBatchConfig  = Join-Path $batchDir "App.Batch.config"
$dirBuildTargets = Join-Path $batchDir "Directory.Build.targets"
$centralizado    = (Test-Path $appBatchConfig) -and (Test-Path $dirBuildTargets)
if (-not $centralizado) {
    Write-Host ""
    Write-Host "AVISO ⚠ la configuración de los batch NO está centralizada en este workspace:"
    if (!(Test-Path $appBatchConfig))  { Write-Host "  falta Batch\App.Batch.config" }
    if (!(Test-Path $dirBuildTargets)) { Write-Host "  falta Batch\Directory.Build.targets" }
    Write-Host "  -> con app.config por proyecto, los bindingRedirects se mantienen a mano y acaban"
    Write-Host "     desalineados con el DLL desplegado (FileLoadException -> StackOverflow al arrancar)."
    Write-Host "  -> informe:      .\hooks\batch-centralizar.ps1 `"$workspace`""
    Write-Host "     centralizar:   .\hooks\batch-centralizar.ps1 `"$workspace`" -Aplicar"
    Write-Host "     convención:    references\batch-config.md"
}

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
#          usar <ProjectReference>. Corregido en r14970 del proyecto donde se detectó; aquí solo se avisa (advisory).
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
#          Lógica en Test-RsCoherenciaBuild (lib-deploy-gates.ps1).
# ---------------------------------------------------------------------------------------------------
$coherencia = Test-RsCoherenciaBuild -Carpeta $exesDir -BuildStart $buildStart -SharedAssemblies $sharedAssemblies
if ($coherencia.ExeCount -eq 0) {
    Write-Host "`nERROR: gate de coherencia — no se desplegó ningún .exe en $exesDir"
    exit 1
}
if ($coherencia.Stragglers.Count -gt 0) {
    Write-Host "`nERROR: gate de coherencia — ficheros de OTRO build en EXES (riesgo StackOverflow):"
    $coherencia.Stragglers | ForEach-Object {
        Write-Host ("  {0}  [{1}]  (build actual: {2})" -f $_.Name, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), $buildStart.ToString('yyyy-MM-dd HH:mm:ss'))
    }
    Write-Host "  -> el instalador NO es coherente. Revisar wipe/Rebuild; NO desplegar."
    exit 1
}
Write-Host "`nGate de coherencia OK — $($coherencia.ExeCount) .exe + DLLs compartidas ($($sharedAssemblies -join '/')) de este build."

# ---------------------------------------------------------------------------------------------------
# Carpetas de despliegue que auditan los gates F y G. Son DOS carpetas compartidas con dueños
# distintos y ambas sufren last-writer-wins:
#   <destino>\EXES                     la que produce esta ejecución
#   C:\ais\<Proyecto>\Procesos\Exes    la carpeta viva, que escribe batch-build.ps1 en cada desarrollo
# Auditar solo la primera dejaba pasar el desalineo de la segunda, que es donde los procesos corren
# de verdad. -OmitirProcesosExes es la salida de emergencia para generar el paquete con la carpeta
# viva sucia.
# ---------------------------------------------------------------------------------------------------
$carpetasDeploy = @([pscustomobject]@{ Etiqueta = "paquete"; Ruta = $exesDir })
$procesosExes   = "C:\ais\$proyecto\Procesos\Exes"   # misma convencion que batch-build.ps1
if ($OmitirProcesosExes) {
    Write-Host "`nAVISO: -OmitirProcesosExes — los gates NO auditan $procesosExes."
} elseif (Test-Path $procesosExes) {
    $carpetasDeploy += [pscustomobject]@{ Etiqueta = "carpeta viva"; Ruta = $procesosExes }
} else {
    Write-Host "`nAVISO: no existe $procesosExes — los gates solo auditan la carpeta del paquete."
}
Write-Host "Carpetas auditadas por los gates:"
$carpetasDeploy | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.Etiqueta, $_.Ruta) }

# ---------------------------------------------------------------------------------------------------
# Paso F — GATE DE BINDING REDIRECTS (bloqueante). En carpeta de deploy compartida, last-writer-wins
#          puede dejar un <exe>.exe.config viejo (bindingRedirect newVersion=X) junto a una
#          System.*.dll/tercero nueva (AssemblyVersion=Y). El redirect apunta a una versión que ya no
#          existe → FileLoadException en bucle → StackOverflow (RSActBD/RSCore). "Terceros
#          version-pinned = OK" es FALSO en carpeta compartida. Para cada redirect cuyo DLL está
#          físicamente desplegado, newVersion debe == AssemblyName.Version real del DLL.
#
#          ⛔ Un gate que NO puede evaluar no reporta OK. Todo fallo de lectura (XML ilegible,
#          SelectNodes roto, versión de DLL no leíble) llega en NoEvaluable y hace exit 1, en vez de
#          saltarse la comprobación con un AVISO y acabar imprimiendo "OK".
#          Única excepción legítima: BadImageFormatException = el fichero no es un assembly
#          gestionado (un nativo que coincide en nombre con la identidad del redirect), así que ese
#          redirect no aplica a ese fichero y saltarlo es correcto.
#          Lógica en Test-RsBindingRedirects (lib-deploy-gates.ps1).
# ---------------------------------------------------------------------------------------------------
$binding = Test-RsBindingRedirects -Carpetas $carpetasDeploy
$binding.Avisos | ForEach-Object { Write-Host $_ }
if ($binding.NoEvaluable.Count -gt 0) {
    Write-Host "`nERROR: gate de binding redirects — NO SE PUDO EVALUAR (un gate que no evalúa no reporta OK):"
    $binding.NoEvaluable | ForEach-Object { Write-Host $_ }
    Write-Host "  -> revisar esos ficheros. NO desplegar hasta que el gate pueda ejecutarse entero."
    exit 1
}
if ($binding.Mismatch.Count -gt 0) {
    Write-Host "`nERROR: gate de binding redirects — config y DLL desalineados (FileLoadException → StackOverflow):"
    $binding.Mismatch | ForEach-Object { Write-Host $_ }
    Write-Host "  -> el .exe.config apunta a una versión de assembly que no está desplegada. NO desplegar."
    Write-Host "  -> el .exe.config válido es el que MSBuild genera en bin\<Config>\; nunca se reconstruye a mano."
    exit 1
}
Write-Host "Gate de binding redirects OK — $($carpetasDeploy.Count) carpeta(s): newVersion de cada .exe.config coincide con el DLL desplegado."

# ---------------------------------------------------------------------------------------------------
# Paso G — GATE DE DEPENDENCIAS ODP.NET (bloqueante). Fallo silencioso en build, explosivo en
#          ejecución: Comun.dll no referencia System.Text.Json & cía en su IL — quien las usa es
#          Oracle.ManagedDataAccess.dll. Al compilar un EXE, MSBuild sigue la cadena
#          Comun.dll -> Oracle.ManagedDataAccess.dll -> System.Text.Json <ver>, no encuentra esa
#          versión en packages y DESCARTA la referencia SIN NINGÚN WARNING. El bin queda sin esas DLL
#          y el proceso muere en el primer acceso a BD con un TypeInitializationException de
#          OracleCommand. Aquí se exige presencia FÍSICA junto a Oracle.ManagedDataAccess.dll.
#          Override por JSON (odpDependencies); default = los 7 satélites del stack.
#          Lógica en Test-RsOdpDependencies (lib-deploy-gates.ps1).
# ---------------------------------------------------------------------------------------------------
$odp = if ($cfg.odpDependencies) {
    Test-RsOdpDependencies -Carpetas $carpetasDeploy -Dependencias @($cfg.odpDependencies)
} else {
    Test-RsOdpDependencies -Carpetas $carpetasDeploy
}
if ($odp.Faltan.Count -gt 0) {
    Write-Host "`nERROR: gate de dependencias ODP.NET — Oracle.ManagedDataAccess.dll desplegado sin sus satélites:"
    $odp.Faltan | ForEach-Object { Write-Host $_ }
    Write-Host "  -> MSBuild descartó esas referencias en silencio (sin warning) al no encontrar la versión"
    Write-Host "     que pide Oracle.ManagedDataAccess.dll. El proceso arranca bien y muere en el primer"
    Write-Host "     acceso a BD con: 'Se produjo una excepción en el inicializador de tipo de"
    Write-Host "     Oracle.ManagedDataAccess.Client.OracleCommand'."
    Write-Host "  -> declararlas en Batch\Directory.Build.targets con HintPath y <Private>true</Private>"
    Write-Host "     (ver references\batch-config.md). NO desplegar."
    exit 1
}
if ($odp.Auditadas -gt 0) {
    Write-Host "Gate de dependencias ODP.NET OK — $($odp.Dependencias.Count) satélites presentes en $($odp.Auditadas) carpeta(s)."
} else {
    Write-Host "Gate de dependencias ODP.NET: no aplica — Oracle.ManagedDataAccess.dll no está desplegado."
}

# ---------------------------------------------------------------------------------------------------
# Paso H — *.dll.config huérfanos (advisory; barrido solo con -LimpiarDllConfig).
#          Con la configuración centralizada ya no se generan: el CLR no lee <dll>.config para
#          binding y eran ruido. Los que quedan en las carpetas de despliegue son residuos de builds
#          anteriores. Solo se comprueba si el workspace ESTÁ centralizado: sin centralizar, un
#          <dll>.config puede seguir siendo legítimo.
#          Localización en Get-RsDllConfigHuerfanos (lib-deploy-gates.ps1); borrarlos se decide aquí.
# ---------------------------------------------------------------------------------------------------
if ($centralizado) {
    $dllConfigs = @(Get-RsDllConfigHuerfanos -Carpetas $carpetasDeploy)
    if ($dllConfigs.Count -gt 0) {
        Write-Host ""
        if ($LimpiarDllConfig) {
            Write-Host "Barrido de *.dll.config huérfanos ($($dllConfigs.Count)):"
            foreach ($x in $dllConfigs) {
                Remove-Item $x.File.FullName -Force -ErrorAction SilentlyContinue
                Write-Host ("  borrado  {0} · {1}" -f $x.Etiqueta, $x.File.Name)
            }
        } else {
            Write-Host "AVISO ⚠ $($dllConfigs.Count) *.dll.config huérfanos (la configuración centralizada ya no los genera):"
            $dllConfigs | ForEach-Object { Write-Host ("  {0} · {1}" -f $_.Etiqueta, $_.File.Name) }
            Write-Host "  -> el CLR no los lee para binding; son residuos de builds anteriores."
            Write-Host "  -> para borrarlos: repetir con -LimpiarDllConfig."
        }
    }
}

Write-Host "`n== Resumen BATCH: $($batch.Count - $fallos.Count)/$($batch.Count) OK =="
if ($fallos.Count -gt 0) {
    Write-Host "Fallos: $($fallos -join ', ')"
    exit 1
}
Write-Host "OK — EXES en $exesDir"
