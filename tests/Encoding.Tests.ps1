<#
    Tests Pester de la convención de codificación de los .ps1 del plugin.

    ⛔ Por qué existe este fichero: la convención "UTF-8 con BOM" ya estaba escrita en
    `hooks/README.md` y aun así se rompió tres veces más (`lib-pii.ps1`, `installer-batch.ps1`,
    `vcs-revert.ps1` llegaron a la 3.4.5 sin BOM y sin parsear bajo 5.1). Una convención que solo
    vive en un README no la comprueba nadie; ésta necesita un gate ejecutable.

    La causa de la reincidencia es mecánica, no de criterio: los editores y las herramientas de
    escritura automática guardan UTF-8 SIN BOM por defecto. Windows PowerShell 5.1 —el intérprete
    con el que `plugin.json` y `runner/runner.ps1` lanzan los hooks (`powershell -File ...`)— sin
    BOM decodifica el fichero con la codepage ANSI del sistema. Un guion largo (U+2014, `E2 80 94`)
    se lee entonces como `â€"`: esa comilla doble cierra la cadena en curso y el script **ni
    siquiera parsea**. El error se propaga a las líneas siguientes, así que el síntoma aparece lejos
    del carácter culpable.

    De las tres aserciones, la del BOM es la que de verdad protege en CI: PowerShell Core (7.x, el
    del runner Ubuntu) sí lee UTF-8 sin BOM correctamente, de modo que allí un fichero sin BOM
    parsearía sin quejarse y solo reventaría en la máquina Windows del usuario. Por eso el BOM se
    comprueba como byte, no a través del parser.

    Ejecutar: Invoke-Pester tests/Encoding.Tests.ps1
#>

BeforeDiscovery {
    $RepoRaiz = Split-Path -Parent $PSScriptRoot

    # `.venv` es una dependencia externa (Activate.ps1 lo genera Python), no código del plugin.
    $script:FicherosPs1 = Get-ChildItem -Path $RepoRaiz -Recurse -Include *.ps1, *.psm1 -File |
        Where-Object { $_.FullName -notlike "*$([IO.Path]::DirectorySeparatorChar).venv$([IO.Path]::DirectorySeparatorChar)*" } |
        ForEach-Object {
            @{
                Ruta     = $_.FullName
                Relativa = $_.FullName.Substring($RepoRaiz.Length + 1)
            }
        }
}

Describe "Codificación de los scripts PowerShell del repo" {

    # El total viaja por -ForEach a propósito: lo que se descubre en Discovery no es visible desde
    # el cuerpo de un It (fase Run), y una comprobación directa sobre la variable daría siempre 0.
    It "hay ficheros .ps1 que comprobar (guarda contra un descubrimiento vacío)" -ForEach @(@{ Total = $FicherosPs1.Count }) {
        # Sin esto, un fallo del Get-ChildItem dejaría la suite en verde sin haber comprobado nada.
        $Total | Should -BeGreaterThan 50
    }

    Context "<Relativa>" -ForEach $FicherosPs1 {

        It "empieza por el BOM UTF-8 (EF BB BF)" {
            $bytes = [System.IO.File]::ReadAllBytes($Ruta)
            $tieneBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            # Aserción sobre un booleano ya calculado: el mensaje de fallo dice qué falta, no vuelca bytes.
            $tieneBom | Should -BeTrue -Because "sin BOM, Windows PowerShell 5.1 lo decodifica como ANSI y los no-ASCII rompen el parser"
        }

        It "es UTF-8 estricto válido" {
            # Si un fichero fuese realmente ANSI, anteponerle el BOM lo declararía UTF-8 y corrompería
            # el texto. Esta aserción es la que hace que "añadir BOM" sea siempre una operación segura.
            $bytes = [System.IO.File]::ReadAllBytes($Ruta)
            $strict = [System.Text.UTF8Encoding]::new($false, $true)
            { [void]$strict.GetString($bytes) } | Should -Not -Throw
        }

        It "parsea sin errores de sintaxis" {
            $errores = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($Ruta, [ref]$null, [ref]$errores)
            $detalle = if ($errores) { ($errores | ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.Message)" }) -join ' | ' } else { '' }
            $errores.Count | Should -Be 0 -Because "el parser reportó: $detalle"
        }

        It "no usa Join-Path con tres o más argumentos posicionales" {
            # -AdditionalChildPath es de PowerShell 6+. En Windows PowerShell 5.1 -el interprete
            # con el que plugin.json y runner.ps1 lanzan los hooks- el tercer argumento no encaja
            # en ningun parametro y la llamada falla en EJECUCION, no al parsear: por eso el
            # parser no lo caza y hace falta esta comprobacion aparte. Llevo 30 apariciones en la
            # suite dando 132 fallos que parecian de codigo (ver CHANGELOG 3.5.1).
            # Forma correcta: Join-Path $base "a/b/c" -- la barra vale en Windows y en Linux.
            $lineas = [System.IO.File]::ReadAllLines($Ruta)
            $malas = @()
            for ($i = 0; $i -lt $lineas.Count; $i++) {
                # Join-Path seguido de dos o mas literales entrecomillados = 3+ posicionales.
                if ($lineas[$i] -match 'Join-Path\s+[^\r\n|;)]*?"[^"]*"\s+"') {
                    $malas += "L$($i + 1): $($lineas[$i].Trim())"
                }
            }
            $malas.Count | Should -Be 0 -Because "no funcionan en PowerShell 5.1: $($malas -join ' | ')"
        }
    }
}
