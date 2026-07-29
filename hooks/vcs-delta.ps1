<#
.SYNOPSIS
    Delta de commits entre dos fechas (SVN o Git, autodetectado) con los ficheros tocados y
    los IDs de tarea (Mantis/Jira) citados en los mensajes.

    Es la base de /rs-actualizador: "que ha cambiado en esta solucion desde la ultima entrega".
    A diferencia de svn-log/git-log (ultimos N commits, filtro por texto), aqui el filtro es
    POR RANGO DE FECHAS y POR RUTA, y devuelve tambien los ficheros modificados.

.PARAMETER Workspace
    Ruta raiz del proyecto (trunk).

.PARAMETER Desde
    Fecha de inicio (exclusiva en la practica: commits posteriores a la ultima entrega),
    formato yyyy-MM-dd o yyyy-MM-dd HH:mm:ss.

.PARAMETER Hasta
    Fecha de corte (incluida). Default: ahora. Sirve para entregar hasta una fecha X
    descartando desarrollos posteriores.

.PARAMETER Ruta
    Subruta relativa al workspace a la que limitar el delta (ej. "Batch\Soluciones\RSProcIN").
    Sin ella, todo el workspace.

.PARAMETER Limit
    Maximo de commits a devolver (default 500).

.EXAMPLE
    .\vcs-delta.ps1 "C:\SVN\RS\<Proyecto>\trunk" -Desde "2026-05-01"
    .\vcs-delta.ps1 "C:\Git\RS\<Proyecto>\trunk" -Desde "2026-05-01" -Hasta "2026-07-15" -Ruta "Batch\Soluciones\RSProcIN"
#>
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Desde,
    [string]$Hasta = "",
    [string]$Ruta = "",
    [int]$Limit = 500
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

if (-not (Test-Path $Workspace)) {
    @{ error = "Workspace no encontrado: $Workspace" } | ConvertTo-Json; exit 1
}
if (-not $Hasta) { $Hasta = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }

# Validar fechas antes de construir el rango (un rango invertido devuelve vacio en silencio)
try { $dDesde = [datetime]::Parse($Desde); $dHasta = [datetime]::Parse($Hasta) }
catch { @{ error = "Fechas invalidas (usa yyyy-MM-dd): Desde='$Desde' Hasta='$Hasta'" } | ConvertTo-Json; exit 1 }
if ($dHasta -lt $dDesde) {
    @{ error = "Rango invertido: Hasta ($Hasta) es anterior a Desde ($Desde)" } | ConvertTo-Json; exit 1
}

# --- Detectar VCS reutilizando el hook existente (no duplicar la logica de ascenso) ---
$detect = & (Join-Path $PSScriptRoot "detect-vcs.ps1") $Workspace | ConvertFrom-Json
$vcs  = $detect.vcs
$root = $detect.root
if ($vcs -eq "none") {
    @{ error = "No se detecto SVN ni Git bajo $Workspace"; vcs = "none" } | ConvertTo-Json; exit 1
}

$target = if ($Ruta) { Join-Path $Workspace $Ruta } else { $Workspace }
if ($Ruta -and !(Test-Path $target)) {
    @{ error = "Ruta no encontrada: $target"; vcs = $vcs } | ConvertTo-Json; exit 1
}

# IDs de tarea en el mensaje: #1234 (Mantis) y PROJ-123 (Jira)
function Get-Tareas([string]$msg) {
    $t = @()
    foreach ($m in [regex]::Matches($msg, '#(\d{2,7})\b'))            { $t += "#$($m.Groups[1].Value)" }
    foreach ($m in [regex]::Matches($msg, '\b([A-Z][A-Z0-9]{1,9}-\d{1,6})\b')) { $t += $m.Groups[1].Value }
    return ,@($t | Select-Object -Unique)
}

$commits = @()
$ficheros = @{}

if ($vcs -eq "svn") {
    try {
        $null = & svn --version --quiet 2>&1
        if ($LASTEXITCODE -ne 0) { @{ error = "SVN no disponible"; vcs = "svn" } | ConvertTo-Json; exit 1 }
    } catch { @{ error = "SVN no encontrado en PATH"; vcs = "svn" } | ConvertTo-Json; exit 1 }

    $rango = "{{$($dDesde.ToString('yyyy-MM-dd HH:mm:ss'))}}:{{$($dHasta.ToString('yyyy-MM-dd HH:mm:ss'))}}"
    $xml = & svn log $target --xml -v -r $rango --limit $Limit 2>&1
    if ($LASTEXITCODE -ne 0) {
        @{ error = "svn log fallo: $($xml -join ' ')"; vcs = "svn" } | ConvertTo-Json; exit 1
    }
    try { [xml]$logXml = ($xml -join "`n") }
    catch { @{ error = "Error parseando XML de svn log: $_"; vcs = "svn" } | ConvertTo-Json; exit 1 }

    foreach ($e in $logXml.log.logentry) {
        $msg = ($e.msg -as [string]).Trim()
        $raw = ($e.date -as [string]).Trim()
        $fecha = if ($raw.Length -ge 19) { $raw.Substring(0,19).Replace("T"," ") } else { $raw }
        $commits += [PSCustomObject]@{
            revision = "$($e.revision)"
            autor    = ($e.author -as [string]).Trim()
            fecha    = $fecha
            mensaje  = $msg
            tareas   = Get-Tareas $msg
        }
        foreach ($p in $e.paths.path) {
            $ruta = ($p.'#text' -as [string]).Trim()
            if ($ruta) { $ficheros[$ruta] = ($p.action -as [string]) }
        }
    }
}
else {
    try {
        $null = & git --version 2>&1
        if ($LASTEXITCODE -ne 0) { @{ error = "Git no disponible"; vcs = "git" } | ConvertTo-Json; exit 1 }
    } catch { @{ error = "Git no encontrado en PATH"; vcs = "git" } | ConvertTo-Json; exit 1 }

    $sep = "%x1f"   # separador de campos: unit separator (no aparece en mensajes)
    $fmt = "%h$sep%an$sep%ad$sep%s"
    $args = @("-C", $root, "log", "--no-merges", "-n", "$Limit",
              "--since=$($dDesde.ToString('yyyy-MM-dd HH:mm:ss'))",
              "--until=$($dHasta.ToString('yyyy-MM-dd HH:mm:ss'))",
              "--date=format:%Y-%m-%d %H:%M:%S", "--pretty=format:$fmt", "--name-status")
    if ($Ruta) { $args += @("--", $Ruta.Replace('\','/')) }

    $out = & git @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        @{ error = "git log fallo: $($out -join ' ')"; vcs = "git" } | ConvertTo-Json; exit 1
    }

    foreach ($linea in $out) {
        $l = "$linea"
        if ($l -match "\u001f") {
            $c = $l -split "\u001f"
            $msg = $c[3]
            $commits += [PSCustomObject]@{
                revision = $c[0]; autor = $c[1]; fecha = $c[2]; mensaje = $msg; tareas = Get-Tareas $msg
            }
        }
        elseif ($l -match '^([AMDRT])\d*\s+(.+)$') {
            # R/C llevan origen y destino separados por tab: quedarse con el destino
            $accion = $Matches[1]
            $path   = ($Matches[2] -split "`t")[-1]
            $ficheros[$path] = $accion
        }
    }
}

$listaFicheros = @($ficheros.Keys | Sort-Object | ForEach-Object {
    [PSCustomObject]@{ path = $_; accion = $ficheros[$_] }
})
$tareas = @($commits | ForEach-Object { $_.tareas } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)

@{
    vcs            = $vcs
    root           = $root
    workspace      = $Workspace
    ruta           = $Ruta
    desde          = $dDesde.ToString("yyyy-MM-dd HH:mm:ss")
    hasta          = $dHasta.ToString("yyyy-MM-dd HH:mm:ss")
    limit          = $Limit
    total_commits  = $commits.Count
    total_ficheros = $listaFicheros.Count
    truncado       = ($commits.Count -ge $Limit)
    commits        = $commits
    ficheros       = $listaFicheros
    tareas         = $tareas
} | ConvertTo-Json -Depth 5
