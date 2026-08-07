<#
.SYNOPSIS
    Escanea el código de una solución buscando patrones de seguridad conocidos.
    Detecta: SQL injection, credenciales hardcodeadas, XSS básico, input sin validar.

.PARAMETER SlnPath
    Ruta completa al archivo .sln

.EXAMPLE
    .\security-scan.ps1 "C:\...\trunk\OnLine\Soluciones\AgendaWeb\AgendaWeb.sln"
#>
param(
    [Parameter(Mandatory=$true)][string]$SlnPath
)


$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
$hooksDir = Split-Path $PSCommandPath -Parent
. (Join-Path $hooksDir "lib-buscar.ps1")

# Obtener scope via parse-sln
$scopeJson = & "$hooksDir\parse-sln.ps1" $SlnPath | ConvertFrom-Json
if ($scopeJson.error) {
    @{ success = $false; error = $scopeJson.error } | ConvertTo-Json; exit 1
}

$scopeDirs = @($scopeJson.scope_dirs)
$tipo      = $scopeJson.tipo

# Patrones de seguridad
$patterns = @(
    # SQL Injection — concatenación de strings en queries
    @{
        id       = "SQL_INJECT_01"
        severity = "critical"
        desc     = "Posible SQL Injection — concatenación de string en query"
        regex    = '("|\+)\s*(SELECT|INSERT|UPDATE|DELETE|EXEC)\s|\.ExecuteNonQuery\(|\.ExecuteScalar\(|\.ExecuteReader\('
        ext      = @('.cs')
        context  = "Usar parámetros (@param) en lugar de concatenación de strings en queries SQL."
    },
    @{
        id       = "SQL_INJECT_02"
        severity = "critical"
        desc     = "Query SQL construida con string.Format o interpolación"
        regex    = 'string\.Format\s*\(\s*"[^"]*(?:SELECT|INSERT|UPDATE|DELETE|WHERE)[^"]*"'
        ext      = @('.cs')
        context  = "Usar SqlParameter o queries parametrizadas."
    },
    # Credenciales hardcodeadas
    @{
        id       = "HARDCRED_01"
        severity = "high"
        desc     = "Posible contraseña hardcodeada"
        regex    = '(?i)(password|contraseña|pwd|pass)\s*=\s*"[^"]{3,}"'
        ext      = @('.cs', '.config', '.xml')
        context  = "Mover credenciales a .rs-databases.json o a variables de entorno."
    },
    @{
        id       = "HARDCRED_02"
        severity = "high"
        desc     = "Cadena de conexión con credenciales en código"
        regex    = '(?i)new\s+SqlConnection\s*\(\s*"[^"]*password'
        ext      = @('.cs')
        context  = "Leer connectionString desde .rs-databases.json, no hardcodear."
    },
    # XSS — solo Online
    @{
        id       = "XSS_01"
        severity = "high"
        desc     = "Posible XSS — Response.Write sin encoding"
        regex    = 'Response\.Write\s*\('
        ext      = @('.cs', '.aspx')
        context  = "Usar Server.HtmlEncode() o HttpUtility.HtmlEncode() antes de escribir input de usuario."
        onlineOnly = $true
    },
    @{
        id       = "XSS_02"
        severity = "medium"
        desc     = "Output directo de Request sin encoding"
        regex    = '<%=\s*Request\.(QueryString|Form|Params)\['
        ext      = @('.aspx', '.ascx')
        context  = "Usar <%: (razor) o HtmlEncode() para evitar XSS."
        onlineOnly = $true
    },
    # Input sin validar
    @{
        id       = "INPUT_01"
        severity = "medium"
        desc     = "Request.QueryString/Form leído directamente sin validación visible"
        regex    = 'Request\.(QueryString|Form)\[[^\]]+\]'
        ext      = @('.cs')
        context  = "Validar y sanitizar input antes de usar. Verificar que existe validación en el mismo método."
        onlineOnly = $true
    },
    # Catch vacío que oculta errores
    @{
        id       = "ERR_01"
        severity = "low"
        desc     = "Catch vacío o con solo comentario — oculta errores"
        regex    = 'catch\s*(\([^)]*\))?\s*\{\s*(//[^\n]*)?\s*\}'
        ext      = @('.cs')
        context  = "Loggear o relanzar la excepción. Nunca silenciar errores."
    }
)

$findings = New-Object System.Collections.ArrayList
$excluidas = @('bin', 'obj', '.vs', 'packages')

# El árbol se enumera UNA vez, con la unión de las extensiones que miran los patrones, y cada
# patrón trabaja después sobre el subconjunto que le toca. Antes se recorría el scope entero y
# se abría cada fichero una vez POR PATRÓN aplicable —hasta 8 lecturas del mismo .cs— para
# descartar casi todas.
$extensiones = @($patterns | ForEach-Object { $_.ext } | Sort-Object -Unique)
$todosLosFicheros = Get-RsFicherosDeScope -Directorios @($scopeDirs) `
                                          -Globs @($extensiones | ForEach-Object { "*$_" }) `
                                          -CarpetasExcluidas $excluidas

# Una búsqueda por PATRÓN, no un `break` por línea: una misma línea puede disparar varios
# patrones y cada uno es un hallazgo distinto con su propio `id`. Es lo que hacía el recorrido
# anterior (bucle de patrones sin corte) y lo que espera quien lee el informe.
foreach ($p in $patterns) {
    if ($p.onlineOnly -and $tipo -ne "Online") { continue }

    $suyos = @($todosLosFicheros | Where-Object { [IO.Path]::GetExtension($_).ToLower() -in $p.ext })
    if (-not $suyos) { continue }

    $coincidencias = Invoke-RsBusqueda -Patrones @($p.regex) -Ficheros $suyos

    foreach ($c in $coincidencias) {
        $snippet = $c.texto.Trim()
        if ($snippet.Length -gt 100) { $snippet = $snippet.Substring(0,100) + "..." }
        $relPath = $c.file.Replace($scopeJson.workspace,"").TrimStart("\")
        [void]$findings.Add([PSCustomObject]@{
            id       = $p.id
            severity = $p.severity
            desc     = $p.desc
            file     = $relPath
            line     = $c.line
            snippet  = $snippet
            context  = $p.context
        })
    }
}
$findings = @($findings.ToArray())

$critical = @($findings | Where-Object { $_.severity -eq "critical" })
$high     = @($findings | Where-Object { $_.severity -eq "high" })
$medium   = @($findings | Where-Object { $_.severity -eq "medium" })
$low      = @($findings | Where-Object { $_.severity -eq "low" })

@{
    success        = $true
    solution       = [System.IO.Path]::GetFileNameWithoutExtension($SlnPath)
    tipo           = $tipo
    total_findings = $findings.Count
    critical       = $critical.Count
    high           = $high.Count
    medium         = $medium.Count
    low            = $low.Count
    findings       = $findings
} | ConvertTo-Json -Depth 5
