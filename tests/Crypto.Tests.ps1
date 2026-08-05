<#
    Tests Pester del helper de cripto hooks/lib-crypto.ps1.

    ⛔ DPAPI es Windows-only: el CI corre en Ubuntu, donde un valor cifrado no se puede descifrar
    (PlatformNotSupportedException). Por eso hay dos bloques: la lógica multiplataforma (detección del
    prefijo `enc:` y passthrough de texto plano), que corre en todos los SO, y el roundtrip DPAPI real,
    que se SALTA limpiamente (-Skip) fuera de Windows.

    ⛔ Ningún test imprime el valor ni el blob: todas las aserciones son sobre un booleano ya calculado
    (`($a -eq $b) | Should -BeTrue`), nunca `Should -BeExactly $valor`, que volcaría ambos lados al log
    de CI cuando falla. El valor de prueba es inventado y sin ningún valor real.

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

Describe "lib-crypto: roundtrip DPAPI real (solo Windows)" -Skip:(-not $IsWindows) {
    # DPAPI CurrentUser: solo la misma cuenta en la misma maquina descifra. Fuera de Windows no
    # existe la API -> el bloque entero se salta, no falla.
    BeforeAll {
        . (Join-Path $PSScriptRoot ".." "hooks" "lib-crypto.ps1")
        # Valor INVENTADO, sin ningun valor real. Lleva acentos y un simbolo no ASCII a proposito:
        # el formato esta documentado como CryptProtectData sobre bytes UTF-8, y un desajuste de
        # codificacion entre quien cifra y quien descifra es justo la divergencia a cazar.
        $script:ValorFicticio = "valor-de-prueba-sin-valor-real-áéíóú-ñ-€"
    }

    It "Protect-RsSecret marca el resultado con el prefijo enc: y Test-RsEncrypted lo reconoce" {
        $cifrado = Protect-RsSecret $script:ValorFicticio
        # Aserciones sobre booleanos: el blob no aparece en el mensaje de fallo.
        $cifrado.StartsWith("enc:")        | Should -BeTrue
        (Test-RsEncrypted $cifrado)        | Should -BeTrue
        ($cifrado -eq $script:ValorFicticio) | Should -BeFalse
    }

    It "Protect-RsSecret + Unprotect-RsSecret devuelve el original (acentos y simbolo no ASCII)" {
        $cifrado    = Protect-RsSecret $script:ValorFicticio
        $descifrado = Unprotect-RsSecret $cifrado
        ($descifrado -eq $script:ValorFicticio) | Should -BeTrue
    }

    It "Protect-RsSecret es idempotente: cifrar dos veces no anida el cifrado" {
        $cifrado = Protect-RsSecret $script:ValorFicticio
        $doble   = Protect-RsSecret $cifrado
        ($doble -eq $cifrado) | Should -BeTrue
        ((Unprotect-RsSecret $doble) -eq $script:ValorFicticio) | Should -BeTrue
    }
}
