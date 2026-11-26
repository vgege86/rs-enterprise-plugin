param(
    [string]$csproj,
    [string]$profile = "FolderProfile1"
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
Write-Host "Publishing Online project..."
Write-Host "Project: $csproj"
Write-Host "Profile: $profile"

if (!(Test-Path $csproj)) {
    Write-Host "ERROR: Project not found: $csproj"
    exit 1
}

# Localizar msbuild via vswhere (no está en PATH por defecto). VisualStudioVersion se deriva de la
# instancia elegida: fijarla a 17.0 rompía con VS 2026 instalado (MSB4226). Ver lib-msbuild.ps1.
. (Join-Path $PSScriptRoot "lib-msbuild.ps1")
$vs = Resolve-RsVsMsBuildOrExit -PreferWebTargets
$msbuild = $vs.msbuild

& "$msbuild" "$csproj" /p:Configuration=Release /p:DeployOnBuild=true /p:PublishProfile=$profile "/p:VisualStudioVersion=$($vs.visual_studio_version)"
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: msbuild failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}
Write-Host "Publish completed successfully"
