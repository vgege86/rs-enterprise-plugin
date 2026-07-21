param(
    [string]$source,
    [string]$workspace
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
Write-Host "Starting copy process..."

# Obtener nombre del proyecto (carpeta antes de trunk)
$project = Split-Path (Split-Path $workspace -Parent) -Leaf

# Ruta destino AIS
$dest = "C:\ais\$project\Procesos\Exes"

Write-Host "Source: $source"
Write-Host "Destination: $dest"

# Crear destino si no existe
if (!(Test-Path $dest)) {
    Write-Host "Destination does not exist. Creating..."
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
}

# 🔥 LIMPIEZA PREVIA (CRÍTICO)
Write-Host "Cleaning destination folder..."

try {
    Get-ChildItem -Path $dest -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction Stop
    Write-Host "Destination cleaned successfully"
}
catch {
    Write-Host "Warning: Could not fully clean destination (continuing...)"
}

# 📦 COPIA COMPLETA
Write-Host "Copying files..."

Copy-Item "$source\*" $dest -Recurse -Force

Write-Host "Copy completed successfully ✅"