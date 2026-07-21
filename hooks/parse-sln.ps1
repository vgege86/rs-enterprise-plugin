<#
.SYNOPSIS
    Parsea un archivo .sln y devuelve scope, tipo y metadata como JSON.
    Elimina la necesidad de que el LLM lea y parsee el .sln manualmente.

.PARAMETER SlnPath
    Ruta completa al archivo .sln

.EXAMPLE
    .\parse-sln.ps1 "C:\SVN\RS\<Proyecto>\trunk\Batch\Soluciones\RSProcIN.sln"
#>
param(
    [Parameter(Mandatory=$true)][string]$SlnPath
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

if (-not (Test-Path $SlnPath)) {
    @{ error = "Archivo no encontrado: $SlnPath" } | ConvertTo-Json
    exit 1
}

$slnFile  = Get-Item $SlnPath
$slnDir   = $slnFile.DirectoryName
$slnName  = $slnFile.BaseName   # sin .sln
$content  = Get-Content $SlnPath -Encoding UTF8

# Inferir tipo desde nombre y ruta
$tipo = if ($slnName -match '^RSProc') { 'Batch' }
        elseif ($SlnPath -match '\\OnLine\\') { 'Online' }
        elseif ($SlnPath -match '\\Batch\\') { 'Batch' }
        else { 'Unknown' }

# Extraer rutas de .csproj
$projectDirs = @()
$projects    = @()

foreach ($line in $content) {
    if ($line -match 'Project\([^)]+\)\s*=\s*"([^"]+)",\s*"([^"]+\.csproj)"') {
        $projName    = $Matches[1].Trim()
        $projRelPath = $Matches[2].Trim().Replace('/', '\')
        # GetFullPath normaliza "..\" — Join-Path solo concatena literal y deja rutas como
        # "Soluciones\..\Negocio\X" sin resolver, rompiendo a herramientas downstream que
        # esperan una ruta absoluta limpia (ej. búsquedas de código, Test-Path).
        $projDir     = [System.IO.Path]::GetFullPath((Join-Path $slnDir (Split-Path $projRelPath -Parent)))
        $projCsproj  = [System.IO.Path]::GetFullPath((Join-Path $slnDir $projRelPath))
        $projectDirs += $projDir
        $projects    += @{ name = $projName; csproj = $projCsproj; dir = $projDir }
    }
}

# Inferir workspace (dos niveles arriba de la .sln si está en Batch\Soluciones\ o OnLine\Soluciones\)
$workspace = $slnDir
if ($SlnPath -match '\\(Batch|OnLine)\\Soluciones\\') {
    $workspace = (Get-Item $slnDir).Parent.Parent.FullName
}
# ServiceManager y sus módulos viven bajo OnLine\AISServiceManager\... (no en Soluciones\).
# El workspace (trunk) es la carpeta anterior a \OnLine\.
elseif ($SlnPath -match '\\OnLine\\AISServiceManager\\') {
    $workspace = $SlnPath.Substring(0, $SlnPath.IndexOf('\OnLine\'))
}

@{
    solution   = $slnName
    sln_path   = $SlnPath
    sln_dir    = $slnDir
    tipo       = $tipo
    workspace  = $workspace
    scope_dirs = $projectDirs
    projects   = $projects
    project_count = $projects.Count
} | ConvertTo-Json -Depth 4
