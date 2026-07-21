<#
.SYNOPSIS
    Obtiene el estado Git del workspace y lo devuelve como JSON. Espejo de svn-diff.ps1.
.PARAMETER workspace
    Ruta del workspace (raíz del repo o subcarpeta dentro de él).
.PARAMETER scopePaths
    Paths de scope para filtrar, separados por punto y coma (opcional).
    Si se omite, devuelve todos los cambios del workspace.
.EXAMPLE
    .\git-status.ps1 "C:\Git\RS\<Proyecto>\trunk"
    .\git-status.ps1 "C:\Git\RS\<Proyecto>\trunk" "Batch\Soluciones\RSProcIN"
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

# Verificar Git disponible
try {
    $null = & git --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        @{ error = "Git no disponible" } | ConvertTo-Json
        exit 1
    }
} catch {
    @{ error = "Git no encontrado en PATH" } | ConvertTo-Json
    exit 1
}

# Rutas de "git status --porcelain" son relativas a la raíz del repo, NO al cwd de invocación
# (a diferencia de "svn status <ruta>") — resolver la raíz real en vez de asumir que es $workspace.
$repoRoot = (& git -C $workspace rev-parse --show-toplevel 2>&1)
if ($LASTEXITCODE -ne 0) {
    @{ error = "No es un repo Git o git no disponible: $repoRoot" } | ConvertTo-Json
    exit 1
}
$repoRoot = ($repoRoot -join "").Trim() -replace '/', '\'

# git status --porcelain=v1 -z: separador NUL — evita problemas con rutas que traen "-> " en renames.
$gitOutput = & git -C $workspace status --porcelain=v1 -z 2>&1
if ($LASTEXITCODE -ne 0) {
    @{ error = "git status falló: $gitOutput" } | ConvertTo-Json
    exit 1
}

# Parsear scope paths si se proporcionaron
$scopeList = @()
if ($scopePaths) {
    $scopeList = $scopePaths -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
}

# -z separa entradas por NUL; una entrada de rename trae DOS rutas seguidas (origen, destino) — se
# consumen ambas del mismo array para no desalinear el resto del parseo.
$rawEntries = ($gitOutput -join "`0") -split "`0" | Where-Object { $_ -ne "" }

$changes = @()
$idx = 0
while ($idx -lt $rawEntries.Count) {
    $entry = $rawEntries[$idx]
    if ($entry.Length -lt 3) { $idx++; continue }

    $xy       = $entry.Substring(0, 2)
    $filePath = $entry.Substring(3)
    $isRename = ($xy[0] -eq 'R' -or $xy[1] -eq 'R')
    if ($isRename) {
        # La entrada de rename no trae "->" en -z: la ruta destino es este elemento,
        # la ruta origen es el SIGUIENTE elemento del array.
        $idx++
        if ($idx -lt $rawEntries.Count) { $filePath = $rawEntries[$idx] }
    }

    # Mapear XY (staged/worktree) a un único carácter, mismo vocabulario que SVN
    $statusChar = switch -Regex ($xy) {
        'U'        { 'C'; break }  # conflicto sin resolver (UU, AA, DD, etc.)
        '\?\?'     { '?'; break }  # sin trackear
        '.*A.*'    { 'A'; break }
        '.*D.*'    { 'D'; break }
        '.*R.*'    { 'R'; break }
        default    { 'M' }
    }

    $filePath = $filePath -replace '/', '\'
    $fullPath = Join-Path $repoRoot $filePath

    # Aplicar filtros de ignorar
    $shouldIgnore = $false
    foreach ($pattern in $ignorePatterns) {
        if ($filePath -match $pattern) { $shouldIgnore = $true; break }
    }
    if (-not $shouldIgnore) {
        # Aplicar filtro de scope si se proporcionó
        $inScope = ($scopeList.Count -eq 0)
        foreach ($scope in $scopeList) {
            if ($filePath.StartsWith($scope, [System.StringComparison]::OrdinalIgnoreCase)) { $inScope = $true; break }
        }
        if ($inScope) {
            $parts   = $filePath -split "[\\/]"
            $project = if ($parts.Count -ge 3) { "$($parts[0])\$($parts[1])\$($parts[2])" } else { $parts[0..([Math]::Min(1,$parts.Count-1))] -join "\" }

            $changes += [PSCustomObject]@{
                status   = $statusChar
                path     = $fullPath
                relative = $filePath
                project  = $project
            }
        }
    }

    $idx++
}

# Agrupar por status
$grouped = $changes | Group-Object status | ForEach-Object {
    @{
        status = $_.Name
        label  = switch ($_.Name) {
            'M' { 'Modificado' }
            'A' { 'Añadido' }
            'D' { 'Eliminado' }
            '?' { 'Sin trackear' }
            'R' { 'Renombrado' }
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

# Ficheros sin trackear que necesitan git add antes de commit
$untracked = @($changes | Where-Object { $_.status -eq '?' } | Select-Object -ExpandProperty relative)

@{
    workspace          = $workspace
    scope_filter       = $scopePaths
    timestamp          = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    total              = $changes.Count
    has_conflicts      = ($changes | Where-Object { $_.status -eq 'C' }).Count -gt 0
    untracked_pending_add = $untracked
    needs_add          = ($untracked.Count -gt 0)
    by_status          = $grouped
    by_project         = $byProject
    changes            = @($changes | Select-Object status, relative, project)
} | ConvertTo-Json -Depth 5
