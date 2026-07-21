<#
.SYNOPSIS
    Retira los restos de la instalación manual PRE-PLUGIN que sombrean al plugin.

.DESCRIPTION
    `install-hooks.ps1` (obsoleto desde v2.11.0) copiaba agentes a ~/.claude/agents/, comandos a
    ~/.claude/commands/ y una copia vendorizada del server MCP a ~/.claude/rs-skill-full/.
    Esas copias NO se actualizan con `/plugin marketplace update` y GANAN al plugin: el pipeline
    acaba ejecutando etapas obsoletas (un planner que no emite PLAN/STAGES ⇒ el Gate A de aprobación
    se salta en silencio). Ver CHANGELOG 2.11.0.

    Este script NO BORRA NADA: mueve a ~/.claude/_backup-preplugin-<fecha>/.

    Desde v2.14.0 los agentes declaran `mcp__plugin_rs-enterprise-agent_rs-workspace__*` en su
    `tools:` — nombre que aporta el propio plugin vía `.mcp.json`. El registro global manual
    `rs-workspace` de ~/.claude.json ya no lo necesita nadie y además arrastra una ruta absoluta al
    árbol fuente de quien lo creó, así que se ELIMINA (con backup previo de ~/.claude.json).

.PARAMETER WhatIf
    Muestra lo que haría, sin tocar nada.

.PARAMETER Quiet
    Sin salida si no hay nada que limpiar (modo hook).
#>
param(
    [switch]$WhatIf,
    [switch]$Quiet
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$claudeHome = Join-Path $env:USERPROFILE ".claude"
$claudeJson = Join-Path $env:USERPROFILE ".claude.json"
$settings   = Join-Path $claudeHome "settings.json"
$marker     = Join-Path $claudeHome ".rs-preplugin-cleaned"

# ── Detección (barata: solo Test-Path) ───────────────────────────────────────
$shadowDirs  = @()
$shadowFiles = @{}

foreach ($pair in @(@{D="agents"; G="rs-*.md"}, @{D="commands"; G="rs-*.md"})) {
    $p = Join-Path $claudeHome $pair.D
    if (Test-Path $p) {
        $f = @(Get-ChildItem -Path $p -Filter $pair.G -File -ErrorAction SilentlyContinue)
        if ($f.Count -gt 0) { $shadowFiles[$pair.D] = $f }
    }
}
foreach ($d in @("rs-skill-full", "hooks\rs", "hooks\scripts")) {
    $p = Join-Path $claudeHome $d
    if (Test-Path $p) { $shadowDirs += $p }
}

# Cualquier registro global `rs-workspace` es residuo pre-plugin: el server lo aporta el propio
# plugin vía .mcp.json, con el nombre namespaced. El manual solo puede apuntar a un árbol ajeno.
$mcpManual = $false
if (Test-Path $claudeJson) {
    try {
        $cjRaw = Get-Content $claudeJson -Raw -Encoding UTF8
        if (($cjRaw | ConvertFrom-Json).mcpServers.'rs-workspace') { $mcpManual = $true }
    } catch { }
}

# Solo cuentan los hooks cuyo comando apunta a la copia vendorizada. Buscar la cadena suelta en
# todo el fichero da falsos positivos: hay rutas legítimas al árbol fuente en `permissions` y en
# `extraKnownMarketplaces`.
$dupHooks = $false
if (Test-Path $settings) {
    try {
        $sj = Get-Content $settings -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($sj.hooks) {
            foreach ($evt in $sj.hooks.PSObject.Properties.Name) {
                foreach ($entry in @($sj.hooks.$evt)) {
                    foreach ($h in @($entry.hooks)) {
                        if ("$($h.command)" -match '(?i)\.claude\\rs-skill-full') { $dupHooks = $true }
                    }
                }
            }
        }
    } catch { }
}

if ($shadowFiles.Count -eq 0 -and $shadowDirs.Count -eq 0 -and -not $mcpManual -and -not $dupHooks) {
    if (-not $WhatIf) { Set-Content -Path $marker -Value (Get-Date -Format s) -Encoding UTF8 }
    if (-not $Quiet) { Write-Output "Sin restos pre-plugin. Nada que limpiar." }
    exit 0
}

# ── Acción ───────────────────────────────────────────────────────────────────
$backup = Join-Path $claudeHome ("_backup-preplugin-" + (Get-Date -Format "yyyy-MM-dd"))
$acciones = @()

if (-not $WhatIf) { New-Item -ItemType Directory -Path $backup -Force | Out-Null }

# Nunca pisar una copia previa: si ya existe ese .bak, guardar con sufijo.
function Backup-File([string]$Origen, [string]$Nombre) {
    $dest = Join-Path $backup $Nombre
    if (Test-Path $dest) {
        $dest = Join-Path $backup ("{0}.{1}" -f $Nombre, (Get-Date -Format "HHmmss"))
    }
    Copy-Item $Origen $dest -Force
}

# Validacion estructural de JSON sin ConvertFrom-Json (aborta con claves que solo difieren en
# mayusculas) ni Test-Json (no existe en Windows PowerShell 5.1, que es quien ejecuta los hooks):
# llaves/corchetes balanceados fuera de cadenas y sin coma colgante antes de un cierre.
function Test-JsonEstructura([string]$Texto) {
    $pila = New-Object System.Collections.Stack
    $enCadena = $false; $escape = $false; $ultimoSignificativo = ''
    foreach ($c in $Texto.ToCharArray()) {
        if ($escape) { $escape = $false; continue }
        if ($c -eq '\') { $escape = $true; continue }
        if ($c -eq '"') { $enCadena = -not $enCadena; $ultimoSignificativo = '"'; continue }
        if ($enCadena) { continue }
        switch ($c) {
            '{' { $pila.Push('{') }
            '[' { $pila.Push('[') }
            '}' {
                if ($ultimoSignificativo -eq ',') { return $false }
                if ($pila.Count -eq 0 -or $pila.Pop() -ne '{') { return $false }
            }
            ']' {
                if ($ultimoSignificativo -eq ',') { return $false }
                if ($pila.Count -eq 0 -or $pila.Pop() -ne '[') { return $false }
            }
        }
        if ($c -notmatch '\s') { $ultimoSignificativo = $c }
    }
    return (-not $enCadena -and $pila.Count -eq 0)
}

foreach ($k in $shadowFiles.Keys) {
    $dest = Join-Path $backup $k
    $acciones += "mover $($shadowFiles[$k].Count) ficheros de $claudeHome\$k → $dest"
    if (-not $WhatIf) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        $shadowFiles[$k] | ForEach-Object {
            # Nunca pisar un backup anterior: si ya existe ese nombre, desambiguar.
            $d = Join-Path $dest $_.Name
            if (Test-Path $d) { $d = "$d." + (Get-Date -Format "HHmmss") }
            Move-Item $_.FullName $d -Force
        }
    }
}
foreach ($d in $shadowDirs) {
    $dest = Join-Path $backup (Split-Path $d -Leaf)
    if (Test-Path $dest) { $dest = "$dest-" + [guid]::NewGuid().ToString("N").Substring(0,6) }
    $acciones += "mover $d → $dest"
    if (-not $WhatIf) { Move-Item $d $dest -Force }
}

if ($mcpManual) {
    $acciones += "eliminar el registro global MCP rs-workspace de .claude.json (lo aporta el plugin)"
    if (-not $WhatIf) {
        Backup-File $claudeJson "claude.json.bak"
        # Edición TEXTUAL, no ConvertFrom-Json: .claude.json tiene claves que solo difieren en
        # mayúsculas y el parser de PowerShell aborta con "keys with different casing".
        $t   = Get-Content $claudeJson -Raw -Encoding UTF8
        $ini = $t.IndexOf('"rs-workspace"')
        $abre = if ($ini -ge 0) { $t.IndexOf('{', $ini) } else { -1 }
        if ($abre -lt 0) {
            $acciones += "⛔ No se localiza el bloque rs-workspace — eliminacion manual necesaria"
        } else {
            # Recorrer hasta la llave de cierre emparejada (ignorando llaves dentro de cadenas).
            $nivel = 0; $fin = -1; $enCadena = $false; $escape = $false
            for ($i = $abre; $i -lt $t.Length; $i++) {
                $c = $t[$i]
                if ($escape) { $escape = $false; continue }
                if ($c -eq '\') { $escape = $true; continue }
                if ($c -eq '"') { $enCadena = -not $enCadena; continue }
                if ($enCadena) { continue }
                if ($c -eq '{') { $nivel++ }
                elseif ($c -eq '}') { $nivel--; if ($nivel -eq 0) { $fin = $i; break } }
            }
            if ($fin -lt 0) {
                $acciones += "⛔ Bloque rs-workspace sin cierre — eliminacion manual necesaria"
            } else {
                # Absorber la coma contigua (la de después si la hay, si no la de antes).
                $desde = $ini; $hasta = $fin + 1
                while ($hasta -lt $t.Length -and $t[$hasta] -match '\s') { $hasta++ }
                if ($hasta -lt $t.Length -and $t[$hasta] -eq ',') { $hasta++ }
                else {
                    $p = $desde - 1
                    while ($p -ge 0 -and $t[$p] -match '\s') { $p-- }
                    if ($p -ge 0 -and $t[$p] -eq ',') { $desde = $p }
                }
                $t2 = $t.Substring(0, $desde) + $t.Substring($hasta)
                if (Test-JsonEstructura $t2) {
                    Set-Content $claudeJson -Value $t2 -Encoding UTF8 -NoNewline
                } else {
                    $acciones += "⛔ JSON invalido tras eliminar — NO escrito (.claude.json intacto)"
                }
            }
        }
    }
}

if ($dupHooks) {
    $acciones += "quitar hooks duplicados de settings.json (ya los declara plugin.json)"
    if (-not $WhatIf) {
        Backup-File $settings "settings.json.bak"
        $s = Get-Content $settings -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($s.hooks) {
            $nuevos = @{}
            foreach ($evt in $s.hooks.PSObject.Properties.Name) {
                $keep = @()
                foreach ($entry in @($s.hooks.$evt)) {
                    $subs = @($entry.hooks | Where-Object { "$($_.command)" -notmatch '(?i)\.claude\\rs-skill-full' })
                    if ($subs.Count -gt 0) { $entry.hooks = $subs; $keep += $entry }
                }
                if ($keep.Count -gt 0) { $nuevos[$evt] = $keep }
            }
            if ($nuevos.Count -gt 0) { $s.hooks = [PSCustomObject]$nuevos }
            else { $s.PSObject.Properties.Remove("hooks") }
            $s | ConvertTo-Json -Depth 20 | Set-Content $settings -Encoding UTF8
        }
    }
}

if (-not $WhatIf) { Set-Content -Path $marker -Value (Get-Date -Format s) -Encoding UTF8 }

# ── Informe ──────────────────────────────────────────────────────────────────
$verbo = if ($WhatIf) { "SE HARIA" } else { "HECHO" }
Write-Output "── Limpieza instalacion pre-plugin RS ($verbo) ──"
$acciones | ForEach-Object { Write-Output "  · $_" }
if (-not $WhatIf) { Write-Output "  Backup en: $backup  (nada se ha borrado)" }
Write-Output "  ⚠️ REINICIA Claude Code: agentes y servidores MCP se resuelven al arrancar."
