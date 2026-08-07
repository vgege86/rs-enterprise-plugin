<#
    Tests Pester del motor de busqueda compartido (hooks/lib-buscar.ps1) y de los tres hooks que
    lo usan: find-symbol.ps1, search-code.ps1 y security-scan.ps1.

    Cada bloque corresponde a un defecto real medido al sustituir el recorrido
    Get-ChildItem + Get-Content + -match, no a una hipotesis:

      - UNA sola coincidencia -> `found` valia 4 y `matches` salia como objeto.
        Sort-Object -Unique con un elemento devuelve el objeto, no un array de uno, y `.Count`
        sobre un hashtable cuenta sus CLAVES (file, line, content, match). El modelo recibia
        count=4 para una coincidencia.

      - Fichero de UNA sola linea -> nunca casaba nada, en silencio.
        Get-Content sobre un fichero de una linea devuelve String, no String[]. El bucle
        indexaba $lines[0] y obtenia el primer CARACTER, no la primera linea.

      - N simbolos -> N procesos y N recorridos del arbol.
        batch_find_symbols lanzaba un powershell por simbolo. -Symbols resuelve los N en una
        pasada; estos tests fijan que el resultado por simbolo es el mismo que pedirlos sueltos.

      - security-scan emite un hallazgo por PATRON, no uno por linea: una linea que dispara dos
        reglas son dos hallazgos con `id` distinto. El motor por defecto se queda con el primer
        patron que casa, asi que ese hook tiene que llamar una vez por patron. Si alguien
        "optimiza" eso a una sola llamada, este bloque se pone en rojo.

    Los hooks se lanzan como proceso (tienen param() y escriben JSON por stdout), con el
    interprete de PRODUCCION (`powershell`, 5.1) cuando esta disponible y `pwsh` cuando no
    —el CI corre sobre ubuntu-latest, donde no existe—.

    Ejecutar: Invoke-Pester tests/Search.Tests.ps1
#>

BeforeAll {
    $script:HooksDir   = Join-Path (Split-Path -Parent $PSScriptRoot) "hooks"
    $script:FindSymbol = Join-Path $HooksDir "find-symbol.ps1"
    $script:SearchCode = Join-Path $HooksDir "search-code.ps1"
    $script:SecScan    = Join-Path $HooksDir "security-scan.ps1"
    $script:LibBuscar  = Join-Path $HooksDir "lib-buscar.ps1"

    $script:Interprete = if (Get-Command powershell -ErrorAction SilentlyContinue) { "powershell" } else { "pwsh" }

    function New-DirPrueba([string]$Prefijo) {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefijo + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }

    function Invoke-Hook {
        param([string]$Script, [string[]]$Argumentos)
        $salida = & $script:Interprete -NoProfile -ExecutionPolicy Bypass -File $Script @Argumentos 2>$null
        return ($salida -join "`n") | ConvertFrom-Json
    }

    # Arbol sintetico con las formas que importan. Se crea una vez y lo comparten los bloques.
    function New-ArbolPrueba {
        $raiz = New-DirPrueba "rssearch_"
        $src  = Join-Path $raiz "src"
        New-Item -ItemType Directory -Path (Join-Path $src "bin") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $src "obj") -Force | Out-Null

        # Varias lineas, una unica coincidencia de 'Cliente' como clase.
        Set-Content -LiteralPath (Join-Path $src "Cliente.cs") -Encoding UTF8 -Value @(
            "using System;",
            "namespace App {",
            "  public class Cliente : Base {",
            "    public void Procesar(int x) { }",
            "  }",
            "}"
        )
        # Otro fichero con 'Procesar', para que ese simbolo tenga DOS coincidencias.
        Set-Content -LiteralPath (Join-Path $src "Pedido.cs") -Encoding UTF8 -Value @(
            "namespace App {",
            "  public class Pedido {",
            "    public void Procesar() { }",
            "  }",
            "}"
        )
        # UNA sola linea: la forma que el recorrido anterior escaneaba caracter a caracter.
        Set-Content -LiteralPath (Join-Path $src "UnaLinea.cs") -Encoding UTF8 -Value "public class Solitario { }"
        # Mayusculas distintas: -match de PowerShell es insensible y hay que conservarlo.
        Set-Content -LiteralPath (Join-Path $src "Mayus.cs") -Encoding UTF8 -Value "CLASS Mayuscula { }"
        # bin/ y obj/ no se miran.
        Set-Content -LiteralPath (Join-Path $src "bin\EnBin.cs") -Encoding UTF8 -Value "public class Solitario { }"
        Set-Content -LiteralPath (Join-Path $src "obj\EnObj.cs") -Encoding UTF8 -Value "public class Solitario { }"

        return @{ Raiz = $raiz; Src = $src }
    }

    $script:Arbol = New-ArbolPrueba
}

AfterAll {
    if ($script:Arbol -and (Test-Path $script:Arbol.Raiz)) {
        Remove-Item -LiteralPath $script:Arbol.Raiz -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "find-symbol.ps1 — forma de la salida" {

    It "con UNA sola coincidencia devuelve found=1 y matches como array" {
        # Regresion: antes devolvia found=4 (las claves del hashtable) y matches como objeto.
        $r = Invoke-Hook -Script $FindSymbol -Argumentos @("Cliente", $Arbol.Src)
        $r.found | Should -Be 1
        @($r.matches).Count | Should -Be 1
        @($r.matches)[0].line | Should -Be 3
    }

    It "con varias coincidencias las cuenta bien" {
        $r = Invoke-Hook -Script $FindSymbol -Argumentos @("Procesar", $Arbol.Src)
        $r.found | Should -Be 2
        @($r.matches).Count | Should -Be 2
    }

    It "sin coincidencias devuelve found=0 y matches vacio, no ausente" {
        $r = Invoke-Hook -Script $FindSymbol -Argumentos @("NoExisteEsteSimbolo", $Arbol.Src)
        $r.found | Should -Be 0
        @($r.matches).Count | Should -Be 0
    }
}

Describe "find-symbol.ps1 — que ficheros mira" {

    It "encuentra el simbolo en un fichero de UNA sola linea" {
        # Regresion: Get-Content devolvia String y el bucle indexaba caracteres.
        $r = Invoke-Hook -Script $FindSymbol -Argumentos @("Solitario", $Arbol.Src)
        $r.found | Should -Be 1
        @($r.matches)[0].file | Should -BeLike "*UnaLinea.cs"
    }

    It "no mira dentro de bin\ ni de obj\" {
        $r = Invoke-Hook -Script $FindSymbol -Argumentos @("Solitario", $Arbol.Src)
        @($r.matches).file | Should -Not -BeLike "*\bin\*"
        @($r.matches).file | Should -Not -BeLike "*\obj\*"
    }

    It "casa sin distinguir mayusculas, como el operador -match" {
        $r = Invoke-Hook -Script $FindSymbol -Argumentos @("Mayuscula", $Arbol.Src)
        $r.found | Should -Be 1
        @($r.matches)[0].content | Should -Be "CLASS Mayuscula { }"
    }
}

Describe "find-symbol.ps1 — modo lote (-Symbols)" {

    It "devuelve por simbolo lo mismo que pedirlos de uno en uno" {
        $simbolos = @("Cliente", "Procesar", "Solitario", "NoExisteEsteSimbolo")

        $sueltos = @{}
        foreach ($s in $simbolos) {
            $sueltos[$s] = Invoke-Hook -Script $FindSymbol -Argumentos @($s, $Arbol.Src)
        }
        $lote = Invoke-Hook -Script $FindSymbol -Argumentos @("-Symbols", ($simbolos -join ","), "-ScopeDirs", $Arbol.Src)

        $lote.total_symbols | Should -Be $simbolos.Count
        foreach ($s in $simbolos) {
            $enLote = $lote.symbols.$s
            $enLote.count | Should -Be $sueltos[$s].found -Because "el simbolo $s tiene que dar lo mismo suelto que en lote"
            $enLote.found | Should -Be ($sueltos[$s].found -gt 0)

            $lineasLote   = @($enLote.matches | ForEach-Object { "$($_.file):$($_.line)" }) | Sort-Object
            $lineasSuelto = @($sueltos[$s].matches | ForEach-Object { "$($_.file):$($_.line)" }) | Sort-Object
            ($lineasLote -join "|") | Should -Be ($lineasSuelto -join "|")
        }
    }

    It "una linea que casa patrones de dos simbolos aparece bajo los dos" {
        # 'public void Procesar(int x) { }' vive en la clase Cliente; pedir ambos no puede hacer
        # que uno se coma la coincidencia del otro.
        $lote = Invoke-Hook -Script $FindSymbol -Argumentos @("-Symbols", "Cliente,Procesar", "-ScopeDirs", $Arbol.Src)
        $lote.symbols.Cliente.count  | Should -BeGreaterThan 0
        $lote.symbols.Procesar.count | Should -BeGreaterThan 0
    }
}

Describe "lib-buscar.ps1 — enumeracion de ficheros" {

    BeforeAll { . $script:LibBuscar }

    It "excluye las carpetas indicadas y no repite ficheros" {
        $f = Get-RsFicherosDeScope -Directorios @($Arbol.Src) -Globs @('*.cs') -CarpetasExcluidas @('bin','obj')
        @($f).Count | Should -Be 4
        ($f | Where-Object { $_ -match '\\(bin|obj)\\' }) | Should -BeNullOrEmpty
    }

    It "con el mismo directorio repetido no duplica resultados" {
        $f = Get-RsFicherosDeScope -Directorios @($Arbol.Src, $Arbol.Src) -Globs @('*.cs') -CarpetasExcluidas @('bin','obj')
        @($f).Count | Should -Be 4
    }

    It "un directorio inexistente no rompe la busqueda" {
        $f = Get-RsFicherosDeScope -Directorios @($Arbol.Src, (Join-Path $Arbol.Raiz "no_existe")) -Globs @('*.cs') -CarpetasExcluidas @('bin','obj')
        @($f).Count | Should -Be 4
    }

    It "sin ficheros devuelve vacio en vez de fallar" {
        $vacio = New-DirPrueba "rsvacio_"
        try {
            $r = Invoke-RsBusqueda -Patrones @('cualquiera') -Directorios @($vacio)
            @($r).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $vacio -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "gana el PRIMER patron del array cuando varios casan la misma linea" {
        $r = Invoke-RsBusqueda -Patrones @('class\s+Cliente', 'public\s+class') -Directorios @($Arbol.Src)
        $c = @($r | Where-Object { $_.file -like "*Cliente.cs" })
        @($c).Count  | Should -Be 1
        $c[0].patron | Should -Be 'class\s+Cliente'
    }
}

Describe "search-code.ps1" {

    It "devuelve la linea y su contexto" {
        $sln = Join-Path $Arbol.Raiz "X.sln"
        $r = Invoke-Hook -Script $SearchCode -Argumentos @($Arbol.Src, $sln, 'class\s+Pedido')
        $r.success      | Should -BeTrue
        $r.result_count | Should -Be 1
        @($r.results)[0].match  | Should -Be "public class Pedido {"
        @($r.results)[0].before | Should -Match "namespace App"
        @($r.results)[0].after  | Should -Match "Procesar"
    }

    It "no devuelve resultados de bin\ ni obj\" {
        $sln = Join-Path $Arbol.Raiz "X.sln"
        $r = Invoke-Hook -Script $SearchCode -Argumentos @($Arbol.Src, $sln, 'class\s+Solitario')
        $r.result_count | Should -Be 1
        @($r.results)[0].file | Should -BeLike "*UnaLinea.cs"
    }

    It "marca truncated cuando hay mas resultados que MaxResults" {
        $sln = Join-Path $Arbol.Raiz "X.sln"
        $r = Invoke-Hook -Script $SearchCode -Argumentos @($Arbol.Src, $sln, 'class', '*.cs', '2', '1')
        $r.result_count | Should -Be 1
        $r.truncated    | Should -BeTrue
    }
}

Describe "security-scan.ps1 — un hallazgo por patron" {

    It "una linea que dispara dos reglas produce dos hallazgos con id distinto" {
        # Es la diferencia con find-symbol: alli gana el primer patron, aqui NO puede ganar uno
        # solo, porque cada regla es un hallazgo con su propia severidad y su propio consejo.
        $ws  = New-DirPrueba "rssec_"
        try {
            $sol = Join-Path $ws "OnLine\Soluciones"
            New-Item -ItemType Directory -Path (Join-Path $sol "Web") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $sol "Web.sln") -Encoding UTF8 -Value @(
                'Microsoft Visual Studio Solution File, Format Version 12.00',
                'Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "Web", "Web\Web.csproj", "{11111111-1111-1111-1111-111111111111}"',
                'EndProject'
            )
            Set-Content -LiteralPath (Join-Path $sol "Web\Web.csproj") -Encoding UTF8 -Value '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net48</TargetFramework></PropertyGroup></Project>'
            # La linea 3 casa DOS reglas a la vez:
            #   SQL_INJECT_01 por \.ExecuteNonQuery\(
            #   HARDCRED_01   por pass\s*=\s*"[^"]{3,}"
            Set-Content -LiteralPath (Join-Path $sol "Web\D.cs") -Encoding UTF8 -Value @(
                'public class D {',
                '  void X() {',
                '    cmd.ExecuteNonQuery(); string pass = "abcdef";',
                '  }',
                '}'
            )

            $r  = Invoke-Hook -Script $SecScan -Argumentos @((Join-Path $sol "Web.sln"))
            $en3 = @($r.findings | Where-Object { $_.line -eq 3 })
            @($en3).Count | Should -BeGreaterThan 1
            (@($en3.id) | Sort-Object -Unique).Count | Should -BeGreaterThan 1
        } finally { Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
