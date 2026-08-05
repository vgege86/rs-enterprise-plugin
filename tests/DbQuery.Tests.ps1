<#
    Tests Pester de la GUARDA read-only de hooks/db-query.ps1.

    La guarda (SELECT/CTE únicamente, sin multi-statement, sin verbo de escritura tras un CTE) se
    ejecuta ANTES de leer la configuración o conectar a la BD, así que estas comprobaciones no
    requieren ni BD ni un .rs-databases.json real: con una SQL prohibida el script sale con el error
    de la guarda usando cualquier workspace.

    Ejecutar: Invoke-Pester tests/DbQuery.Tests.ps1
#>

Describe "db-query.ps1 read-only guard" {
    BeforeAll {
        $script:hook = Join-Path $PSScriptRoot "../hooks/db-query.ps1"
    }

    It "existe el hook" {
        Test-Path $script:hook | Should -BeTrue
    }

    It "rechaza multi-statement (SELECT ...; DROP ...)" {
        $out = & $script:hook -Workspace "X:\dummy" -Sql "SELECT 1 FROM dual; DROP TABLE x" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error | Should -Match "Multi-statement"
    }

    It "rechaza CTE con verbo de escritura (WITH ... DELETE)" {
        $out = & $script:hook -Workspace "X:\dummy" -Sql "WITH t AS (SELECT 1 FROM dual) DELETE FROM x" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error | Should -Match "CTE con verbo de escritura"
    }

    It "rechaza sentencias que no son SELECT (UPDATE)" {
        $out = & $script:hook -Workspace "X:\dummy" -Sql "UPDATE x SET a = 1" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error | Should -Match "Solo se permiten"
    }

    It "rechaza DELETE" {
        $out = & $script:hook -Workspace "X:\dummy" -Sql "DELETE FROM x" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error | Should -Match "Solo se permiten"
    }

    # Estos dos usan la unidad ficticia X:\ para llegar a la guarda sin tocar un workspace real.
    # El Join-Path de Windows PowerShell 5.1 VALIDA que la unidad exista y aborta con
    # "No se encuentra la unidad", asi que el hook nunca llega a la guarda y el test mide otra
    # cosa; el de PowerShell 7 no valida. Es una diferencia del cmdlet, no un fallo del hook.
    It "un SELECT válido pasa la guarda (falla después, no por la guarda)" -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        # Con workspace inexistente, un SELECT legítimo NO debe dar error de guarda: debe llegar a la
        # lectura de config y fallar ahí (config no encontrada), demostrando que la guarda lo dejó pasar.
        $out = & $script:hook -Workspace "X:\dummy" -Sql "SELECT 1 FROM dual" | ConvertFrom-Json
        $out.error | Should -Not -Match "Solo se permiten"
        $out.error | Should -Not -Match "Multi-statement"
    }

    It "un ; dentro de comentario de línea NO cuenta como multi-statement" -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        # Antes daba falso positivo: el ; del comentario inflaba el conteo. Ahora la guarda quita
        # comentarios antes de contar, así que este SELECT legítimo debe pasar la guarda.
        $out = & $script:hook -Workspace "X:\dummy" -Sql "SELECT 1 FROM dual -- ; DROP TABLE x" | ConvertFrom-Json
        $out.error | Should -Not -Match "Multi-statement"
        $out.error | Should -Not -Match "Solo se permiten"
    }

    It "un comentario de bloque NO oculta un verbo de escritura en un CTE" {
        $out = & $script:hook -Workspace "X:\dummy" -Sql "WITH t AS (SELECT 1 FROM dual) /* x */ DELETE FROM y" | ConvertFrom-Json
        $out.success | Should -Be $false
        $out.error | Should -Match "CTE con verbo de escritura"
    }
}
