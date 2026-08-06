<#
    Tests Pester de hooks/lib-deploy-gates.ps1 — los gates de coherencia de una carpeta de
    despliegue de procesos batch, que ejercita hooks/installer-batch.ps1.

    ⛔ POR QUE EXISTE ESTA SUITE. Los gates vivian soldados dentro de installer-batch.ps1: para que
    se ejecutara la comprobacion habia que ejecutar antes todo el script (vswhere, msbuild, un
    workspace de cliente con sus .sln y un Rebuild completo). Eso no existe en CI, asi que ninguno
    estaba probado — y el gate de binding redirects vivio desde la 2.15.8 auditando UNA SOLA de las
    dos carpetas de despliegue sin que saltara nada. Una comprobacion cuya correccion no es
    observable no protege de nada.

    Cada bloque corresponde a una cicatriz real, no a una hipotesis:
      - .exe.config ilegible -> NO reporta OK. Antes hacia AVISO + continue y el script terminaba
        imprimiendo "Gate de binding redirects OK": falso verde (CHANGELOG 3.7.0).
      - DLL no gestionado -> aviso y SIGUE siendo OK. Es la unica excepcion legitima: un nativo que
        coincide en nombre con la identidad del redirect no es el assembly al que apunta.
      - Dos carpetas -> el hallazgo lleva la etiqueta de la carpeta correcta. Auditar solo la del
        paquete dejaba pasar el desalineo de C:\ais\<P>\Procesos\Exes, que es donde los procesos
        corren de verdad.
      - ODP.NET sin satelites -> el bin compila sin warning y el proceso muere en el primer acceso
        a BD con un TypeInitializationException de OracleCommand.
      - Straggler de otro build -> frankenbuild -> StackOverflow al arrancar (CHANGELOG 2.15.7).

    Los assemblies de prueba son copias renombradas de una DLL gestionada REAL del runtime:
    GetAssemblyName necesita metadatos validos, un fichero de relleno no sirve. No depende de
    ningun workspace de cliente, asi que corre en CI.

    Ejecutar: Invoke-Pester tests/DeployGates.Tests.ps1
#>

BeforeAll {
    . (Join-Path $PSScriptRoot "../hooks/lib-deploy-gates.ps1")

    function New-DeployDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("rsdg_" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }

    function New-Carpeta([string]$Etiqueta, [string]$Ruta) {
        return [pscustomobject]@{ Etiqueta = $Etiqueta; Ruta = $Ruta }
    }

    # Copia una DLL gestionada real bajo otro nombre y devuelve su AssemblyVersion verdadera.
    function Copy-AssemblyGestionado([string]$Dir, [string]$Nombre) {
        $origen = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "System.Xml.dll"
        $destino = Join-Path $Dir "$Nombre.dll"
        Copy-Item $origen $destino -Force
        return [System.Reflection.AssemblyName]::GetAssemblyName($destino).Version.ToString()
    }

    function New-ExeConfig {
        param([string]$Dir, [string]$Exe, [string]$Assembly, [string]$NewVersion)
        $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <runtime>
    <assemblyBinding xmlns="urn:schemas-microsoft-com:asm.v1">
      <dependentAssembly>
        <assemblyIdentity name="$Assembly" publicKeyToken="b77a5c561934e089" culture="neutral" />
        <bindingRedirect oldVersion="0.0.0.0-99.0.0.0" newVersion="$NewVersion" />
      </dependentAssembly>
    </assemblyBinding>
  </runtime>
</configuration>
"@
        Set-Content (Join-Path $Dir "$Exe.exe.config") -Value $xml -Encoding UTF8
    }

    function New-ExeFalso([string]$Dir, [string]$Nombre, [datetime]$Fecha) {
        $p = Join-Path $Dir "$Nombre.exe"
        Set-Content $p -Value "binario de prueba" -Encoding UTF8
        (Get-Item $p).LastWriteTime = $Fecha
        return $p
    }

    $script:OdpSatelites = @('System.Text.Json','System.Diagnostics.DiagnosticSource','System.Text.Encodings.Web',
                             'System.Collections.Immutable','System.IO.Pipelines','System.Formats.Asn1',
                             'Microsoft.Bcl.AsyncInterfaces')
}

Describe "Gate de binding redirects" {

    It "OK cuando newVersion coincide con la AssemblyVersion del DLL desplegado" {
        $d = New-DeployDir
        $ver = Copy-AssemblyGestionado $d "Tercero"
        New-ExeConfig -Dir $d -Exe "RSProc" -Assembly "Tercero" -NewVersion $ver

        $r = Test-RsBindingRedirects -Carpetas @(New-Carpeta 'paquete' $d)
        $r.Ok                | Should -BeTrue
        $r.Mismatch.Count    | Should -Be 0
        $r.NoEvaluable.Count | Should -Be 0
    }

    It "detecta el desalineo cuando newVersion no coincide con el DLL" {
        $d = New-DeployDir
        Copy-AssemblyGestionado $d "Tercero" | Out-Null
        New-ExeConfig -Dir $d -Exe "RSProc" -Assembly "Tercero" -NewVersion "10.0.0.9"

        $r = Test-RsBindingRedirects -Carpetas @(New-Carpeta 'paquete' $d)
        $r.Ok             | Should -BeFalse
        $r.Mismatch.Count | Should -Be 1
        $r.Mismatch[0]    | Should -Match 'newVersion=10\.0\.0\.9'
    }

    It "ignora el redirect cuyo DLL NO esta desplegado (se resuelve del GAC)" {
        $d = New-DeployDir
        New-ExeConfig -Dir $d -Exe "RSProc" -Assembly "NoDesplegada" -NewVersion "1.2.3.4"

        $r = Test-RsBindingRedirects -Carpetas @(New-Carpeta 'paquete' $d)
        $r.Ok             | Should -BeTrue
        $r.Mismatch.Count | Should -Be 0
    }

    It "NO reporta OK si no puede parsear un .exe.config" {
        # El falso verde de la 2.15.8: antes esto era AVISO + continue y el gate decia OK.
        $d = New-DeployDir
        Set-Content (Join-Path $d "RSCore.exe.config") -Value "esto no es XML valido {{{" -Encoding UTF8

        $r = Test-RsBindingRedirects -Carpetas @(New-Carpeta 'paquete' $d)
        $r.Ok                | Should -BeFalse
        $r.NoEvaluable.Count | Should -Be 1
        $r.NoEvaluable[0]    | Should -Match 'XML ilegible'
    }

    It "avisa y SIGUE siendo OK si el fichero no es un assembly gestionado" {
        # Unica excepcion legitima: un nativo que coincide en nombre con la identidad del redirect.
        $d = New-DeployDir
        Set-Content (Join-Path $d "Tercero.dll") -Value "MZ esto no es un assembly" -Encoding UTF8
        New-ExeConfig -Dir $d -Exe "RSProc" -Assembly "Tercero" -NewVersion "1.0.0.0"

        $r = Test-RsBindingRedirects -Carpetas @(New-Carpeta 'paquete' $d)
        $r.Ok                | Should -BeTrue
        $r.NoEvaluable.Count | Should -Be 0
        $r.Avisos.Count      | Should -Be 1
        $r.Avisos[0]         | Should -Match 'no es un assembly gestionado'
    }

    It "trata un newVersion no parseable como desalineo, no como OK" {
        $d = New-DeployDir
        Copy-AssemblyGestionado $d "Tercero" | Out-Null
        New-ExeConfig -Dir $d -Exe "RSProc" -Assembly "Tercero" -NewVersion "no-es-una-version"

        $r = Test-RsBindingRedirects -Carpetas @(New-Carpeta 'paquete' $d)
        $r.Ok             | Should -BeFalse
        $r.Mismatch.Count | Should -Be 1
    }

    It "audita las DOS carpetas y etiqueta en cual esta el desalineo" {
        # La regresion de la 2.15.8: solo se miraba la carpeta del paquete.
        $dPaquete = New-DeployDir
        $dViva    = New-DeployDir
        $ver = Copy-AssemblyGestionado $dPaquete "Tercero"
        New-ExeConfig -Dir $dPaquete -Exe "RSProc" -Assembly "Tercero" -NewVersion $ver   # alineada
        Copy-AssemblyGestionado $dViva "Tercero" | Out-Null
        New-ExeConfig -Dir $dViva -Exe "RSCore" -Assembly "Tercero" -NewVersion "10.0.0.9" # rota

        $r = Test-RsBindingRedirects -Carpetas @(
            (New-Carpeta 'paquete' $dPaquete),
            (New-Carpeta 'carpeta viva' $dViva))

        $r.Ok             | Should -BeFalse
        $r.Mismatch.Count | Should -Be 1
        $r.Mismatch[0]    | Should -Match 'carpeta viva'
        $r.Mismatch[0]    | Should -Match 'RSCore\.exe\.config'
    }

    It "no revienta con una carpeta inexistente ni con una vacia" {
        $vacia = New-DeployDir
        $r = Test-RsBindingRedirects -Carpetas @(
            (New-Carpeta 'vacia' $vacia),
            (New-Carpeta 'fantasma' (Join-Path $vacia "no-existe")))
        $r.Ok | Should -BeTrue
    }
}

Describe "Gate de dependencias ODP.NET" {

    It "OK cuando estan los 7 satelites junto a Oracle.ManagedDataAccess.dll" {
        $d = New-DeployDir
        Copy-AssemblyGestionado $d "Oracle.ManagedDataAccess" | Out-Null
        foreach ($s in $script:OdpSatelites) { Copy-AssemblyGestionado $d $s | Out-Null }

        $r = Test-RsOdpDependencies -Carpetas @(New-Carpeta 'paquete' $d)
        $r.Ok           | Should -BeTrue
        $r.Auditadas    | Should -Be 1
        $r.Faltan.Count | Should -Be 0
    }

    It "detecta el satelite que falta" {
        $d = New-DeployDir
        Copy-AssemblyGestionado $d "Oracle.ManagedDataAccess" | Out-Null
        foreach ($s in $script:OdpSatelites) {
            if ($s -eq 'System.Text.Json') { continue }   # el que MSBuild descarta sin warning
            Copy-AssemblyGestionado $d $s | Out-Null
        }

        $r = Test-RsOdpDependencies -Carpetas @(New-Carpeta 'paquete' $d)
        $r.Ok           | Should -BeFalse
        $r.Faltan.Count | Should -Be 1
        $r.Faltan[0]    | Should -Match 'System\.Text\.Json\.dll'
    }

    It "no aplica si Oracle.ManagedDataAccess.dll no esta desplegado" {
        $d = New-DeployDir
        $r = Test-RsOdpDependencies -Carpetas @(New-Carpeta 'paquete' $d)
        $r.Auditadas | Should -Be 0
        $r.Ok        | Should -BeTrue   # Auditadas=0 significa "no aplica", no "correcto"
    }

    It "respeta la lista override de dependencias" {
        $d = New-DeployDir
        Copy-AssemblyGestionado $d "Oracle.ManagedDataAccess" | Out-Null

        $r = Test-RsOdpDependencies -Carpetas @(New-Carpeta 'paquete' $d) -Dependencias @('Solo.Esta')
        $r.Faltan.Count       | Should -Be 1
        $r.Faltan[0]          | Should -Match 'Solo\.Esta\.dll'
        $r.Dependencias.Count | Should -Be 1
    }

    It "reporta la carpeta concreta cuando audita varias" {
        $dOk   = New-DeployDir
        $dRoto = New-DeployDir
        foreach ($dir in @($dOk, $dRoto)) { Copy-AssemblyGestionado $dir "Oracle.ManagedDataAccess" | Out-Null }
        foreach ($s in $script:OdpSatelites) { Copy-AssemblyGestionado $dOk $s | Out-Null }

        $r = Test-RsOdpDependencies -Carpetas @(
            (New-Carpeta 'paquete' $dOk),
            (New-Carpeta 'carpeta viva' $dRoto))
        $r.Auditadas | Should -Be 2
        $r.Ok        | Should -BeFalse
        @($r.Faltan | Where-Object { $_ -match 'carpeta viva' }).Count | Should -Be 7
    }
}

Describe "Gate de coherencia de build" {

    It "OK cuando todo lo desplegado es de este build" {
        $d = New-DeployDir
        $inicio = (Get-Date).AddMinutes(-5)
        New-ExeFalso $d "RSProcIN" (Get-Date) | Out-Null
        New-ExeFalso $d "RSProcOUT" (Get-Date) | Out-Null

        $r = Test-RsCoherenciaBuild -Carpeta $d -BuildStart $inicio
        $r.Ok               | Should -BeTrue
        $r.ExeCount         | Should -Be 2
        $r.Stragglers.Count | Should -Be 0
    }

    It "detecta el straggler de otro build" {
        $d = New-DeployDir
        $inicio = (Get-Date).AddMinutes(-5)
        New-ExeFalso $d "RSProcIN" (Get-Date) | Out-Null
        New-ExeFalso $d "RSViejo"  ((Get-Date).AddDays(-3)) | Out-Null

        $r = Test-RsCoherenciaBuild -Carpeta $d -BuildStart $inicio
        $r.Ok               | Should -BeFalse
        $r.Stragglers.Count | Should -Be 1
        $r.Stragglers[0].Name | Should -Be "RSViejo.exe"
    }

    It "vigila las DLL compartidas, no solo los .exe" {
        $d = New-DeployDir
        $inicio = (Get-Date).AddMinutes(-5)
        New-ExeFalso $d "RSProcIN" (Get-Date) | Out-Null
        $dll = Join-Path $d "Comun.dll"
        Set-Content $dll -Value "x" -Encoding UTF8
        (Get-Item $dll).LastWriteTime = (Get-Date).AddDays(-3)

        $r = Test-RsCoherenciaBuild -Carpeta $d -BuildStart $inicio
        $r.Ok                 | Should -BeFalse
        $r.Stragglers[0].Name | Should -Be "Comun.dll"
    }

    It "ignora las DLL que no son compartidas" {
        $d = New-DeployDir
        $inicio = (Get-Date).AddMinutes(-5)
        New-ExeFalso $d "RSProcIN" (Get-Date) | Out-Null
        $dll = Join-Path $d "Tercero.dll"
        Set-Content $dll -Value "x" -Encoding UTF8
        (Get-Item $dll).LastWriteTime = (Get-Date).AddDays(-3)

        $r = Test-RsCoherenciaBuild -Carpeta $d -BuildStart $inicio
        $r.Ok | Should -BeTrue
    }

    It "sin ningun .exe no es un despliegue correcto" {
        $d = New-DeployDir
        $r = Test-RsCoherenciaBuild -Carpeta $d -BuildStart (Get-Date).AddMinutes(-5)
        $r.ExeCount | Should -Be 0
        $r.Ok       | Should -BeFalse
    }
}

Describe "Localizacion de *.dll.config huerfanos" {

    It "los encuentra en las dos carpetas y los etiqueta" {
        $dA = New-DeployDir
        $dB = New-DeployDir
        Set-Content (Join-Path $dA "Comun.dll.config")    -Value "<configuration />" -Encoding UTF8
        Set-Content (Join-Path $dB "BusComun.dll.config") -Value "<configuration />" -Encoding UTF8
        Set-Content (Join-Path $dB "RSCore.exe.config")   -Value "<configuration />" -Encoding UTF8

        $r = @(Get-RsDllConfigHuerfanos -Carpetas @(
            (New-Carpeta 'paquete' $dA),
            (New-Carpeta 'carpeta viva' $dB)))

        $r.Count | Should -Be 2   # el .exe.config no cuenta
        @($r | Where-Object { $_.Etiqueta -eq 'carpeta viva' }).Count | Should -Be 1
    }

    It "devuelve vacio si no hay ninguno" {
        $d = New-DeployDir
        @(Get-RsDllConfigHuerfanos -Carpetas @(New-Carpeta 'paquete' $d)).Count | Should -Be 0
    }
}
