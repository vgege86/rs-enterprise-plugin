<#
    Tests Pester del parser de logs de error web (hooks/parse-weblog.ps1).

    ⛔ Por qué existe este fichero: hasta la 3.20.0 el hook no reconocía el formato propio de la
    AgendaWeb uCollect/RS (`Error: (11/08/2026 13:45) - Codigo error: ... Descripción error: ...`).
    Sobre un log real de 55.494 líneas con 2.544 eventos devolvía `total_events: 1`,
    `distinct_signatures: 1` y `format_detected: "stacktrace-plano"` — con `success: true`. Un log
    lleno de errores se tría entonces como "un error suelto, de infraestructura, no abrir tareas".

    Es el mismo patrón de fallo que el parser de `dotnet test` de la 3.15.0 (ver TrxParser.Tests.ps1):
    la salida es sintácticamente correcta y el JSON parece sano, así que ninguna revisión posterior
    lo caza. Lo único que lo detecta es un test que le dé al parser un log de ese formato y exija
    un recuento. Eso es lo que hay aquí.

    Sin dependencia de ningún log real: se usa tests/fixtures/weblog-rs.log (12 eventos recortados
    y anonimizados) y ficheros fabricados en $TestDrive.

    Ejecutar: Invoke-Pester tests/WebLogParser.Tests.ps1
#>

BeforeAll {
    $script:hook    = Join-Path $PSScriptRoot "../hooks/parse-weblog.ps1"
    $script:fixture = Join-Path $PSScriptRoot "fixtures/weblog-rs.log"

    function Invoke-Weblog {
        param([string]$Ruta, [hashtable]$Opciones = @{})
        $args = @{ Path = $Ruta; MaxSignatures = 50; Samples = 1 }
        foreach ($k in $Opciones.Keys) { $args[$k] = $Opciones[$k] }
        $texto = & $script:hook @args
        return ($texto -join "`n" | ConvertFrom-Json)
    }

    function Firma($res, [string]$patronMensaje) {
        return @($res.signatures | Where-Object { $_.message -match $patronMensaje })[0]
    }

    function Get-TextoSalida($res) {
        # Todo el texto que sale del hook hacia un ticket. Se concatena a mano y no con
        # ConvertTo-Json: el serializador escapa '<' como < y una aserción sobre '<val>'
        # pasaría a fallar por el escape, no por el contenido.
        return (@($res.signatures | ForEach-Object { $_.message; $_.origin; @($_.samples).text }) -join "`n")
    }
}

Describe "parse-weblog.ps1 — formato rs-cerrores" {

    BeforeAll { $script:res = Invoke-Weblog $script:fixture }

    It "existen el hook y el fixture" {
        Test-Path $script:hook    | Should -BeTrue
        Test-Path $script:fixture | Should -BeTrue
    }

    It "reconoce el formato y NO lo confunde con un volcado plano" {
        $script:res.success         | Should -BeTrue
        $script:res.format_detected | Should -Be "rs-cerrores"
    }

    It "cuenta un evento por cabecera, no uno por fichero" {
        # 13 cabeceras en el fixture; la de nivel Warn no entra con -Niveles ERROR,FATAL.
        $script:res.total_events        | Should -Be 12
        $script:res.distinct_signatures | Should -Be 11
    }

    It "abre evento con la hora de UNA cifra (el 20% de un log real la lleva)" {
        # "Error: (20/02/2026 8:41)" — exigir HH de dos cifras tira estos eventos Y los pega
        # como continuación del anterior, falseando además la firma de ese otro evento.
        $f = Firma $script:res 'ORA-00001'
        $f.first_seen | Should -Be "2026-02-20 08:41:00"
    }

    It "admite los segundos cuando el log los trae" {
        (Firma $script:res 'ORA-00933').last_seen | Should -Be "2026-08-07 08:03:22"
    }

    It "normaliza el stamp a una forma ordenable (first_seen <= last_seen como texto)" {
        $f = Firma $script:res 'ULUFCOD'
        $f.first_seen | Should -Be "2026-08-11 13:45:00"
        $f.last_seen  | Should -Be "2026-08-11 13:47:00"
        ($f.first_seen -le $f.last_seen) | Should -BeTrue
    }

    It "usa el código ORA como excepción, no un token *Exception" {
        (Firma $script:res 'ULUFCOD').exception | Should -Be "ORA-12899"
    }

    It "usa el 'Codigo error' cuando no hay ORA" {
        (Firma $script:res 'ThreadAbortException').exception | Should -Be "COD200"
    }

    It "cae a la excepción .NET cuando el código no discrimina (0)" {
        (Firma $script:res 'InvalidCastException').exception | Should -Be "System.InvalidCastException"
    }

    It "no colapsa dos columnas distintas del mismo ORA en una firma" {
        (Firma $script:res 'ULUFCOD').hash | Should -Not -Be (Firma $script:res 'UFUSRMODIF').hash
    }

    It "toma el frame propio EMBEBIDO en la línea del mensaje, no solo el anclado a inicio" {
        # El frame más profundo va detrás del texto del mensaje; el que abre línea es el de
        # arriba en el stack. Anclando a ^ se pierde la capa que identifica el fallo.
        (Firma $script:res 'ULUFCOD').origin | Should -Be "Comun.cConexionOracle.EjecutarQuery"
    }

    It "captura la pantalla .aspx.cs más cercana del stack" {
        (Firma $script:res 'ULUFCOD').pantalla     | Should -Be "FrmDetalleClie"
        (Firma $script:res 'ORA-00001').pantalla   | Should -Be "FrmGestionUsuarios"
        (Firma $script:res 'clientSecret').pantalla | Should -BeNullOrEmpty
    }

    It "el mensaje empieza en la descripción, sin arrastrar la cabecera" {
        (Firma $script:res 'ULUFCOD').message | Should -BeLike "ORA-12899:*"
    }

    It "conserva los acentos del log" {
        (Firma $script:res 'ULUFCOD').message | Should -BeLike "*máximo*"
        (Get-TextoSalida $script:res) | Should -Not -Match ([char]0xFFFD)
    }
}

Describe "parse-weblog.ps1 — PII en el formato rs-cerrores" {

    BeforeAll { $script:res = Invoke-Weblog $script:fixture }

    It "redacta los literales SQL, donde viaja el dato que no tiene forma reconocible" {
        $texto = Get-TextoSalida $script:res
        $texto | Should -Match "'<val>'"
        $texto | Should -Not -Match "correo\.ejemplo"
        $texto | Should -Not -Match "L0001"
    }

    It "redacta el DNI aunque vaya fuera de comillas" {
        (Firma $script:res 'NullReferenceException').message | Should -Match '\[PII\]'
    }
}

Describe "parse-weblog.ps1 — filtros" {

    It "-Niveles sigue filtrando: la etiqueta de cabecera da el nivel" {
        $res = Invoke-Weblog $script:fixture @{ Niveles = "WARN" }
        $res.total_events | Should -Be 1
        $res.signatures[0].exception | Should -Be "COD300"
    }

    It "-Desde descarta los eventos anteriores a la fecha" {
        # 8 de las 12 cabeceras de nivel error son de agosto.
        $res = Invoke-Weblog $script:fixture @{ Desde = "2026-08-01" }
        $res.total_events | Should -Be 8
    }

    It "las líneas de un evento descartado no abren un evento nuevo" {
        # El stack del evento filtrado lleva "...Exception": sin cortarlo, el camino del volcado
        # plano lo readmite y el recuento devuelve justo lo que se acababa de filtrar.
        $res = Invoke-Weblog $script:fixture @{ Desde = "2026-08-01" }
        @($res.signatures | Where-Object { $_.first_seen -eq "" }).Count | Should -Be 0
    }
}

Describe "parse-weblog.ps1 — codificación del log" {

    It "lee un log en la codepage ANSI sin convertir los acentos en U+FFFD" {
        # Los logs de una web .NET en Windows salen en ANSI. Leerlos como UTF-8 no solo afea el
        # texto que acaba en el ticket: "Descripción error:" deja de casar y el mensaje sale con
        # la cabecera entera pegada delante, sin que nada lo delate.
        try { [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance) } catch { }
        $enc = $null
        try { $enc = [Text.Encoding]::GetEncoding(1252) } catch { }
        if (-not $enc) { Set-ItResult -Skipped -Because "esta máquina no tiene la codepage 1252"; return }

        $ruta = Join-Path $TestDrive "ansi.log"
        $linea = 'Error: (11/08/2026 13:45) - Codigo error: 5 Codigo error sql: 0 Descripción error: Cálculo inválido en la línea 3' + "`r`n"
        [IO.File]::WriteAllBytes($ruta, $enc.GetBytes($linea))

        $res = Invoke-Weblog $ruta
        $res.total_events        | Should -Be 1
        $res.signatures[0].message | Should -Be "Cálculo inválido en la línea 3"
    }
}

Describe "parse-weblog.ps1 — formatos que ya funcionaban (no regresión)" {

    It "un log NLog/log4net sigue detectándose como tal" {
        $ruta = Join-Path $TestDrive "nlog.log"
        @(
            '2026-08-11 13:45:02.123 ERROR Fallo al guardar el cliente'
            '   at RSFac.Cartera.Guardar(Int32 id)'
            '2026-08-11 13:46:10.001 INFO  Proceso terminado'
            '2026-08-11 13:47:44.900 ERROR Fallo al guardar el cliente'
            '   at RSFac.Cartera.Guardar(Int32 id)'
        ) | Set-Content -LiteralPath $ruta -Encoding UTF8

        $res = Invoke-Weblog $ruta
        $res.format_detected     | Should -Be "nlog-log4net"
        $res.total_events        | Should -Be 2
        $res.distinct_signatures | Should -Be 1
        $res.signatures[0].origin | Should -Be "RSFac.Cartera.Guardar"
    }

    It "admite el timestamp entre paréntesis y sin segundos" {
        $ruta = Join-Path $TestDrive "sinsegundos.log"
        @(
            '(2026-08-11 13:45) ERROR NullReferenceException al pintar el grid'
            '   at RSFac.Cartera.Pintar()'
        ) | Set-Content -LiteralPath $ruta -Encoding UTF8

        $res = Invoke-Weblog $ruta
        $res.format_detected | Should -Be "nlog-log4net"
        $res.total_events    | Should -Be 1
        $res.signatures[0].first_seen | Should -Be "2026-08-11 13:45"
    }

    It "un volcado de stack plano sigue abriendo evento por la excepción" {
        $ruta = Join-Path $TestDrive "plano.log"
        @(
            'System.InvalidOperationException: La colección se modificó'
            '   at RSFac.Agenda.Recorrer()'
        ) | Set-Content -LiteralPath $ruta -Encoding UTF8

        $res = Invoke-Weblog $ruta
        $res.format_detected | Should -Be "stacktrace-plano"
        $res.total_events    | Should -Be 1
    }

    It "sin errores reconocidos devuelve el agregado vacío, no un falso positivo" {
        $ruta = Join-Path $TestDrive "vacio.log"
        @('nada que ver aquí', 'otra línea') | Set-Content -LiteralPath $ruta -Encoding UTF8

        $res = Invoke-Weblog $ruta
        $res.success         | Should -BeTrue
        $res.total_events    | Should -Be 0
        $res.format_detected | Should -Be "desconocido"
    }
}
