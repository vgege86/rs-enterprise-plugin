param(
    [string]$solution,
    [string]$workspace
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$solutionPath = "$workspace\Batch\Soluciones\$solution.sln"

Write-Host "Building Batch solution..."

dotnet build "$solutionPath" -c Debug
dotnet build "$solutionPath" -c Release

# Localizar bin\Release — probar rutas más comunes
$candidatos = @(
    "$workspace\Batch\$solution\bin\Release",
    "$workspace\Batch\Soluciones\$solution\bin\Release",
    "$workspace\Batch\Soluciones\$solution\$solution\bin\Release"
)
$exePath = $candidatos | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $exePath) {
    # Buscar cualquier bin\Release bajo Batch que contenga EXE con el nombre de la solución
    $found = Get-ChildItem "$workspace\Batch" -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue |
             Where-Object { $_.DirectoryName -match "bin.Release" } |
             Select-Object -First 1
    if ($found) { $exePath = $found.DirectoryName }
}

if (-not $exePath) {
    Write-Error "No se encontró bin\Release para $solution bajo $workspace\Batch"
    exit 1
}

Write-Host "Binaries en: $exePath"

# obtener proyecto AIS (carpeta anterior a trunk)
$project = Split-Path (Split-Path $workspace -Parent) -Leaf
$aisPath = "C:\ais\$project\Procesos\Exes"

Write-Host "Copiando a $aisPath"

if (!(Test-Path $aisPath)) {
    New-Item -ItemType Directory -Path $aisPath -Force | Out-Null
}

# Borrar SOLO los ficheros que se van a copiar (no limpiar destino completo)
Get-ChildItem "$exePath" -File -Recurse | ForEach-Object {
    $rel = $_.FullName.Substring($exePath.Length).TrimStart('\')
    $dst = Join-Path $aisPath $rel
    if (Test-Path $dst) { Remove-Item $dst -Force }
}

Copy-Item "$exePath\*" $aisPath -Recurse -Force
Write-Host "OK — binarios copiados a $aisPath"