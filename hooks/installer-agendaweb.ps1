<#
.SYNOPSIS
    Instalador — publica la Agenda Web (WebForms .NET Framework) a <destino>\AgendaWeb.

    .sln = docs\<proyecto>-instalador.json → agendaweb.sln (bajo OnLine\Soluciones\).
    Publica por FileSystem (msbuild) forzando el destino a <destino>\AgendaWeb — NO usa el
    <PublishUrl> del .pubxml (que apunta al AIS en vivo).

.PARAMETER workspace  Ruta trunk del proyecto
.PARAMETER destino    Carpeta Instalador
#>
param(
    [Parameter(Mandatory=$true)][string]$workspace,
    [Parameter(Mandatory=$true)][string]$destino
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$proyecto = if ((Split-Path $workspace -Leaf) -eq 'trunk') { Split-Path (Split-Path $workspace -Parent) -Leaf } else { Split-Path $workspace -Leaf }
$jsonPath = Join-Path $workspace "docs\$proyecto-instalador.json"
if (!(Test-Path $jsonPath)) { Write-Host "ERROR: Config no encontrada: $jsonPath"; exit 1 }
$cfg = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

$slnName = $cfg.agendaweb.sln
if (-not $slnName) { Write-Host "AVISO: agendaweb.sln no configurado — se omite AgendaWeb."; exit 0 }
$publishProfile = $cfg.agendaweb.publishProfile
$slnPath = Join-Path $workspace "OnLine\Soluciones\$slnName"
if (!(Test-Path $slnPath)) { Write-Host "ERROR: .sln no encontrada: $slnPath"; exit 1 }

# Resolver el .csproj web (el que tiene Web.config en su carpeta) desde la .sln
$slnDir = Split-Path $slnPath -Parent
$csprojRefs = Select-String -Path $slnPath -Pattern '"([^"]+\.csproj)"' -AllMatches |
    ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value }

$webCsproj = $null
foreach ($rel in ($csprojRefs | Select-Object -Unique)) {
    $abs = [System.IO.Path]::GetFullPath((Join-Path $slnDir $rel))
    if (Test-Path $abs) {
        $dir = Split-Path $abs -Parent
        if (Test-Path (Join-Path $dir "Web.config")) { $webCsproj = $abs; break }
    }
}
if (-not $webCsproj) {
    Write-Host "ERROR: no se encontró el proyecto web (con Web.config) en $slnName"
    Write-Host "Proyectos referenciados: $($csprojRefs -join ', ')"
    exit 1
}
Write-Host "Proyecto web: $webCsproj"

# Localizar msbuild via vswhere
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (!(Test-Path $vswhere)) { Write-Host "ERROR: vswhere no encontrado en $vswhere"; exit 1 }
$msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
if (!$msbuild -or !(Test-Path $msbuild)) { Write-Host "ERROR: msbuild no encontrado via vswhere"; exit 1 }
Write-Host "msbuild: $msbuild"

$agendaDir = Join-Path $destino "AgendaWeb"
if (Test-Path $agendaDir) { Remove-Item $agendaDir -Recurse -Force }
New-Item -ItemType Directory -Path $agendaDir -Force | Out-Null

# DeployTarget=WebPublish es OBLIGATORIO: con DeployOnBuild y sin él, msbuild cae al target
# Package y genera obj\Release\Package\<app>.zip en vez de publicar a carpeta (publish vacío).
# publishUrl y DeleteExistingFiles van como propiedades globales -> ganan a las del .pubxml
# (cuyo PublishUrl apunta al AIS en vivo y suele llevar DeleteExistingFiles=true).
$msbuildArgs = @(
    "$webCsproj",
    "/p:Configuration=Release",
    "/p:DeployOnBuild=true",
    "/p:DeployTarget=WebPublish",
    "/p:WebPublishMethod=FileSystem",
    "/p:publishUrl=$agendaDir",
    "/p:DeleteExistingFiles=false",
    "/p:VisualStudioVersion=17.0",
    "/verbosity:minimal"
)
if ($publishProfile) {
    $msbuildArgs += "/p:PublishProfile=$publishProfile"
    Write-Host "Publish profile: $publishProfile"
}

Write-Host "Publicando AgendaWeb -> $agendaDir"
& "$msbuild" @msbuildArgs
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: msbuild falló (exit $LASTEXITCODE)"; exit $LASTEXITCODE }

$n = (Get-ChildItem $agendaDir -Recurse -File -ErrorAction SilentlyContinue).Count
if ($n -eq 0) { Write-Host "ERROR: publish sin ficheros en $agendaDir"; exit 1 }
Write-Host "OK — AgendaWeb publicada: $n ficheros en $agendaDir"
