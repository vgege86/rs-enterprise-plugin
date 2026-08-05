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

Describe "lib-mantis Get-MantisAdvancePath" {
    BeforeAll {
        . (Join-Path $PSScriptRoot ".." "hooks" "lib-mantis.ps1")
        $script:chain = @('new', 'acknowledged', 'assigned', 'confirmed')
    }

    It "new -> assigned devuelve 2 pasos intermedios" {
        $r = Get-MantisAdvancePath $script:chain "new" "assigned"
        $r.Count | Should -Be 2
        $r | Should -Be @('acknowledged', 'assigned')
    }

    It "acknowledged -> assigned devuelve un solo paso (array)" {
        $r = Get-MantisAdvancePath $script:chain "acknowledged" "assigned"
        $r.Count  | Should -Be 1
        $r[0]     | Should -Be "assigned"
    }

    It "assigned -> assigned (mismo estado) devuelve array vacío" {
        $r = Get-MantisAdvancePath $script:chain "assigned" "assigned"
        $r.Count | Should -Be 0
    }

    It "assigned -> confirmed devuelve un solo paso" {
        $r = Get-MantisAdvancePath $script:chain "assigned" "confirmed"
        $r.Count | Should -Be 1
        $r[0]    | Should -Be "confirmed"
    }

    It "new -> confirmed devuelve la cadena completa de 3 pasos" {
        $r = Get-MantisAdvancePath $script:chain "new" "confirmed"
        $r.Count | Should -Be 3
        $r | Should -Be @('acknowledged', 'assigned', 'confirmed')
    }

    It "confirmed -> assigned (retroceso) lanza" {
        { Get-MantisAdvancePath $script:chain "confirmed" "assigned" } | Should -Throw
    }

    It "closed -> assigned (estado actual fuera de cadena) lanza" {
        { Get-MantisAdvancePath $script:chain "closed" "assigned" } | Should -Throw
    }

    It "assigned -> nonexistent (estado destino fuera de cadena) lanza" {
        { Get-MantisAdvancePath $script:chain "assigned" "nonexistent" } | Should -Throw
    }
}

# Regresión 2.26.5: el llamador envolvía el resultado con @( ), que sobre una función que ya emite
# el array vía comma unario NO aplana — lo anida. Efecto: un solo PATCH con status.name como array
# (HTTP 500), pasos intermedios saltados y la rama "ya en el estado destino" inalcanzable.
Describe "lib-mantis Get-MantisAdvancePath contrato de consumo" {
    BeforeAll {
        . (Join-Path $PSScriptRoot ".." "hooks" "lib-mantis.ps1")
        $script:chain = @('new', 'acknowledged', 'assigned', 'confirmed')
        $script:cliSrc = Get-Content -Raw (Join-Path $PSScriptRoot ".." "hooks" "mantis-cli.ps1")
    }

    It "cada elemento es un string suelto, no un array anidado" {
        $path = Get-MantisAdvancePath $script:chain "new" "confirmed"
        $path.Count | Should -Be 3
        foreach ($step in $path) { $step | Should -BeOfType [string] }
    }

    It "un solo paso sigue siendo un array de un string" {
        $path = Get-MantisAdvancePath $script:chain "new" "acknowledged"
        $path.Count | Should -Be 1
        $path[0]    | Should -BeOfType [string]
    }

    It "el body PATCH de cada paso lleva status.name como string, no como array" {
        $path = Get-MantisAdvancePath $script:chain "new" "acknowledged"
        $body = ConvertTo-Json @{ status = @{ name = $path[0] } } -Depth 8 -Compress
        $body | Should -Be '{"status":{"name":"acknowledged"}}'
    }

    It "mismo estado -> Count 0 (dispara la rama 'ya en el estado destino')" {
        $path = Get-MantisAdvancePath $script:chain "assigned" "assigned"
        $path.Count | Should -Be 0
    }

    # Caracterización del gotcha de PowerShell que causó el bug: fija por qué existe la guarda
    # estática de abajo. Si algún día @( ) aplanara, este test avisaría de que la guarda sobra.
    It "envolver con @( ) anida el array (el gotcha que rompía advance)" {
        $malo = @(Get-MantisAdvancePath $script:chain "new" "confirmed")
        $malo.Count           | Should -Be 1
        # -is en vez de `| Should -BeOfType`: la pipeline desenrollaría el array anidado y la
        # aserción vería sus elementos (strings) en vez del array.
        ($malo[0] -is [array]) | Should -BeTrue
        $body = ConvertTo-Json @{ status = @{ name = $malo[0] } } -Depth 8 -Compress
        $body | Should -Be '{"status":{"name":["acknowledged","assigned","confirmed"]}}'
    }

    It "mantis-cli.ps1 NO envuelve la llamada con @( )" {
        $script:cliSrc | Should -Not -Match '@\(\s*Get-MantisAdvancePath'
        $script:cliSrc | Should -Match '\$path\s*=\s*Get-MantisAdvancePath'
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

    It "me con -CredPath inválido → success:false con instrucción (pasa por resolución de credenciales)" {
        $out = & $script:cli -Command "me" -CredPath "X:\no-existe.json" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Match "Credenciales no encontradas"
    }
}

Describe "mantis-cli create validación" {
    BeforeAll { $script:cli = Join-Path $PSScriptRoot ".." "hooks" "mantis-cli.ps1" }

    It "create sin -Summary → success:false antes de tocar red" {
        $out = & $script:cli -Command "create" -Project 12 -Category "General" -Description "x" -CredPath "X:\no-existe.json" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Match "(?i)summary|resumen"
    }
}

Describe "mantis-cli transition/comment validación" {
    BeforeAll { $script:cli = Join-Path $PSScriptRoot ".." "hooks" "mantis-cli.ps1" }

    It "transition sin -Status → success:false" {
        $out = & $script:cli -Command "transition" -Id 42 -CredPath "X:\no-existe.json" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Match "(?i)status|estado"
    }
    It "comment sin -Text → success:false" {
        $out = & $script:cli -Command "comment" -Id 42 -CredPath "X:\no-existe.json" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Match "(?i)text|texto|comentario"
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

    It "attach con conexión rechazada → JSON válido con success:false y error no vacío (no crashea, token no filtrado)" {
        $tmpFile = Join-Path ([IO.Path]::GetTempPath()) ("mantis-attach-" + [guid]::NewGuid() + ".txt")
        Set-Content -Path $tmpFile -Value "contenido de prueba" -Encoding UTF8
        try {
            $out = & $script:cli -Command "attach" -Id 42 -Files $tmpFile -CredPath $script:tmp | ConvertFrom-Json
            $out.success | Should -Be $false
            $out.error   | Should -Not -BeNullOrEmpty
            $out.error   | Should -Not -Match ([regex]::Escape($script:dummyToken))
        } finally { Remove-Item -Force $tmpFile -ErrorAction SilentlyContinue }
    }

    It "transition (verbo PATCH) con conexión rechazada → error de red, NO ArgumentNullException por verbo nulo" {
        # Regresión: en .NET Framework 4.x, [System.Net.Http.HttpMethod]::PATCH no existe como
        # propiedad estática (solo se añadió en .NET Core 2.1) y devuelve $null, lo que hace que
        # HttpRequestMessage($null, url) lance ArgumentNullException. transition es el ÚNICO
        # comando que usa PATCH, así que este es el único caso que lo detecta.
        $out = & $script:cli -Command transition -Id 42 -Status assigned -CredPath $script:tmp | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Not -BeNullOrEmpty
        $out.error   | Should -Not -Match "(?i)ArgumentNullException"
        $out.error   | Should -Not -Match "(?i)valor no puede ser nulo"
        $out.error   | Should -Not -Match "(?i)cannot be null"
    }
}

Describe "mantis-cli attach/download validación" {
    BeforeAll { $script:cli = Join-Path $PSScriptRoot ".." "hooks" "mantis-cli.ps1" }

    It "attach con fichero inexistente → success:false" {
        $out = & $script:cli -Command "attach" -Id 42 -Files "X:\no-existe.sql" -CredPath "X:\no-existe.json" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Match "(?i)fichero no encontrado"
    }
    It "download sin -Out → success:false" {
        $out = & $script:cli -Command "download" -Id 42 -FileId 7 -CredPath "X:\no-existe.json" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Match "(?i)out|destino"
    }
}

Describe "mantis-cli advance validación" {
    BeforeAll { $script:cli = Join-Path $PSScriptRoot ".." "hooks" "mantis-cli.ps1" }

    It "advance sin -Chain → success:false" {
        $out = & $script:cli -Command "advance" -Id 42 -To "assigned" -CredPath "X:\no-existe.json" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Match "Chain"
    }
    It "advance sin -To → success:false" {
        $out = & $script:cli -Command "advance" -Id 42 -Chain "new,assigned" -CredPath "X:\no-existe.json" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Match "(?i)to|destino"
    }
}

Describe "mantis-cli assign validación" {
    BeforeAll { $script:cli = Join-Path $PSScriptRoot ".." "hooks" "mantis-cli.ps1" }

    It "assign sin -Handler → success:false (guarda pura, sin red)" {
        $out = & $script:cli -Command "assign" -Id 42 -CredPath "X:\no-existe.json" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Match "(?i)handler"
    }
    It "assign sin -Id → success:false" {
        $out = & $script:cli -Command "assign" -Handler 7 -CredPath "X:\no-existe.json" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Match "(?i)id"
    }
}

Describe "mantis-cli advance fallo de red" {
    BeforeAll {
        $script:cli = Join-Path $PSScriptRoot ".." "hooks" "mantis-cli.ps1"
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("mantis-advance-net-" + [guid]::NewGuid() + ".json")
        $script:dummyToken = "DUMMY-TOKEN-ADVANCE"
        @{ baseUrl = "http://127.0.0.1:1"; token = $script:dummyToken } | ConvertTo-Json | Set-Content -Path $script:tmp -Encoding UTF8
    }
    AfterAll { Remove-Item -Force $script:tmp -ErrorAction SilentlyContinue }

    It "conexión rechazada en el GET inicial → JSON válido con success:false, error no vacío, sin filtrar el token" {
        $out = & $script:cli -Command "advance" -Id 42 -To "assigned" -Chain "new,acknowledged,assigned,confirmed" -CredPath $script:tmp | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error   | Should -Not -BeNullOrEmpty
        $out.error   | Should -Not -Match ([regex]::Escape($script:dummyToken))
    }
}
