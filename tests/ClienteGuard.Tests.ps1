<#
    Tests Pester de hooks/cliente-guard-write.ps1 -- la guarda que impide escribir
    identificadores de cliente en el repo del PLUGIN (docs/plugin-architecture.md #10).

    Todos los nombres que aparecen aqui son inventados a proposito (Acme, Vortex): un
    test que usara uno real seria justo la fuga que la guarda persigue.

    La lista de la capa 1 se inyecta con $env:RS_CLIENTES_PATH para no depender del
    ~/.claude/rs-clientes.json de quien ejecute la suite -- que puede no existir, o
    contener otros nombres.

    Ejecutar: pwsh -NoProfile -Command "Invoke-Pester tests/ClienteGuard.Tests.ps1"
#>

BeforeAll {
    $script:g = Join-Path $PSScriptRoot "../hooks/cliente-guard-write.ps1"

    function New-RsRepoPlugin {
        <# Repo del plugin de mentira: lo unico que la guarda mira para decidir el ambito
           es un .claude-plugin/plugin.json cuyo "name" sea rs-enterprise-agent. #>
        param([string]$Ruta, [string]$Nombre = "rs-enterprise-agent")
        $man = Join-Path $Ruta ".claude-plugin/plugin.json"
        New-Item -ItemType File -Path $man -Force | Out-Null
        Set-Content -LiteralPath $man -Encoding UTF8 -Value ('{ "name": "' + $Nombre + '", "version": "0.0.0" }')
        return $Ruta
    }

    function New-RsListaClientes {
        param([string]$Ruta, [string[]]$Nombres = @("Acme"), [string[]]$Dominios = @(), [string[]]$Esquemas = @())
        New-Item -ItemType File -Path $Ruta -Force | Out-Null
        $o = @{ nombres = $Nombres; dominios = $Dominios; esquemas = $Esquemas }
        Set-Content -LiteralPath $Ruta -Encoding UTF8 -Value ($o | ConvertTo-Json -Depth 5)
        return $Ruta
    }

    function Invoke-Guarda {
        <# Devuelve @{ codigo; salida }. La salida de aviso va por stdout (exit 0); el
           bloqueo va por stderr (exit 2) y aqui se descarta: lo que se afirma es el codigo. #>
        param([string]$Contenido = "", [string]$Ruta)
        $ev = @{ tool_input = @{ file_path = $Ruta; content = $Contenido } } | ConvertTo-Json -Depth 5 -Compress
        $out = $ev | & pwsh -NoProfile -File $script:g 2>$null
        return @{ codigo = $LASTEXITCODE; salida = ($out -join "`n") }
    }
}

Describe "cliente-guard-write.ps1 -- ambito" {
    BeforeAll {
        $script:repo  = New-RsRepoPlugin (Join-Path $TestDrive "plug")
        $script:fuera = Join-Path $TestDrive "workspace-cliente"
        New-Item -ItemType Directory -Path $script:fuera -Force | Out-Null
        $env:RS_CLIENTES_PATH = New-RsListaClientes (Join-Path $TestDrive "rs-clientes.json") @("Acme")
    }
    AfterAll { Remove-Item Env:RS_CLIENTES_PATH -ErrorAction SilentlyContinue }

    It "bloquea dentro del repo del plugin" {
        (Invoke-Guarda "Ejemplo para Acme" (Join-Path $script:repo "references/x.md")).codigo | Should -Be 2
    }

    It "NO actua fuera del repo del plugin -- ahi el nombre es legitimo" {
        (Invoke-Guarda "Ejemplo para Acme" (Join-Path $script:fuera "docs/x.md")).codigo | Should -Be 0
    }

    It "NO actua si el manifest es de otro plugin del marketplace" {
        $otro = New-RsRepoPlugin (Join-Path $TestDrive "otro-plugin") "rs-validador"
        (Invoke-Guarda "Ejemplo para Acme" (Join-Path $otro "x.md")).codigo | Should -Be 0
    }

    It "vale para un fichero que aun no existe (Write de uno nuevo)" {
        (Invoke-Guarda "Acme" (Join-Path $script:repo "references/nuevo-que-no-existe.md")).codigo | Should -Be 2
    }
}

Describe "cliente-guard-write.ps1 -- capa 1 (lista declarada, BLOQUEA)" {
    BeforeAll {
        $script:repo = New-RsRepoPlugin (Join-Path $TestDrive "plug1")
        $script:f    = Join-Path $script:repo "references/x.md"
    }
    AfterAll { Remove-Item Env:RS_CLIENTES_PATH -ErrorAction SilentlyContinue }

    It "bloquea el nombre en el contenido" {
        $env:RS_CLIENTES_PATH = New-RsListaClientes (Join-Path $TestDrive "l1.json") @("Acme")
        (Invoke-Guarda "El proyecto Acme usa Oracle" $script:f).codigo | Should -Be 2
    }

    It "bloquea aunque cambie el caso" {
        $env:RS_CLIENTES_PATH = New-RsListaClientes (Join-Path $TestDrive "l2.json") @("Acme")
        (Invoke-Guarda "esquema RSACME y usuario acme" $script:f).codigo | Should -Be 2
    }

    It "bloquea el nombre en la RUTA, no solo en el contenido" {
        $env:RS_CLIENTES_PATH = New-RsListaClientes (Join-Path $TestDrive "l3.json") @("Acme")
        (Invoke-Guarda "contenido inocuo" (Join-Path $script:repo "docs/informe-Acme.md")).codigo | Should -Be 2
    }

    It "bloquea un dominio declarado" {
        $env:RS_CLIENTES_PATH = New-RsListaClientes (Join-Path $TestDrive "l4.json") @() @("vortex.example")
        (Invoke-Guarda '"email": "dev@vortex.example"' $script:f).codigo | Should -Be 2
    }

    It "bloquea un esquema declarado" {
        $env:RS_CLIENTES_PATH = New-RsListaClientes (Join-Path $TestDrive "l5.json") @() @() @("RSVORTEX")
        (Invoke-Guarda 'SELECT * FROM RSVORTEX.RDEUDORES' $script:f).codigo | Should -Be 2
    }

    It "NO bloquea cuando el token cae dentro de otra palabra (frontera)" {
        # "Acme" declarado no debe disparar sobre "Acmeter", que es otra cosa.
        $env:RS_CLIENTES_PATH = New-RsListaClientes (Join-Path $TestDrive "l6.json") @("Acme")
        (Invoke-Guarda "la clase Acmeter mide el consumo" $script:f).codigo | Should -Be 0
    }

    It "ignora tokens de menos de 3 caracteres -- casarian con medio repo" {
        $env:RS_CLIENTES_PATH = New-RsListaClientes (Join-Path $TestDrive "l7.json") @("RS")
        (Invoke-Guarda "el plugin RS hace cosas" $script:f).codigo | Should -Be 0
    }

    It "sin fichero de lista, la capa 1 queda inactiva" {
        $env:RS_CLIENTES_PATH = Join-Path $TestDrive "no-existe.json"
        (Invoke-Guarda "El proyecto Acme usa Oracle" $script:f).codigo | Should -Be 0
    }

    It "con lista ilegible avisa por stdout y NO bloquea" {
        $rota = Join-Path $TestDrive "rota.json"
        Set-Content -LiteralPath $rota -Encoding UTF8 -Value "{ esto no es json"
        $env:RS_CLIENTES_PATH = $rota
        $r = Invoke-Guarda "texto cualquiera" $script:f
        $r.codigo | Should -Be 0
        $r.salida | Should -Match "AVISO rs-clientes"
    }
}

Describe "cliente-guard-write.ps1 -- capa 2 (heuristica, AVISA sin bloquear)" {
    BeforeAll {
        $script:repo = New-RsRepoPlugin (Join-Path $TestDrive "plug2")
        $script:f    = Join-Path $script:repo "references/x.md"
        $env:RS_CLIENTES_PATH = Join-Path $TestDrive "sin-lista.json"   # capa 1 inactiva
    }
    AfterAll { Remove-Item Env:RS_CLIENTES_PATH -ErrorAction SilentlyContinue }

    It "avisa de una ruta de workspace de cliente sin bloquear" {
        $r = Invoke-Guarda 'ver N:\SVN\RS\Vortex\trunk\docs\.rs-databases.json' $script:f
        $r.codigo | Should -Be 0
        $r.salida | Should -Match "AVISO cliente-guard"
        $r.salida | Should -Match "ruta de workspace"
    }

    It "NO avisa de una ruta con segmento propio del autor" {
        $r = Invoke-Guarda 'ver N:\SVN\RS\Agentes\trunk\x.md' $script:f
        $r.salida | Should -Not -Match "AVISO cliente-guard"
    }

    It "avisa de un site Atlassian concreto" {
        (Invoke-Guarda '"baseUrl": "https://vortexcorp.atlassian.net"' $script:f).salida |
            Should -Match "site Atlassian"
    }

    # Sin angulos en el nombre del It: Pester v6 los lee como plantilla de -ForEach y
    # revienta al parsear ("Unexpected token '-site'").
    It "NO avisa del marcador de site" {
        (Invoke-Guarda '"baseUrl": "https://<tu-site>.atlassian.net"' $script:f).salida |
            Should -Not -Match "AVISO cliente-guard"
    }

    It "avisa de un usuario de conexion concreto" {
        (Invoke-Guarda 'Data Source=X;User Id=RSVORTEXQUERY' $script:f).salida |
            Should -Match "usuario de conexion"
    }

    It "avisa de un esquema concreto en JSON" {
        (Invoke-Guarda '{ "schema": "RSVORTEX" }' $script:f).salida | Should -Match "esquema de BD"
    }

    It "NO avisa de un marcador de esquema" {
        (Invoke-Guarda '{ "schema": "<ESQUEMA>" }' $script:f).salida | Should -Not -Match "AVISO cliente-guard"
    }

    It "no se dispara sobre la propia guarda ni sobre esta suite" {
        foreach ($rel in @("hooks/cliente-guard-write.ps1", "tests/ClienteGuard.Tests.ps1")) {
            $r = Invoke-Guarda 'N:\SVN\RS\Vortex\trunk\x' (Join-Path $script:repo $rel)
            $r.codigo | Should -Be 0
            $r.salida | Should -Not -Match "AVISO cliente-guard"
        }
    }
}

Describe "cliente-guard-write.ps1 -- registro en el manifest" {
    It "esta declarado como PreToolUse Write|Edit en plugin.json" {
        $man = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../.claude-plugin/plugin.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $cmds = $man.hooks.PreToolUse | Where-Object { $_.matcher -eq "Write|Edit" } |
                ForEach-Object { $_.hooks.command }
        ($cmds -join " ") | Should -Match "cliente-guard-write\.ps1"
    }
}
