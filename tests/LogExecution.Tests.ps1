<#
    Tests Pester de hooks/log-execution.ps1 — historial de ejecuciones por desarrollador.

    POR QUE EXISTE ESTA SUITE. Hasta la 3.26.x todas las ejecuciones iban a un unico
    executions/history.json y cada entrada nueva se insertaba al principio del array: con varios
    desarrolladores sobre el mismo trunk, todos tocaban las mismas lineas y SVN daba conflicto en
    cada update. Desde 3.27.0 cada desarrollador escribe en executions/history/<dev>.json. Lo que
    aqui se fija: que cada uno escribe SOLO en su fichero, que la entrada lleva `developer`, que el
    nombre es seguro como fichero, y que el history.json antiguo no se toca.

    Ejecutar: Invoke-Pester tests/LogExecution.Tests.ps1
#>

BeforeAll {
    $script:hookLog = Join-Path $PSScriptRoot "../hooks/log-execution.ps1"

    function New-Ws {
        $d = Join-Path $TestDrive ("ws_" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }
    function Read-Hist([string]$Ws, [string]$Dev) {
        $raw = Get-Content (Join-Path $Ws "executions/history/$Dev.json") -Raw -Encoding UTF8
        # -InputObject: en PS 5.1 el array por pipeline llegaria como UN objeto.
        return @(ConvertFrom-Json -InputObject $raw)
    }
}

Describe "log-execution.ps1 por desarrollador" {

    It "cada desarrollador escribe solo en su fichero y la entrada lleva developer" {
        $ws = New-Ws
        & $script:hookLog $ws "RSProcIN" "cambio de ana" -Developer ana | Out-Null
        & $script:hookLog $ws "AgendaWeb" "cambio de luis" -Developer luis | Out-Null
        & $script:hookLog $ws "RSProcIN" "otro de ana" -Developer ana | Out-Null

        $ana  = Read-Hist $ws "ana"
        $luis = Read-Hist $ws "luis"
        $ana.Count  | Should -Be 2
        $luis.Count | Should -Be 1
        $ana[0].task | Should -Be "otro de ana"      # la mas reciente primero
        ($ana | ForEach-Object { $_.developer } | Select-Object -Unique) | Should -Be "ana"
        $luis[0].developer | Should -Be "luis"
    }

    It "un fichero con una sola entrada sigue siendo un array" {
        $ws = New-Ws
        & $script:hookLog $ws "RSProcIN" "primera" -Developer ana | Out-Null
        $raw = Get-Content (Join-Path $ws "executions/history/ana.json") -Raw -Encoding UTF8
        $raw.TrimStart([char]0xFEFF).TrimStart() | Should -Match '^\['
    }

    It "normaliza DOMINIO\Usuario a un nombre de fichero seguro en minusculas" {
        $ws = New-Ws
        $out = & $script:hookLog $ws "RSProcIN" "x" -Developer "EMPRESA\Ana.Perez" | ConvertFrom-Json
        $out.developer | Should -Be "ana.perez"
        Test-Path (Join-Path $ws "executions/history/ana.perez.json") | Should -BeTrue
    }

    It "sin -Developer usa RS_DEVELOPER y, si no, el usuario del sistema" {
        $ws = New-Ws
        $antes = $env:RS_DEVELOPER
        try {
            $env:RS_DEVELOPER = "marta"
            (& $script:hookLog $ws "RSProcIN" "x" | ConvertFrom-Json).developer | Should -Be "marta"

            $env:RS_DEVELOPER = $null
            $esperado = (($env:USERNAME, $env:USER | Where-Object { $_ } | Select-Object -First 1) -replace '^.*[\\/]', '').ToLowerInvariant() -replace '[^a-z0-9._-]', '_'
            if (-not $esperado) { $esperado = "desconocido" }
            (& $script:hookLog $ws "RSProcIN" "y" | ConvertFrom-Json).developer | Should -Be $esperado
        }
        finally { $env:RS_DEVELOPER = $antes }
    }

    It "no toca el history.json antiguo" {
        $ws = New-Ws
        $ex = Join-Path $ws "executions"
        New-Item -ItemType Directory -Path $ex -Force | Out-Null
        $legacy = Join-Path $ex "history.json"
        $contenido = '[{"id":"old1","timestamp":"2026-01-01T00:00:00","task":"viejo","status":"success"}]'
        Set-Content -LiteralPath $legacy -Value $contenido -Encoding UTF8 -NoNewline

        & $script:hookLog $ws "RSProcIN" "nuevo" -Developer ana | Out-Null

        (Get-Content -LiteralPath $legacy -Raw -Encoding UTF8).TrimStart([char]0xFEFF) | Should -Be $contenido
    }
}
