<#
.SYNOPSIS
    Obtiene el historial de commits Git de un workspace como JSON estructurado. Espejo de svn-log.ps1.

.PARAMETER Workspace
    Ruta raíz del proyecto (repo Git o subcarpeta dentro de él).

.PARAMETER Solution
    Filtrar entradas cuyo mensaje contenga este texto (opcional).

.PARAMETER Limit
    Número máximo de entradas a devolver (defecto: 10).

.EXAMPLE
    .\git-log.ps1 "C:\Git\RS\<Proyecto>\trunk"
    .\git-log.ps1 "C:\Git\RS\<Proyecto>\trunk" -Solution "RSProcIN" -Limit 20
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$Solution = "",
    [int]$Limit = 10
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
# Verificar Git disponible
try {
    $null = & git --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        @{ error = "Git no disponible" } | ConvertTo-Json; exit 1
    }
} catch {
    @{ error = "Git no encontrado en PATH" } | ConvertTo-Json; exit 1
}

# %x1f (unit separator) entre campos, %x1e (record separator) entre commits — evita colisión con
# "|" u otros caracteres que puedan aparecer dentro del mensaje de commit.
$format = "%h%x1f%an%x1f%ad%x1f%s%x1e"
$logOutput = & git -C $Workspace log -n $Limit "--pretty=format:$format" --date=format:"%Y-%m-%d %H:%M:%S" 2>&1
if ($LASTEXITCODE -ne 0) {
    @{ error = "git log falló: $($logOutput -join ' ')" } | ConvertTo-Json; exit 1
}

$raw = ($logOutput -join "`n")
$records = $raw -split "`u{001e}" | Where-Object { $_.Trim() -ne "" }

$entries = @()
foreach ($rec in $records) {
    $fields = $rec -split "`u{001f}"
    if ($fields.Count -lt 4) { continue }
    $msg = $fields[3].Trim()

    # Filtro por solución si se especifica
    if ($Solution -and $msg -notmatch [regex]::Escape($Solution)) { continue }

    $entries += [PSCustomObject]@{
        revision = $fields[0].Trim()   # hash corto — equivalente al nº de revisión SVN
        author   = $fields[1].Trim()
        date     = $fields[2].Trim()
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
