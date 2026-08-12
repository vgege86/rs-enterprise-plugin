<#
    Tests Pester de hooks/lib-msbuild.ps1 — el detector que decide con que compilador hay que
    construir una solucion.

    POR QUE EXISTE ESTA SUITE. compile-check.ps1 y test-runner-check.ps1 llamaban siempre al CLI
    dotnet. En un workspace mixto (web y batch en .NET Framework, servicio y modulos en .NET
    moderno) eso devolvia MSB4019 sobre codigo correcto, y como el parser solo reconocia CS####,
    el error real quedaba invisible: error_count=0 con exit_code=1. El validator reportaba
    "compilacion no verificada" de forma cronica.

    La decision NO puede depender de nombres de solucion ni de proyecto: el plugin es generico. Se
    decide leyendo lo que declara cada .csproj, y eso es exactamente lo que aqui se ejercita — con
    ficheros de prueba en un temp, sin Visual Studio y sin workspace de cliente, para que corra en
    CI. Encontrar msbuild.exe de verdad no se puede probar en CI; lo que si se prueba es la
    INVARIANTE que protege: si hace falta y no esta, el resultado trae `error` (falla cerrado) en
    vez de caer al compilador equivocado en silencio.

    Ejecutar: Invoke-Pester tests/MsBuild.Tests.ps1
#>

BeforeAll {
    . (Join-Path $PSScriptRoot "../hooks/lib-msbuild.ps1")

    function New-TempDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("rsmb_" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }

    # .csproj SDK-style (formato moderno)
    function New-CsprojSdk {
        param([string]$Dir, [string]$Nombre, [string]$Tfm = "net8.0")
        $ruta = Join-Path $Dir "$Nombre.csproj"
        @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>$Tfm</TargetFramework>
  </PropertyGroup>
</Project>
"@ | Set-Content -LiteralPath $ruta -Encoding UTF8
        return $ruta
    }

    # .csproj clasico (.NET Framework), opcionalmente web o con COM
    function New-CsprojLegacy {
        param(
            [string]$Dir,
            [string]$Nombre,
            [string]$Version = "v4.8",
            [switch]$Web,
            [switch]$Com
        )
        $ruta = Join-Path $Dir "$Nombre.csproj"
        $extra = ""
        if ($Com) { $extra += "  <ItemGroup><COMReference Include=`"SHDocVw`"><Guid>{EAB22AC0-30C1-11CF-A7EB-0000C05BAE0B}</Guid></COMReference></ItemGroup>`n" }
        if ($Web) { $extra += "  <Import Project=`"`$(VSToolsPath)\WebApplications\Microsoft.WebApplication.targets`" />`n" }
        @"
<Project ToolsVersion="15.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <TargetFrameworkVersion>$Version</TargetFrameworkVersion>
    <AssemblyName>$Nombre</AssemblyName>
  </PropertyGroup>
$extra  <Import Project="`$(MSBuildToolsPath)\Microsoft.CSharp.targets" />
</Project>
"@ | Set-Content -LiteralPath $ruta -Encoding UTF8
        return $ruta
    }

    # .sln minima que referencia los .csproj dados por ruta RELATIVA a la propia .sln
    function New-Sln {
        param([string]$Dir, [string]$Nombre, [string[]]$Relativos)
        $ruta = Join-Path $Dir "$Nombre.sln"
        $lineas = @("Microsoft Visual Studio Solution File, Format Version 12.00")
        foreach ($rel in $Relativos) {
            $nom = [IO.Path]::GetFileNameWithoutExtension($rel)
            $lineas += "Project(`"{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}`") = `"$nom`", `"$rel`", `"{$([Guid]::NewGuid())}`""
            $lineas += "EndProject"
        }
        $lineas | Set-Content -LiteralPath $ruta -Encoding UTF8
        return $ruta
    }
}

Describe "Test-RsTfmFramework" {

    It "reconoce como .NET Framework: <Tfm>" -ForEach @(
        @{ Tfm = "v4.8" }, @{ Tfm = "v3.5" }, @{ Tfm = "net48" }, @{ Tfm = "net472" },
        @{ Tfm = "net40" }, @{ Tfm = "net8.0;net48" }
    ) {
        Test-RsTfmFramework -Tfm $Tfm | Should -BeTrue
    }

    It "NO lo reconoce como .NET Framework: <Tfm>" -ForEach @(
        @{ Tfm = "net8.0" }, @{ Tfm = "net5.0" }, @{ Tfm = "net10.0-windows" },
        @{ Tfm = "netstandard2.0" }, @{ Tfm = "netcoreapp3.1" }, @{ Tfm = "" }
    ) {
        # La regla es la nomenclatura oficial de TFMs: net5+ SIEMPRE lleva version menor
        # (net8.0) y .NET Framework NUNCA la lleva (net48). Sin punto = Framework.
        Test-RsTfmFramework -Tfm $Tfm | Should -BeFalse
    }
}

Describe "Get-RsProyectoInfo" {

    It "un .csproj SDK-style con TFM moderno no exige MSBuild" {
        $d = New-TempDir
        try {
            $info = Get-RsProyectoInfo -ProjectPath (New-CsprojSdk -Dir $d -Nombre "Modulo")
            $info.exists           | Should -BeTrue
            $info.sdk_style        | Should -BeTrue
            $info.legacy           | Should -BeFalse
            $info.target_framework | Should -Be "net8.0"
            $info.framework_full   | Should -BeFalse
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "un .csproj clasico se detecta como legacy y .NET Framework" {
        $d = New-TempDir
        try {
            $info = Get-RsProyectoInfo -ProjectPath (New-CsprojLegacy -Dir $d -Nombre "Proceso")
            $info.sdk_style      | Should -BeFalse
            $info.legacy         | Should -BeTrue
            $info.framework_full | Should -BeTrue
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "detecta el proyecto web por el import de WebApplication.targets (la causa literal del MSB4019)" {
        $d = New-TempDir
        try {
            $info = Get-RsProyectoInfo -ProjectPath (New-CsprojLegacy -Dir $d -Nombre "Agenda" -Web)
            $info.web | Should -BeTrue
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "detecta COMReference" {
        $d = New-TempDir
        try {
            $info = Get-RsProyectoInfo -ProjectPath (New-CsprojLegacy -Dir $d -Nombre "Interop" -Com)
            $info.com | Should -BeTrue
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "un proyecto que no existe en disco sale con exists=false y no inventa nada" {
        $info = Get-RsProyectoInfo -ProjectPath (Join-Path ([IO.Path]::GetTempPath()) "no_existe_jamas.csproj")
        $info.exists         | Should -BeFalse
        $info.framework_full | Should -BeFalse
    }
}

Describe "Get-RsProyectosSln" {

    It "resuelve las rutas relativas con '..' a ruta absoluta" {
        $raiz = New-TempDir
        try {
            $solDir = Join-Path $raiz "Soluciones"; New-Item -ItemType Directory -Path $solDir -Force | Out-Null
            $negDir = Join-Path $raiz "Negocio";    New-Item -ItemType Directory -Path $negDir -Force | Out-Null
            New-CsprojLegacy -Dir $negDir -Nombre "Negocio" | Out-Null

            $sln = New-Sln -Dir $solDir -Nombre "App" -Relativos @("..\Negocio\Negocio.csproj")
            $proyectos = @(Get-RsProyectosSln -SlnPath $sln)

            $proyectos.Count      | Should -Be 1
            $proyectos[0].exists  | Should -BeTrue
            $proyectos[0].project | Should -Not -Match '\.\.'
        }
        finally { Remove-Item $raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe "Get-RsBuildToolchain" {

    It "solucion 100% SDK-style moderna -> CLI dotnet" {
        $d = New-TempDir
        try {
            New-CsprojSdk -Dir $d -Nombre "Modulo" | Out-Null
            $t = Get-RsBuildToolchain -SlnPath (New-Sln -Dir $d -Nombre "Servicio" -Relativos @("Modulo.csproj"))
            $t.requires_msbuild | Should -BeFalse
            $t.builder          | Should -Be "dotnet"
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "un solo proyecto .NET Framework arrastra toda la solucion a MSBuild" {
        # MSBuild de VS compila tambien los SDK-style; el CLI dotnet no compila Framework.
        # Por eso el mixto se resuelve hacia MSBuild, nunca al reves.
        $d = New-TempDir
        try {
            New-CsprojSdk    -Dir $d -Nombre "Comun"   | Out-Null
            New-CsprojLegacy -Dir $d -Nombre "Proceso" | Out-Null
            $t = Get-RsBuildToolchain -SlnPath (New-Sln -Dir $d -Nombre "Batch" -Relativos @("Comun.csproj", "Proceso.csproj"))
            $t.requires_msbuild | Should -BeTrue
            $t.builder          | Should -Be "msbuild"
            $t.reason           | Should -Match "Proceso"
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "el motivo nombra el proyecto concreto, no la solucion (nada de listas de nombres)" {
        $d = New-TempDir
        try {
            New-CsprojLegacy -Dir $d -Nombre "Agenda" -Web | Out-Null
            $t = Get-RsBuildToolchain -SlnPath (New-Sln -Dir $d -Nombre "OnLine" -Relativos @("Agenda.csproj"))
            $t.reason | Should -Match "Agenda"
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "si hace falta MSBuild y no esta en la maquina, FALLA CERRADO (error, no fallback a dotnet)" {
        # La invariante que protege del bug original: no verificado != no compila. Sin esto, el
        # detector caeria a dotnet en silencio y devolveria un falso 'no compila'.
        $d = New-TempDir
        try {
            New-CsprojLegacy -Dir $d -Nombre "Proceso" | Out-Null
            $t = Get-RsBuildToolchain -SlnPath (New-Sln -Dir $d -Nombre "Batch" -Relativos @("Proceso.csproj"))
            $t.builder | Should -Be "msbuild"
            if (-not $t.builder_path) {
                $t.error | Should -Not -BeNullOrEmpty
            }
            else {
                $t.error | Should -BeNullOrEmpty
            }
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "-Preferencia impone el compilador y lo marca como forzado" {
        $d = New-TempDir
        try {
            New-CsprojLegacy -Dir $d -Nombre "Proceso" | Out-Null
            $sln = New-Sln -Dir $d -Nombre "Batch" -Relativos @("Proceso.csproj")
            $t = Get-RsBuildToolchain -SlnPath $sln -Preferencia dotnet
            $t.builder          | Should -Be "dotnet"
            $t.forced           | Should -BeTrue
            $t.requires_msbuild | Should -BeTrue   # se sigue informando de que no era lo indicado
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "una .sln cuyos proyectos no estan en disco no se inventa un veredicto" {
        $d = New-TempDir
        try {
            $t = Get-RsBuildToolchain -SlnPath (New-Sln -Dir $d -Nombre "Rota" -Relativos @("NoExiste.csproj"))
            $t.requires_msbuild    | Should -BeFalse
            $t.projects_unreadable | Should -Be 1
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe "Get-RsTestAssembly" {

    It "devuelve el .dll mas reciente cuando bin\Debug y bin\Release conviven" {
        $d = New-TempDir
        try {
            $proj = New-CsprojLegacy -Dir $d -Nombre "Tests"
            $debug   = Join-Path $d "bin\Debug";   New-Item -ItemType Directory -Path $debug   -Force | Out-Null
            $release = Join-Path $d "bin\Release"; New-Item -ItemType Directory -Path $release -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $debug   "Tests.dll") -Value "viejo"
            Start-Sleep -Milliseconds 50
            Set-Content -LiteralPath (Join-Path $release "Tests.dll") -Value "nuevo"

            Get-RsTestAssembly -ProjectPath $proj | Should -Be (Join-Path $release "Tests.dll")
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "devuelve null si el proyecto nunca se compilo (ausencia de evidencia, no 'sin fallos')" {
        $d = New-TempDir
        try {
            Get-RsTestAssembly -ProjectPath (New-CsprojLegacy -Dir $d -Nombre "Tests") | Should -BeNullOrEmpty
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
