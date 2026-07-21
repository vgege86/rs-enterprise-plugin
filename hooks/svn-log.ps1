<#
.SYNOPSIS
    Obtiene el historial de commits SVN de un workspace como JSON estructurado.

.PARAMETER Workspace
    Ruta raíz del proyecto.

.PARAMETER Solution
    Filtrar entradas cuyo mensaje contenga este texto (opcional).

.PARAMETER Limit
    Número máximo de entradas a devolver (defecto: 10).

.EXAMPLE
    .\svn-log.ps1 "C:\SVN\RS\<Proyecto>\trunk"
    .\svn-log.ps1 "C:\SVN\RS\<Proyecto>\trunk" -Solution "RSProcIN" -Limit 20
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$Solution = "",
    [int]$Limit = 10
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
# Verificar SVN disponible
try {
    $null = & svn --version --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        @{ error = "SVN no disponible" } | ConvertTo-Json; exit 1
    }
} catch {
    @{ error = "SVN no encontrado en PATH" } | ConvertTo-Json; exit 1
}

# Ejecutar svn log con salida XML
$xmlOutput = & svn log $Workspace --xml --limit $Limit 2>&1
if ($LASTEXITCODE -ne 0) {
    @{ error = "svn log falló: $($xmlOutput -join ' ')" } | ConvertTo-Json; exit 1
}

# Parsear XML
try {
    [xml]$logXml = ($xmlOutput -join "`n")
} catch {
    @{ error = "Error parseando XML de svn log: $_" } | ConvertTo-Json; exit 1
}

$entries = @()
foreach ($entry in $logXml.log.logentry) {
    $msg = ($entry.msg -as [string]).Trim()

    # Filtro por solución si se especifica
    if ($Solution -and $msg -notmatch [regex]::Escape($Solution)) { continue }

    $rawDate = ($entry.date -as [string]).Trim()
    $date    = if ($rawDate.Length -ge 19) { $rawDate.Substring(0,19).Replace("T"," ") } else { $rawDate }

    $entries += [PSCustomObject]@{
        revision = [int]$entry.revision
        author   = ($entry.author -as [string]).Trim()
        date     = $date
        message  = $msg
    }
}

@{
    workspace        = $Workspace
    solution_filter  = $Solution
    limit            = $Limit
    total            = $entries.Count
    entries          = $entries
} | ConvertTo-Json -Depth 4
