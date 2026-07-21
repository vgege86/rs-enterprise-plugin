param(
    [string]$workspace
)

Write-Host "Resetting environment..."

# Limpiar builds
.\scripts\clean-build.ps1 $workspace

# Limpiar AIS
.\scripts\clean-ais.ps1 $workspace

Write-Host "Environment reset completed ✅"