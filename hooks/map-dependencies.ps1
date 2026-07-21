<#
.SYNOPSIS
    Mapea dependencias entre soluciones del workspace.
    Detecta proyectos compartidos (DALC, Bus, Common) usados por múltiples soluciones.
    Útil para evaluar el impacto real de cambiar un proyecto compartido.

.PARAMETER Workspace
    Ruta raíz del proyecto (carpeta trunk).

.EXAMPLE
    .\map-dependencies.ps1 "C:\SVN\RS\<Proyecto>\trunk"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

# Buscar todas las .sln bajo Batch\Soluciones y OnLine\Soluciones
# (AISServiceManager: host + ArqNet + Modulos viven fuera de \Soluciones\ — incluir explícito)
$searchDirs = @(
    (Join-Path $Workspace "Batch\Soluciones"),
    (Join-Path $Workspace "OnLine\Soluciones"),
    (Join-Path $Workspace "OnLine\AISServiceManager"),
    (Join-Path $Workspace "Batch"),
    (Join-Path $Workspace "OnLine")
)

$slnFiles = @()
foreach ($dir in $searchDirs) {
    if (Test-Path $dir) {
        $found = Get-ChildItem $dir -Filter "*.sln" -Recurse -Depth 3 -ErrorAction SilentlyContinue
        foreach ($f in $found) {
            if ($f.FullName -notmatch '\\(bin|obj|\.vs|packages)\\') { $slnFiles += $f }
        }
    }
}

if ($slnFiles.Count -eq 0) {
    @{ success = $false; error = "No se encontraron archivos .sln bajo $Workspace" } | ConvertTo-Json; exit 1
}

# Parsear cada .sln: extraer proyectos
function Get-SlnProjects([string]$slnPath) {
    $projects = @()
    $lines = Get-Content $slnPath -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        # Project("{...}") = "NombreProyecto", "ruta\relativa\proyecto.csproj", "{GUID}"
        if ($line -match 'Project\("[^"]+"\)\s*=\s*"([^"]+)"\s*,\s*"([^"]+\.csproj)"') {
            $projects += [PSCustomObject]@{
                name    = $Matches[1].Trim()
                relPath = $Matches[2].Trim().Replace("/","\")
                absPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $slnPath -Parent) $Matches[2].Trim().Replace("/","\")))
            }
        }
    }
    return $projects
}

# Parsear .csproj: extraer ProjectReferences
function Get-ProjectRefs([string]$csprojPath) {
    $refs = @()
    if (-not (Test-Path $csprojPath)) { return $refs }
    $content = Get-Content $csprojPath -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
    $regex = [regex]'<ProjectReference\s+Include="([^"]+\.csproj)"'
    foreach ($m in $regex.Matches($content)) {
        $refPath = $m.Groups[1].Value.Replace("/","\")
        $absRef  = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $csprojPath -Parent) $refPath))
        $refs += $absRef
    }
    return $refs
}

# Parsear NuGet packages de .csproj
function Get-NugetPackages([string]$csprojPath) {
    $pkgs = @()
    if (-not (Test-Path $csprojPath)) { return $pkgs }
    $content = Get-Content $csprojPath -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
    $regex = [regex]'<PackageReference\s+Include="([^"]+)"\s+Version="([^"]+)"'
    foreach ($m in $regex.Matches($content)) {
        $pkgs += [PSCustomObject]@{ name = $m.Groups[1].Value; version = $m.Groups[2].Value }
    }
    return $pkgs
}

# Construir mapa
$solutions       = @{}  # slnName → { tipo, projects[], project_refs[] }
$sharedProjects  = @{}  # absPath → { name, used_by[] }
$nugetVersions   = @{}  # "PackageName" → { "Version" → [slnName] }

foreach ($sln in $slnFiles) {
    $slnName  = [System.IO.Path]::GetFileNameWithoutExtension($sln.FullName)
    $relSln   = $sln.FullName.Replace($Workspace,"").TrimStart("\")
    $tipo     = if ($relSln -match '^Batch') { "Batch" } elseif ($relSln -match '^OnLine') { "Online" } else { "Unknown" }
    $projects = Get-SlnProjects $sln.FullName

    $allRefs = @()
    foreach ($proj in $projects) {
        $refs = Get-ProjectRefs $proj.absPath
        foreach ($ref in $refs) {
            $refName = [System.IO.Path]::GetFileNameWithoutExtension($ref)
            $refRel  = $ref.Replace($Workspace,"").TrimStart("\")
            $allRefs += [PSCustomObject]@{ name = $refName; path = $refRel; abs = $ref }

            # Registrar en sharedProjects
            if (-not $sharedProjects[$ref]) {
                $sharedProjects[$ref] = @{ name = $refName; path = $refRel; used_by = @() }
            }
            if ($slnName -notin $sharedProjects[$ref].used_by) {
                $sharedProjects[$ref].used_by += $slnName
            }
        }

        # NuGet packages
        $pkgs = Get-NugetPackages $proj.absPath
        foreach ($pkg in $pkgs) {
            $key = $pkg.name
            if (-not $nugetVersions[$key]) { $nugetVersions[$key] = @{} }
            if (-not $nugetVersions[$key][$pkg.version]) { $nugetVersions[$key][$pkg.version] = @() }
            if ($slnName -notin $nugetVersions[$key][$pkg.version]) {
                $nugetVersions[$key][$pkg.version] += $slnName
            }
        }
    }

    $solutions[$slnName] = [PSCustomObject]@{
        name          = $slnName
        tipo          = $tipo
        path          = $relSln
        project_count = $projects.Count
        projects      = @($projects | Select-Object name, relPath)
        refs          = @($allRefs | Select-Object name, path -Unique)
    }
}

# Filtrar solo proyectos realmente compartidos (usados por >1 solución)
$shared = @($sharedProjects.Values | Where-Object { $_.used_by.Count -gt 1 } | ForEach-Object {
    [PSCustomObject]@{ name = $_.name; path = $_.path; used_by = $_.used_by; impact = $_.used_by.Count }
} | Sort-Object impact -Descending)

# Detectar conflictos de versión NuGet (mismo paquete, versiones distintas)
$versionConflicts = @()
foreach ($pkg in $nugetVersions.Keys) {
    if ($nugetVersions[$pkg].Count -gt 1) {
        $versions = $nugetVersions[$pkg].Keys | ForEach-Object {
            [PSCustomObject]@{ version = $_; solutions = $nugetVersions[$pkg][$_] }
        }
        $versionConflicts += [PSCustomObject]@{ package = $pkg; versions = @($versions) }
    }
}

@{
    success           = $true
    workspace         = $Workspace
    solution_count    = $solutions.Count
    solutions         = @($solutions.Values | Sort-Object tipo, name)
    shared_projects   = $shared
    version_conflicts = $versionConflicts
    has_shared        = ($shared.Count -gt 0)
    has_conflicts     = ($versionConflicts.Count -gt 0)
} | ConvertTo-Json -Depth 6
