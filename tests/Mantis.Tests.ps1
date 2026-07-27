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
