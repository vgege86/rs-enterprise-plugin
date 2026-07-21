<#
.SYNOPSIS
    Obtiene el estado SVN del workspace y lo devuelve como JSON.
.PARAMETER workspace
    Ruta del workspace.
.PARAMETER scopePaths
    Paths de scope para filtrar, separados por punto y coma (opcional).
    Si se omite, devuelve todos los cambios del workspace.
.EXAMPLE
    .\svn-diff.ps1 "C:\SVN\RS\<Proyecto>\trunk"
    .\svn-diff.ps1 "C:\SVN\RS\<Proyecto>\trunk" "Batch\Soluciones\RSProcIN;Batch\Soluciones\RSProcIN"
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$workspace,

    [string]$scopePaths = ""
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
# Patrones a ignorar siempre
$ignorePatterns = @(
    '\\bin\\', '\\obj\\', '\\.vs\\',
    '\.user$', '\.suo$', '\\packages\\'
)

# Verificar SVN disponible
try {
    $null = & svn --version --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        @{ error = "SVN no disponible" } | ConvertTo-Json
        exit 1
    }
} catch {
    @{ error = "SVN no encontrado en PATH" } | ConvertTo-Json
    exit 1
}

# Ejecutar svn status
$svnOutput = & svn status $workspace 2>&1
if ($LASTEXITCODE -ne 0) {
    @{ error = "svn status falló: $svnOutput" } | ConvertTo-Json
    exit 1
}

# Parsear scope paths si se proporcionaron
$scopeList = @()
if ($scopePaths) {
    $scopeList = $scopePaths -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
}

# Parsear cada línea de svn status
$changes = @()
foreach ($line in ($svnOutput -split "`n")) {
    $line = $line.TrimEnd()
    if ($line.Length -lt 2) { continue }

    $statusChar = $line[0].ToString()
    if ($statusChar -notmatch '[MADC?!]') { continue }

    $filePath = $line.Substring(1).Trim()

    # Aplicar filtros de ignorar
    $shouldIgnore = $false
    foreach ($pattern in $ignorePatterns) {
        if ($filePath -match $pattern) { $shouldIgnore = $true; break }
    }
    if ($shouldIgnore) { continue }

    # Aplicar filtro de scope si se proporcionó
    if ($scopeList.Count -gt 0) {
        $inScope = $false
        foreach ($scope in $scopeList) {
            $fullScopePath = Join-Path $workspace $scope
            if ($filePath.StartsWith($fullScopePath, [System.StringComparison]::OrdinalIgnoreCase) -or
                $filePath.StartsWith($scope, [System.StringComparison]::OrdinalIgnoreCase)) {
                $inScope = $true
                break
            }
        }
        if (-not $inScope) { continue }
    }

    # Inferir proyecto (primeras 2-3 carpetas del path relativo)
    $relativePath = $filePath.Replace($workspace, "").TrimStart("\")
    $parts = $relativePath -split "\\"
    $project = if ($parts.Count -ge 3) { "$($parts[0])\$($parts[1])\$($parts[2])" } else { $parts[0..1] -join "\" }

    $changes += [PSCustomObject]@{
        status   = $statusChar
        path     = $filePath
        relative = $relativePath
        project  = $project
    }
}

# Agrupar por status
$grouped = $changes | Group-Object status | ForEach-Object {
    @{
        status = $_.Name
        label  = switch ($_.Name) {
            'M' { 'Modificado' }
            'A' { 'Añadido' }
            'D' { 'Eliminado' }
            '?' { 'Sin versionar' }
            '!' { 'Faltante' }
            'C' { 'Conflicto' }
            default { $_.Name }
        }
        count  = $_.Count
        files  = @($_.Group | Select-Object -ExpandProperty relative)
    }
}

# Agrupar por proyecto
$byProject = $changes | Group-Object project | ForEach-Object {
    @{
        project = $_.Name
        count   = $_.Count
        files   = @($_.Group | Select-Object relative, status)
    }
}

# Ficheros sin versionar que necesitan svn add antes de commit
$unversioned = @($changes | Where-Object { $_.status -eq '?' } | Select-Object -ExpandProperty relative)

@{
    workspace              = $workspace
    scope_filter           = $scopePaths
    timestamp              = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    total                  = $changes.Count
    has_conflicts          = ($changes | Where-Object { $_.status -eq 'C' }).Count -gt 0
    unversioned_pending_add = $unversioned
    needs_svn_add          = ($unversioned.Count -gt 0)
    by_status              = $grouped
    by_project             = $byProject
    changes                = @($changes | Select-Object status, relative, project)
} | ConvertTo-Json -Depth 5
