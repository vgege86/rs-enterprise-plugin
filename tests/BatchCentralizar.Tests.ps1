<#
    Tests Pester de hooks/batch-centralizar.ps1 — el hook que detecta si la configuracion de los
    batch .NET Framework de un workspace esta centralizada (Batch\App.Batch.config +
    Batch\Directory.Build.targets) y, con -Aplicar, la centraliza.

    El hook se invoca como proceso contra workspaces sinteticos y se comprueba su JSON: es un
    script con param() y efectos en disco, no una libreria dot-sourceable.

    Cada bloque corresponde a una cicatriz real, no a una hipotesis:
      - app.config con <probing privatePath>/loadFromRemoteSources -> EXCEPCION, no se retira.
        Son los procesos que hospedan un AppDomain hijo; unificarlos los deja sin arrancar.
      - app.config con secciones propias (appSettings, ...) -> REVISAR, no se retira.
        Retirarlo perderia configuracion del proyecto en silencio.
      - HintPath de ODP.NET sin resolver -> BLOCKED sin escribir NADA.
        Un Directory.Build.targets a medias no arregla el descarte silencioso de referencias:
        deja el bin sin System.Text.Json y el proceso muere en el primer acceso a BD.
      - -Aplicar dos veces -> no pisa lo ya creado (idempotente).

    Ejecutar: Invoke-Pester tests/BatchCentralizar.Tests.ps1
#>

BeforeAll {
    $script:Hook = Join-Path (Split-Path -Parent $PSScriptRoot) "hooks\batch-centralizar.ps1"

    function New-DirPrueba([string]$Prefijo) {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefijo + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }

    # Assemblies reales: GetAssemblyName necesita metadatos validos, no ficheros de relleno.
    # Se toman del propio GAC/framework para no depender de ningun workspace de cliente.
    function Copy-AssemblyReal([string]$Destino, [string]$Nombre) {
        $origen = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "System.Xml.dll"
        Copy-Item $origen (Join-Path $Destino "$Nombre.dll") -Force
    }

    function New-WorkspacePrueba {
        param([string[]]$ConOdp = @(), [switch]$SinHintPath)

        $ws = New-DirPrueba "rsbc_"
        $batch = Join-Path $ws "Batch"
        $pkg   = Join-Path $ws "packages"
        New-Item -ItemType Directory -Path $batch -Force | Out-Null
        New-Item -ItemType Directory -Path $pkg   -Force | Out-Null

        foreach ($n in $ConOdp) { Copy-AssemblyReal $pkg $n }

        $refs = ""
        if (-not $SinHintPath) {
            foreach ($n in $ConOdp) {
                $refs += "    <Reference Include=`"$n, Version=1.0.0.0, Culture=neutral`">`r`n"
                $refs += "      <HintPath>..\..\packages\$n.dll</HintPath>`r`n"
                $refs += "    </Reference>`r`n"
            }
        } else {
            # Referencia a ODP.NET SIN HintPath: el hook debe detectarla y no poder resolverla.
            $refs = "    <Reference Include=`"Oracle.ManagedDataAccess`" />`r`n"
        }

        $dirNormal = Join-Path $batch "Normal"
        New-Item -ItemType Directory -Path $dirNormal -Force | Out-Null
        Set-Content (Join-Path $dirNormal "Normal.csproj") -Encoding UTF8 -Value @"
<Project ToolsVersion="15.0">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFrameworkVersion>v4.8</TargetFrameworkVersion></PropertyGroup>
  <ItemGroup>
$refs  </ItemGroup>
  <ItemGroup><None Include="app.config" /></ItemGroup>
</Project>
"@
        Set-Content (Join-Path $dirNormal "app.config") -Encoding UTF8 -Value @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <startup><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.8" /></startup>
</configuration>
"@
        return $ws
    }

    function Add-ProyectoPrueba([string]$Workspace, [string]$Nombre, [string]$AppConfig) {
        $d = Join-Path (Join-Path $Workspace "Batch") $Nombre
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content (Join-Path $d "$Nombre.csproj") -Encoding UTF8 -Value @"
<Project ToolsVersion="15.0">
  <PropertyGroup><OutputType>Exe</OutputType></PropertyGroup>
  <ItemGroup><None Include="app.config" /></ItemGroup>
</Project>
"@
        Set-Content (Join-Path $d "app.config") -Encoding UTF8 -Value $AppConfig
    }

    function Invoke-Hook {
        param([string]$Workspace, [switch]$Aplicar)
        $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:Hook,$Workspace)
        if ($Aplicar) { $args += '-Aplicar' }
        $out = & powershell @args 2>&1 | Out-String
        return ($out | ConvertFrom-Json)
    }

    $script:OdpCompleto = @('Oracle.ManagedDataAccess','System.Text.Json','System.Diagnostics.DiagnosticSource',
                            'System.Text.Encodings.Web','System.Collections.Immutable','System.IO.Pipelines',
                            'System.Formats.Asn1','Microsoft.Bcl.AsyncInterfaces')

    $script:CfgProbing = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <runtime>
    <loadFromRemoteSources enabled="true" />
    <assemblyBinding xmlns="urn:schemas-microsoft-com:asm.v1"><probing privatePath="Modulos" /></assemblyBinding>
  </runtime>
</configuration>
"@

    $script:CfgAppSettings = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <startup><supportedRuntime version="v4.0" /></startup>
  <appSettings><add key="RutaSalida" value="D:\salida" /></appSettings>
</configuration>
"@
}

Describe "Deteccion (modo informe, sin escribir)" {

    It "un workspace sin los dos ficheros no esta centralizado y pide accion" {
        $ws = New-WorkspacePrueba -ConOdp $script:OdpCompleto
        $r = Invoke-Hook -Workspace $ws
        $r.centralizado | Should -BeFalse
        $r.status       | Should -Be "NEEDS_ACTION"
    }

    It "el modo informe NO escribe nada en el workspace" {
        $ws = New-WorkspacePrueba -ConOdp $script:OdpCompleto
        Invoke-Hook -Workspace $ws | Out-Null
        (Test-Path (Join-Path $ws "Batch\App.Batch.config"))        | Should -BeFalse
        (Test-Path (Join-Path $ws "Batch\Directory.Build.targets")) | Should -BeFalse
        (Test-Path (Join-Path $ws "Batch\Normal\app.config"))       | Should -BeTrue
    }

    It "clasifica como EXCEPCION el app.config con probing privatePath y loadFromRemoteSources" {
        $ws = New-WorkspacePrueba -ConOdp $script:OdpCompleto
        Add-ProyectoPrueba $ws "Motor" $script:CfgProbing
        $r = Invoke-Hook -Workspace $ws
        $motor = $r.proyectos | Where-Object { $_.nombre -eq "Motor" }
        $motor.clase   | Should -Be "excepcion"
        $motor.motivos | Should -Contain "probing privatePath"
        $motor.motivos | Should -Contain "loadFromRemoteSources"
    }

    It "clasifica como REVISAR el app.config con secciones propias" {
        $ws = New-WorkspacePrueba -ConOdp $script:OdpCompleto
        Add-ProyectoPrueba $ws "Otro" $script:CfgAppSettings
        $r = Invoke-Hook -Workspace $ws
        ($r.proyectos | Where-Object { $_.nombre -eq "Otro" }).clase | Should -Be "revisar"
    }

    It "resuelve el HintPath de las 8 dependencias ODP.NET requeridas" {
        $ws = New-WorkspacePrueba -ConOdp $script:OdpCompleto
        $r = Invoke-Hook -Workspace $ws
        @($r.odp.noResueltas).Count | Should -Be 0
        @($r.odp.resueltas).Count   | Should -Be 8
    }

    It "un workspace sin carpeta Batch da BLOCKED" {
        $ws = New-DirPrueba "rsbc_"
        $r = Invoke-Hook -Workspace $ws
        $r.status | Should -Be "BLOCKED"
    }
}

Describe "Centralizacion (-Aplicar)" {

    It "crea los dos ficheros y retira solo el app.config CENTRALIZABLE" {
        $ws = New-WorkspacePrueba -ConOdp $script:OdpCompleto
        Add-ProyectoPrueba $ws "Motor" $script:CfgProbing
        Add-ProyectoPrueba $ws "Otro"  $script:CfgAppSettings

        $r = Invoke-Hook -Workspace $ws -Aplicar

        (Test-Path (Join-Path $ws "Batch\App.Batch.config"))        | Should -BeTrue
        (Test-Path (Join-Path $ws "Batch\Directory.Build.targets")) | Should -BeTrue
        (Test-Path (Join-Path $ws "Batch\Normal\app.config"))       | Should -BeFalse  # centralizable
        (Test-Path (Join-Path $ws "Batch\Motor\app.config"))        | Should -BeTrue   # excepcion
        (Test-Path (Join-Path $ws "Batch\Otro\app.config"))         | Should -BeTrue   # revisar
    }

    # ⛔ Sin angulos en los nombres de It: Pester 6 expande {angulo}texto{angulo} como plantilla
    # de -ForEach y el nombre deja de parsear.
    It 'elimina el item None Include=app.config del csproj centralizado' {
        $ws = New-WorkspacePrueba -ConOdp $script:OdpCompleto
        Invoke-Hook -Workspace $ws -Aplicar | Out-Null
        (Get-Content (Join-Path $ws "Batch\Normal\Normal.csproj") -Raw) | Should -Not -Match 'None\s+Include="app\.config"'
    }

    It "genera XML valido en los dos ficheros" {
        $ws = New-WorkspacePrueba -ConOdp $script:OdpCompleto
        Invoke-Hook -Workspace $ws -Aplicar | Out-Null
        { [xml](Get-Content (Join-Path $ws "Batch\App.Batch.config") -Raw) }        | Should -Not -Throw
        { [xml](Get-Content (Join-Path $ws "Batch\Directory.Build.targets") -Raw) } | Should -Not -Throw
    }

    It "declara una Reference con Private=true por dependencia ODP.NET" {
        $ws = New-WorkspacePrueba -ConOdp $script:OdpCompleto
        Invoke-Hook -Workspace $ws -Aplicar | Out-Null
        $targets = [xml](Get-Content (Join-Path $ws "Batch\Directory.Build.targets") -Raw)
        $refs = @($targets.Project.ItemGroup.Reference)
        $refs.Count | Should -Be 8
        @($refs | Where-Object { $_.Private -eq 'true' }).Count | Should -Be 8
    }

    It "asigna AppConfig solo si el proyecto NO tiene app.config propio" {
        $ws = New-WorkspacePrueba -ConOdp $script:OdpCompleto
        Invoke-Hook -Workspace $ws -Aplicar | Out-Null
        $raw = Get-Content (Join-Path $ws "Batch\Directory.Build.targets") -Raw
        $raw | Should -Match 'AppConfig Condition='
        $raw | Should -Match '!Exists\('
        # App.Batch.config NO lleva elemento runtime: lo genera MSBuild en cada build. Se comprueba
        # sobre el XML, no sobre el texto — los comentarios del fichero nombran ese bloque.
        $cfg = [xml](Get-Content (Join-Path $ws "Batch\App.Batch.config") -Raw)
        @($cfg.configuration.ChildNodes | Where-Object { $_.LocalName -eq 'runtime' }).Count | Should -Be 0
    }

    It "es idempotente: una segunda pasada no pisa lo ya creado" {
        $ws = New-WorkspacePrueba -ConOdp $script:OdpCompleto
        Invoke-Hook -Workspace $ws -Aplicar | Out-Null
        $antes = (Get-Content (Join-Path $ws "Batch\Directory.Build.targets") -Raw)
        $r = Invoke-Hook -Workspace $ws -Aplicar
        (Get-Content (Join-Path $ws "Batch\Directory.Build.targets") -Raw) | Should -Be $antes
        ($r.acciones -join '|') | Should -Match 'ya existia'
    }

    It "sin HintPath resoluble da BLOCKED y NO escribe nada" {
        $ws = New-WorkspacePrueba -SinHintPath
        $r = Invoke-Hook -Workspace $ws -Aplicar
        $r.status | Should -Be "BLOCKED"
        (Test-Path (Join-Path $ws "Batch\App.Batch.config"))        | Should -BeFalse
        (Test-Path (Join-Path $ws "Batch\Directory.Build.targets")) | Should -BeFalse
        (Test-Path (Join-Path $ws "Batch\Normal\app.config"))       | Should -BeTrue
    }
}
