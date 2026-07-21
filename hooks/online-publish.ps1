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

# Localizar msbuild via vswhere (no está en PATH por defecto)
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (!(Test-Path $vswhere)) {
    Write-Host "ERROR: vswhere not found at $vswhere"
    exit 1
}

$msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
if (!$msbuild -or !(Test-Path $msbuild)) {
    Write-Host "ERROR: msbuild not found via vswhere"
    exit 1
}

Write-Host "Using msbuild: $msbuild"

& "$msbuild" "$csproj" /p:Configuration=Release /p:DeployOnBuild=true /p:PublishProfile=$profile /p:VisualStudioVersion=17.0
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: msbuild failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}
Write-Host "Publish completed successfully"
