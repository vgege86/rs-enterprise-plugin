Describe "lib-mantis credenciales" {
    BeforeAll {
        . (Join-Path $PSScriptRoot ".." "hooks" "lib-mantis.ps1")
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("mantis-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tmp | Out-Null
    }
    AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

    It "lee baseUrl y token de un JSON válido" {
        $f = Join-Path $script:tmp "ok.json"
        '{ "baseUrl": "https://soporte.ais-int.net/mantis/", "token": "SECRET123" }' | Set-Content -Path $f -Encoding UTF8
        $c = Get-MantisCreds $f
        $c.baseUrl | Should -Be "https://soporte.ais-int.net/mantis"   # TrimEnd('/')
        $c.token   | Should -Be "SECRET123"
    }

    It "lanza si el fichero no existe" {
        { Get-MantisCreds (Join-Path $script:tmp "nope.json") } | Should -Throw
    }

    It "lanza si falta el token" {
        $f = Join-Path $script:tmp "notoken.json"
        '{ "baseUrl": "https://x/mantis" }' | Set-Content -Path $f -Encoding UTF8
        { Get-MantisCreds $f } | Should -Throw
    }

    It "Protect-MantisToken oculta el token" {
        Protect-MantisToken "fallo con token=SECRET123 en la url" "SECRET123" | Should -Be "fallo con token=*** en la url"
    }

    It "Protect-MantisToken con token vacío no altera el texto" {
        Protect-MantisToken "texto" "" | Should -Be "texto"
    }
}

Describe "lib-mantis New-MantisRequest" {
    BeforeAll { . (Join-Path $PSScriptRoot ".." "hooks" "lib-mantis.ps1") }

    It "compone la url con base /api/rest/index.php" {
        $r = New-MantisRequest "https://x/mantis" "GET" "/projects"
        $r.Url    | Should -Be "https://x/mantis/api/rest/index.php/projects"
        $r.Method | Should -Be "GET"
        $r.Body   | Should -BeNullOrEmpty
    }

    It "serializa el body a JSON compacto" {
        $r = New-MantisRequest "https://x/mantis" "PATCH" "/issues/42" @{ status = @{ name = "assigned" } }
        $r.Url  | Should -Be "https://x/mantis/api/rest/index.php/issues/42"
        $r.Body | Should -Be '{"status":{"name":"assigned"}}'
    }

    It "respeta query strings en el path" {
        $r = New-MantisRequest "https://x/mantis" "GET" "/issues?project_id=12&page_size=50"
        $r.Url | Should -Be "https://x/mantis/api/rest/index.php/issues?project_id=12&page_size=50"
    }
}

Describe "mantis-cli.ps1 guardas (pre-red)" {
    BeforeAll {
        $script:cli = Join-Path $PSScriptRoot ".." "hooks" "mantis-cli.ps1"
    }

    It "existe el hook" { Test-Path $script:cli | Should -BeTrue }

    It "comando desconocido → success:false" {
        $out = & $script:cli -Command "frobnicate" -CredPath "X:\no-existe.json" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Match "(?i)comando"
    }

    It "credenciales ausentes → success:false con instrucción" {
        $out = & $script:cli -Command "projects" -CredPath "X:\no-existe.json" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Match "Credenciales no encontradas"
    }
}

Describe "mantis-cli fallo de red" {
    BeforeAll {
        $script:cli = Join-Path $PSScriptRoot ".." "hooks" "mantis-cli.ps1"
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("mantis-net-" + [guid]::NewGuid() + ".json")
        $script:dummyToken = "DUMMY-TOKEN-XYZ"
        @{ baseUrl = "http://127.0.0.1:1"; token = $script:dummyToken } | ConvertTo-Json | Set-Content -Path $script:tmp -Encoding UTF8
    }
    AfterAll { Remove-Item -Force $script:tmp -ErrorAction SilentlyContinue }

    It "conexión rechazada → JSON válido con success:false y error no vacío (no crashea)" {
        $out = & $script:cli -Command "projects" -CredPath $script:tmp | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Not -BeNullOrEmpty
        $out.error   | Should -Not -Match ([regex]::Escape($script:dummyToken))
    }
}
