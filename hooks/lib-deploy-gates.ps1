<#
.SYNOPSIS
    Gates de coherencia de una carpeta de despliegue de procesos batch. Librería: dot-sourcear
    desde el hook que la necesite (hoy hooks\installer-batch.ps1), no se invoca sola.

.DESCRIPTION
    ⛔ POR QUÉ VIVE APARTE. Estos gates estaban soldados dentro de installer-batch.ps1, mezclados
    con sus Write-Host y sus exit. Para que se ejecutara la comprobación había que ejecutar antes
    todo el script: vswhere, msbuild, un workspace de cliente con sus .sln y un Rebuild completo.
    Eso no existe en CI, así que NINGUNO estaba probado — y el gate de binding redirects vivió
    desde la 2.15.8 auditando una sola de las dos carpetas de despliegue sin que saltara nada
    (ver CHANGELOG 3.7.0). Una comprobación cuya corrección no es observable no protege de nada.

    Reparto de responsabilidades, deliberado:
      - Aquí: DECIDIR. Estas funciones no imprimen ni terminan el proceso; devuelven el veredicto
        y las líneas de detalle ya formateadas.
      - En el hook: PRESENTAR. Los Write-Host y los exit 1 se quedan en installer-batch.ps1, que
        es quien sabe qué es bloqueante en su flujo.
    Así los gates se pueden ejercitar contra carpetas de prueba en un temp, en un segundo y sin
    Visual Studio: tests\DeployGates.Tests.ps1.

    "Carpeta de despliegue" = objeto con dos campos:
        @{ Etiqueta = 'paquete'|'carpeta viva'|...; Ruta = '<ruta absoluta>' }
    La etiqueta viaja en cada línea de detalle: son varias carpetas y saber en CUÁL está el
    desalineo es la mitad del diagnóstico.
#>

# ---------------------------------------------------------------------------------------------------
# GATE DE COHERENCIA. Todo .exe + DLL compartida desplegado debe ser de ESTE build. Un fichero
# anterior a $BuildStart = straggler de un build viejo = frankenbuild.
#
# Las DLL compartidas (Comun/BusComun/RSModel) no tienen strong-name y su AssemblyVersion es 1.0.*
# → el CLR enlaza por nombre simple → un exe viejo llama a un método con firma cambiada →
# recursión infinita → StackOverflowException al arrancar (regresión real, CHANGELOG 2.15.7).
# ---------------------------------------------------------------------------------------------------
function Test-RsCoherenciaBuild {
    param(
        [Parameter(Mandatory=$true)][string]$Carpeta,
        [Parameter(Mandatory=$true)][datetime]$BuildStart,
        [string[]]$SharedAssemblies = @('Comun','BusComun','RSModel')
    )

    $deployed = @(Get-ChildItem $Carpeta -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -eq '.exe' -or ($_.Extension -eq '.dll' -and $SharedAssemblies -contains $_.BaseName)
    })
    $exeCount   = @($deployed | Where-Object { $_.Extension -eq '.exe' }).Count
    $stragglers = @($deployed | Where-Object { $_.LastWriteTime -lt $BuildStart })

    # Sin ningún .exe no hay nada que validar: es un despliegue vacío, no un despliegue correcto.
    return @{
        ExeCount    = $exeCount
        Stragglers  = $stragglers
        Ok          = ($exeCount -gt 0 -and $stragglers.Count -eq 0)
    }
}

# ---------------------------------------------------------------------------------------------------
# GATE DE BINDING REDIRECTS. En carpeta de deploy compartida, last-writer-wins puede dejar un
# <exe>.exe.config viejo (bindingRedirect newVersion=X) junto a una System.*.dll/tercero nueva
# (AssemblyVersion=Y). El redirect apunta a una versión que ya no existe → FileLoadException en
# bucle → StackOverflow. "Terceros version-pinned = OK" es FALSO en carpeta compartida.
# Para cada redirect cuyo DLL está FÍSICAMENTE desplegado, newVersion debe == AssemblyName.Version.
#
# ⛔ Un gate que NO puede evaluar no reporta OK. Todo fallo de lectura (XML ilegible, SelectNodes
# roto, versión de DLL no leíble) va a NoEvaluable y tumba el veredicto, en vez de saltarse la
# comprobación con un aviso y acabar diciendo "OK" — que es justo lo que hacía antes.
# Única excepción legítima: BadImageFormatException = el fichero no es un assembly gestionado (un
# nativo que coincide en nombre con la identidad del redirect), así que ese redirect no le aplica.
# ---------------------------------------------------------------------------------------------------
function Test-RsBindingRedirects {
    param([Parameter(Mandatory=$true)][object[]]$Carpetas)

    $asmNs       = 'urn:schemas-microsoft-com:asm.v1'
    $mismatch    = @()
    $noEvaluable = @()
    $avisos      = @()

    foreach ($carpeta in $Carpetas) {
        foreach ($cfgFile in @(Get-ChildItem $carpeta.Ruta -File -Filter "*.exe.config" -ErrorAction SilentlyContinue)) {
            try { $xml = [xml](Get-Content $cfgFile.FullName -Raw) } catch {
                $noEvaluable += ("  {0} · {1}: XML ilegible — {2}" -f $carpeta.Etiqueta, $cfgFile.Name, $_.Exception.Message)
                continue
            }
            $nsm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
            $nsm.AddNamespace('a', $asmNs)
            try { $deps = @($xml.SelectNodes('//a:dependentAssembly', $nsm)) } catch {
                $noEvaluable += ("  {0} · {1}: SelectNodes falló — {2}" -f $carpeta.Etiqueta, $cfgFile.Name, $_.Exception.Message)
                continue
            }
            foreach ($dep in $deps) {
                $ident    = $dep.SelectSingleNode('a:assemblyIdentity', $nsm)
                $redirect = $dep.SelectSingleNode('a:bindingRedirect', $nsm)
                if (-not $ident -or -not $redirect) { continue }
                $name   = $ident.name
                $newVer = $redirect.newVersion
                if (-not $name -or -not $newVer) { continue }

                $dll = Join-Path $carpeta.Ruta "$name.dll"
                if (!(Test-Path $dll)) { continue }  # no desplegada → se resuelve de GAC, no aplica

                try { $realVer = [System.Reflection.AssemblyName]::GetAssemblyName($dll).Version }
                catch [System.BadImageFormatException] {
                    $avisos += "AVISO: $($carpeta.Etiqueta) · $name.dll no es un assembly gestionado — el redirect no aplica a ese fichero."
                    continue
                }
                catch {
                    $noEvaluable += ("  {0} · {1}: no se pudo leer la versión de {2}.dll — {3}" -f $carpeta.Etiqueta, $cfgFile.Name, $name, $_.Exception.Message)
                    continue
                }
                try { $cfgVer = [version]$newVer } catch { $cfgVer = $null }
                if ($cfgVer -eq $null -or $realVer -ne $cfgVer) {
                    $mismatch += ("  {0} · {1} · {2}: config newVersion={3} != DLL AssemblyVersion={4}" -f $carpeta.Etiqueta, $cfgFile.Name, $name, $newVer, $realVer)
                }
            }
        }
    }

    return @{
        Mismatch    = $mismatch
        NoEvaluable = $noEvaluable
        Avisos      = $avisos
        Ok          = ($mismatch.Count -eq 0 -and $noEvaluable.Count -eq 0)
    }
}

# ---------------------------------------------------------------------------------------------------
# GATE DE DEPENDENCIAS ODP.NET. Fallo silencioso en build, explosivo en ejecución: Comun.dll no
# referencia System.Text.Json & cía en su IL — quien las usa es Oracle.ManagedDataAccess.dll. Al
# compilar un EXE, MSBuild sigue la cadena Comun.dll -> Oracle.ManagedDataAccess.dll ->
# System.Text.Json <ver>, no encuentra esa versión en packages y DESCARTA la referencia SIN NINGÚN
# WARNING. El bin queda sin esas DLL y el proceso muere en el primer acceso a BD con un
# TypeInitializationException de OracleCommand. Aquí se exige presencia FÍSICA.
#
# Solo aplica donde Oracle.ManagedDataAccess.dll esté desplegado: Auditadas=0 significa "no aplica",
# no "correcto". El llamante debe distinguirlo al informar.
# ---------------------------------------------------------------------------------------------------
function Test-RsOdpDependencies {
    param(
        [Parameter(Mandatory=$true)][object[]]$Carpetas,
        [string[]]$Dependencias = @(
            'System.Text.Json', 'System.Diagnostics.DiagnosticSource', 'System.Text.Encodings.Web',
            'System.Collections.Immutable', 'System.IO.Pipelines', 'System.Formats.Asn1',
            'Microsoft.Bcl.AsyncInterfaces')
    )

    $faltan    = @()
    $auditadas = 0
    foreach ($carpeta in $Carpetas) {
        if (!(Test-Path (Join-Path $carpeta.Ruta "Oracle.ManagedDataAccess.dll"))) { continue }
        $auditadas++
        foreach ($d in $Dependencias) {
            if (!(Test-Path (Join-Path $carpeta.Ruta "$d.dll"))) {
                $faltan += ("  {0}: falta {1}.dll" -f $carpeta.Etiqueta, $d)
            }
        }
    }

    return @{
        Faltan       = $faltan
        Auditadas    = $auditadas
        Dependencias = $Dependencias
        Ok           = ($faltan.Count -eq 0)
    }
}

# ---------------------------------------------------------------------------------------------------
# *.dll.config huérfanos. Con la configuración centralizada de los batch ya no se generan: el CLR no
# lee <dll>.config para binding y eran ruido (ver references\batch-config.md). Los que quedan en las
# carpetas de despliegue son residuos de builds anteriores.
#
# Advisory puro: solo LOCALIZA. Borrarlos es decisión del llamante — son carpetas compartidas y en
# un workspace SIN centralizar un <dll>.config puede seguir siendo legítimo.
# ---------------------------------------------------------------------------------------------------
function Get-RsDllConfigHuerfanos {
    param([Parameter(Mandatory=$true)][object[]]$Carpetas)

    $encontrados = @()
    foreach ($carpeta in $Carpetas) {
        Get-ChildItem $carpeta.Ruta -File -Filter "*.dll.config" -ErrorAction SilentlyContinue |
            ForEach-Object { $encontrados += [pscustomobject]@{ Etiqueta = $carpeta.Etiqueta; File = $_ } }
    }
    return $encontrados
}
