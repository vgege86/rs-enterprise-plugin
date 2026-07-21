param(
    [string]$workspace
)

# Obtener nombre del proyecto
$project = Split-Path (Split-Path $workspace -Parent) -Leaf
$aisPath = "C:\ais\$project\Procesos\Exes"

Write-Host "Cleaning AIS: $aisPath"

if (Test-Path $aisPath) {
    Remove-Item "$aisPath\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "AIS cleaned ✅"
}
else {
    Write-Host "AIS path not found"
}