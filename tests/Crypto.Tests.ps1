<#
    Tests Pester del helper de cripto hooks/lib-crypto.ps1.

    ⛔ DPAPI es Windows-only: el CI corre en Ubuntu, así que aquí NO se puede probar el roundtrip real
    (Protect-RsSecret / Unprotect-RsSecret sobre un valor cifrado → PlatformNotSupportedException en
    Linux). Se cubre solo la lógica multiplataforma: detección del prefijo `enc:` y el passthrough de
    texto plano. El roundtrip DPAPI se verifica manualmente en Windows.

    Ejecutar: Invoke-Pester tests/Crypto.Tests.ps1
#>

Describe "lib-crypto: detección y passthrough (sin DPAPI)" {
    BeforeAll {
        . (Join-Path $PSScriptRoot ".." "hooks" "lib-crypto.ps1")
    }

    It "Test-RsEncrypted detecta el prefijo enc:" {
        Test-RsEncrypted "enc:QUJD" | Should -BeTrue
        Test-RsEncrypted "texto plano" | Should -BeFalse
        Test-RsEncrypted "" | Should -BeFalse
    }

    It "Unprotect-RsSecret devuelve el texto plano tal cual (legacy)" {
        Unprotect-RsSecret "mi-password" | Should -BeExactly "mi-password"
        Unprotect-RsSecret "" | Should -BeExactly ""
    }

    It "Protect-RsSecret sobre cadena vacía devuelve vacío (nada que cifrar)" {
        Protect-RsSecret "" | Should -BeExactly ""
    }
}
