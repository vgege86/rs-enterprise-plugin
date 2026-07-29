<#
.SYNOPSIS
    Actualizador — compila y empaqueta SOLO lo afectado por un rango de commits, en la carpeta
    de entrega <destino> (C:\AIS\<Proyecto>\Actualizador\<ENTORNO>_<AAAAMMDD>).

      Exes\                    delta: solo las soluciones batch afectadas (Rebuild completo de cada una)
      AgendaWeb\               SIEMPRE completa (delega en installer-agendaweb.ps1)
      ServiceManager\Modulos\  delta: solo las DLL de los modulos afectados

    Que se compila lo decide el MANIFIESTO que escribe el agente rs-actualizador tras cruzar
    los ficheros del delta VCS (vcs-delta.ps1) con los .sln/.csproj del workspace.

    ⛔ La configuracion FUNCIONAL del cliente no viaja: se excluyen web.config, el <proceso>.xml de
    cada batch y appsettings*.json (mas los patrones de "excluirEntrega" del JSON), y se listan en el
    output para que el readme.txt recoja los parametros nuevos que el cliente deba anadir.
    Los *.config que acompanan al binario (RSProcIN.exe.config, DLL .config) SI viajan: llevan los
    binding redirects y separarlos de sus DLL provoca FileLoadException.

    Por que Rebuild de la solucion batch entera y no solo el csproj tocado: las DLL compartidas
    (Comun/BusComun/RSModel) no tienen strong-name y el CLR enlaza por nombre simple — mezclar
    binarios de builds distintos provoca StackOverflowException en arranque (misma regresion que
    documenta installer-batch.ps1). Por eso el gate de coherencia es identico aqui.

.PARAMETER workspace   Ruta trunk del proyecto
.PARAMETER destino     Carpeta de la entrega (ya creada o no)
.PARAMETER manifiesto  JSON con lo afectado:
    {
      "entorno": "TEST",
      "version": "TEST_20260729",
      "batch": ["RSProcIN"],
      "agendaweb": true,
      "modulos": ["AIS.RS.<Proyecto>.API"]
    }

.EXAMPLE
    .\actualizador-build.ps1 "C:\SVN\RS\<Proyecto>\trunk" "C:\AIS\<Proyecto>\Actualizador\TEST_20260729" "C:\...\manifiesto.json"
#>
param(
    [Parameter(Mandatory=$true)][string]$workspace,
    [Parameter(Mandatory=$true)][string]$destino,
    [Parameter(Mandatory=$true)][string]$manifiesto
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

if (!(Test-Path $workspace))  { Write-Host "ERROR: workspace no encontrado: $workspace"; exit 1 }
if (!(Test-Path $manifiesto)) { Write-Host "ERROR: manifiesto no encontrado: $manifiesto"; exit 1 }

$man = Get-Content $manifiesto -Raw -Encoding UTF8 | ConvertFrom-Json
$batch     = @($man.batch)
$modulos   = @($man.modulos)
$conAgenda = [bool]$man.agendaweb

if ($batch.Count -eq 0 -and $modulos.Count -eq 0 -and -not $conAgenda) {
    Write-Host "ERROR: el manifiesto no declara nada que empaquetar (batch, modulos y agendaweb vacios)."
    exit 1
}

$proyecto = if ((Split-Path $workspace -Leaf) -eq 'trunk') { Split-Path (Split-Path $workspace -Parent) -Leaf } else { Split-Path $workspace -Leaf }

# sharedAssemblies: mismo criterio que el instalador (config del instalador si existe)
$sharedAssemblies = @('Comun','BusComun','RSModel')
$jsonInst = Join-Path $workspace "docs\$proyecto-instalador.json"
if (Test-Path $jsonInst) {
    $cfgInst = Get-Content $jsonInst -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfgInst.sharedAssemblies) { $sharedAssemblies = @($cfgInst.sharedAssemblies) }
}

New-Item -ItemType Directory -Path $destino -Force | Out-Null
Write-Host "== Actualizador $($man.version) — $proyecto =="
Write-Host "Destino: $destino"
Write-Host "Batch: $($batch.Count) · AgendaWeb: $conAgenda · Modulos: $($modulos.Count)"

$fallos = @()

# ---------------------------------------------------------------------------------------------------
# Helpers (gemelos de installer-batch.ps1 — se duplican a proposito: aquel hook arrastra una regresion
# documentada y no se toca desde aqui)
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
    return ((Get-Content $csproj -Raw) -match '<OutputType>\s*(Exe|WinExe)\s*</OutputType>')
}

$msbuild = $null
function Get-MsBuild {
    if ($script:msbuild) { return $script:msbuild }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (!(Test-Path $vswhere)) { Write-Host "ERROR: vswhere no encontrado en $vswhere"; exit 1 }
    $mb = & $vswhere -latest -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
    if (!$mb -or !(Test-Path $mb)) { Write-Host "ERROR: msbuild no encontrado via vswhere"; exit 1 }
    $script:msbuild = $mb
    Write-Host "msbuild: $mb"
    return $mb
}

$buildStart = Get-Date

# ---------------------------------------------------------------------------------------------------
# 1. BATCH (delta) -> Exes\
# ---------------------------------------------------------------------------------------------------
if ($batch.Count -gt 0) {
    $exesDir = Join-Path $destino "Exes"
    New-Item -ItemType Directory -Path $exesDir -Force | Out-Null
    $mb = Get-MsBuild

    $exeCsprojBySln = @{}
    $allCsproj = New-Object System.Collections.Generic.HashSet[string]
    foreach ($sln in $batch) {
        $slnPath = Join-Path $workspace "Batch\Soluciones\$sln.sln"
        if (!(Test-Path $slnPath)) { Write-Host "ERROR: .sln no encontrada: $slnPath"; $fallos += $sln; continue }
        $csprojs = Get-CsprojFromSln $slnPath
        foreach ($cp in $csprojs) { [void]$allCsproj.Add($cp) }
        $exeCps = @($csprojs | Where-Object { Test-IsExeCsproj $_ })
        if ($exeCps.Count -eq 0) {
            $exeCps = @($csprojs | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) -eq $sln })
        }
        if ($exeCps.Count -eq 0) { Write-Host "ERROR: ningun csproj-exe en $sln"; $fallos += $sln; continue }
        $exeCsprojBySln[$sln] = $exeCps
    }

    Write-Host "`n-- Wipe bin/obj del scope batch ($($allCsproj.Count) proyectos) --"
    foreach ($cp in $allCsproj) {
        $dir = Split-Path $cp -Parent
        foreach ($sub in @('bin','obj')) {
            $p = Join-Path $dir $sub
            if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    $buildStart = Get-Date
    Write-Host "Build snapshot: $($buildStart.ToString('yyyy-MM-dd HH:mm:ss'))"

    foreach ($sln in ($exeCsprojBySln.Keys | Sort-Object)) {
        Write-Host "`n--- $sln ---"
        $ok = $true
        foreach ($csproj in $exeCsprojBySln[$sln]) {
            Write-Host "Rebuild: $([System.IO.Path]::GetFileName($csproj))"
            & "$mb" "$csproj" /t:Rebuild /p:Configuration=Release /p:VisualStudioVersion=17.0 /verbosity:minimal /nologo
            if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Rebuild fallo (exit $LASTEXITCODE)"; $ok = $false; break }

            $csprojDir = Split-Path $csproj -Parent
            $outDir = Join-Path $csprojDir "bin\Release"
            if (!(Test-Path $outDir)) {
                $found = Get-ChildItem $csprojDir -Recurse -Directory -Filter "Release" -ErrorAction SilentlyContinue |
                         Where-Object { $_.FullName -match 'bin.Release$' } | Select-Object -First 1
                if ($found) { $outDir = $found.FullName }
            }
            if (!(Test-Path $outDir)) { Write-Host "ERROR: no se encontro bin\Release"; $ok = $false; break }
            Write-Host "Binarios: $outDir  ->  $exesDir"
            Copy-Item "$outDir\*" $exesDir -Recurse -Force
        }
        if (-not $ok) { $fallos += $sln }
    }

    # Gate de coherencia (bloqueante): todo .exe / DLL compartida desplegado debe ser de ESTE build
    $deployed = @(Get-ChildItem $exesDir -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -eq '.exe' -or ($_.Extension -eq '.dll' -and $sharedAssemblies -contains $_.BaseName)
    })
    if (@($deployed | Where-Object { $_.Extension -eq '.exe' }).Count -eq 0) {
        Write-Host "`nERROR: gate de coherencia — no se desplego ningun .exe en $exesDir"; exit 1
    }
    $stragglers = @($deployed | Where-Object { $_.LastWriteTime -lt $buildStart })
    if ($stragglers.Count -gt 0) {
        Write-Host "`nERROR: gate de coherencia — ficheros de OTRO build en Exes (riesgo StackOverflow):"
        $stragglers | ForEach-Object { Write-Host ("  {0}  [{1}]" -f $_.Name, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) }
        exit 1
    }
    Write-Host "Gate de coherencia OK — $($deployed.Count) binarios de este build"
}

# ---------------------------------------------------------------------------------------------------
# 2. AGENDAWEB (siempre completa) -> AgendaWeb\
# ---------------------------------------------------------------------------------------------------
if ($conAgenda) {
    Write-Host "`n== AgendaWeb (publicacion completa) =="
    if (!(Test-Path $jsonInst)) {
        Write-Host "ERROR: AgendaWeb requiere docs\$proyecto-instalador.json (de ahi sale agendaweb.sln)."
        Write-Host "       Genera primero el instalador con /rs-instalador, o pon agendaweb=false en el manifiesto."
        $fallos += "AgendaWeb"
    } else {
        & (Join-Path $PSScriptRoot "installer-agendaweb.ps1") $workspace $destino
        if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: publicacion de AgendaWeb fallo (exit $LASTEXITCODE)"; $fallos += "AgendaWeb" }
    }
}

# ---------------------------------------------------------------------------------------------------
# 3. MODULOS ServiceManager (delta) -> ServiceManager\Modulos\
# ---------------------------------------------------------------------------------------------------
if ($modulos.Count -gt 0) {
    $modDir = Join-Path $destino "ServiceManager\Modulos"
    New-Item -ItemType Directory -Path $modDir -Force | Out-Null
    $modulosRoot = Join-Path $workspace "OnLine\AISServiceManager\Modulos"
    Write-Host "`n== Modulos ServiceManager: $($modulos.Count) =="

    foreach ($mod in $modulos) {
        Write-Host "`n--- $mod ---"
        $modFolder = Join-Path $modulosRoot $mod
        if (!(Test-Path $modFolder)) { Write-Host "ERROR: carpeta de modulo no encontrada: $modFolder"; $fallos += $mod; continue }
        $modSln = Get-ChildItem $modFolder -Filter *.sln -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $modSln) { Write-Host "ERROR: no hay .sln en $modFolder"; $fallos += $mod; continue }

        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "actmod_$($mod -replace '[^\w]','_')"
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        $publishStart = Get-Date

        dotnet publish "$($modSln.FullName)" -c Release -o "$tmp"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: publish del modulo $mod fallo (exit $LASTEXITCODE)"
            $fallos += $mod
            if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
            continue
        }

        # En un actualizador solo viajan las DLL COMPILADAS AHORA (las de NuGet/framework ya estan
        # instaladas en el cliente y meterlas invita a un conflicto de versiones).
        $copiadas = 0
        Get-ChildItem $tmp -Filter *.dll -File | Where-Object { $_.LastWriteTime -ge $publishStart } | ForEach-Object {
            Copy-Item $_.FullName $modDir -Force
            $copiadas++
        }
        Write-Host "$mod -> $copiadas DLL copiadas a Modulos"
        if ($copiadas -eq 0) { Write-Host "AVISO: 0 DLL nuevas para $mod — revisa si el modulo estaba realmente afectado" }
        Remove-Item $tmp -Recurse -Force
    }
}

# ---------------------------------------------------------------------------------------------------
# 4. EXCLUSION de la configuracion FUNCIONAL del cliente
#
#    SI viajan los *.config que acompanan al binario (RSProcIN.exe.config y las DLL .config): llevan
#    los binding redirects, y si no coinciden con las DLL desplegadas da FileLoadException ->
#    StackOverflow (es justo lo que vigila el gate de binding redirects de installer-batch.ps1).
#    Separarlos del binario que los necesita seria introducir esa regresion.
#
#    NO viaja la configuracion funcional del entorno del cliente:
#      - web.config (a cualquier nivel de AgendaWeb)
#      - <proceso>.xml  — el XML de configuracion de cada batch (rsprocin.exe + rsprocin.xml)
#      - appsettings*.json — configuracion del host/modulos net8
#      - lo que anada el JSON del proyecto en "excluirEntrega" (wildcards)
# ---------------------------------------------------------------------------------------------------
$excluidos = New-Object System.Collections.Generic.List[System.IO.FileInfo]

Get-ChildItem $destino -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -ieq 'web.config' -or $_.Name -like 'appsettings*.json'
} | ForEach-Object { $excluidos.Add($_) }

# XML de configuracion de proceso: mismo nombre base que un .exe entregado
$exesFin = Join-Path $destino "Exes"
$xmlHuerfanos = @()
if (Test-Path $exesFin) {
    $exeNames = @(Get-ChildItem $exesFin -File -Filter *.exe -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.BaseName.ToLower() })
    foreach ($xml in @(Get-ChildItem $exesFin -Recurse -File -Filter *.xml -ErrorAction SilentlyContinue)) {
        if ($exeNames -contains $xml.BaseName.ToLower()) { $excluidos.Add($xml) }
        else { $xmlHuerfanos += $xml }
    }
}

# Patrones extra declarados por el proyecto
$patronesExtra = @()
if (Test-Path $jsonInst) {
    $cfgTmp = Get-Content $jsonInst -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfgTmp.excluirEntrega) { $patronesExtra = @($cfgTmp.excluirEntrega) }
}
foreach ($pat in $patronesExtra) {
    Get-ChildItem $destino -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like $pat } | ForEach-Object { $excluidos.Add($_) }
}

$purgados = @($excluidos | Sort-Object FullName -Unique)
if ($purgados.Count -gt 0) {
    Write-Host "`n-- Configuracion del cliente excluida del paquete ($($purgados.Count) ficheros) --"
    foreach ($f in $purgados) {
        Write-Host "  $($f.FullName.Substring($destino.Length + 1))"
        Remove-Item $f.FullName -Force
    }
    Write-Host "  -> si alguno lleva parametros NUEVOS, documentalos en readme.txt (el cliente los anade a su copia)."
}
if ($xmlHuerfanos.Count -gt 0) {
    Write-Host "`nAVISO: .xml en Exes que NO coinciden con ningun .exe entregado — se quedan en el paquete."
    Write-Host "       Revisa si alguno es configuracion del cliente; si lo es, anadelo a 'excluirEntrega' del JSON:"
    $xmlHuerfanos | ForEach-Object { Write-Host "  $($_.FullName.Substring($destino.Length + 1))" }
}

# ---------------------------------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------------------------------
$nExes = @(Get-ChildItem (Join-Path $destino "Exes") -File -ErrorAction SilentlyContinue).Count
$nWeb  = @(Get-ChildItem (Join-Path $destino "AgendaWeb") -Recurse -File -ErrorAction SilentlyContinue).Count
$nMod  = @(Get-ChildItem (Join-Path $destino "ServiceManager\Modulos") -File -ErrorAction SilentlyContinue).Count

Write-Host "`n== Resumen ACTUALIZADOR $($man.version) =="
Write-Host "Exes:                 $nExes ficheros"
Write-Host "AgendaWeb:            $nWeb ficheros"
Write-Host "ServiceManager\Modulos: $nMod DLL"
Write-Host "Config cliente excluida: $($purgados.Count) ficheros"

if ($fallos.Count -gt 0) {
    Write-Host "FALLOS: $($fallos -join ', ')"
    exit 1
}
Write-Host "OK — paquete generado en $destino"
