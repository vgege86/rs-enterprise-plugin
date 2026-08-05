<#
    Tests Pester de hooks/render-word.ps1: los párrafos del .docx generado tienen que salir con los
    ESTILOS de la plantilla, no como Normal con formato manual.

    ⛔ El hook necesita Microsoft Word por COM: en Linux/CI o sin Word instalado el bloque entero se
    SALTA (-Skip), no falla.

    ⛔ La plantilla corporativa no se versiona en el plugin (es material de marca) y no puede vivir
    en el repo ni referenciarse por una ruta absoluta de la máquina del desarrollador. El test se
    FABRICA su propia plantilla .dotx con Word en el directorio temporal: portada (Título/Subtítulo),
    tabla de historial con filas de relleno, campo TOC y los dos estilos de párrafo de tabla que la
    plantilla real trae. Así el test es autocontenido y comprueba lo mismo.

    Los estilos esperados se leen del propio documento por ID built-in (-2 Título 1, -49 Lista con
    viñetas, -50 Lista con números, -102 HTML con formato previo...), nunca por nombre literal en
    español: el hook debe funcionar con Word en cualquier idioma y el test también.

    Ejecutar: Invoke-Pester tests/RenderWord.Tests.ps1
#>

function Test-RsWordDisponible {
    if (-not $IsWindows) { return $false }
    try {
        $w = New-Object -ComObject Word.Application
        $w.Quit()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($w) | Out-Null
        return $true
    } catch { return $false }
}
$hayWord = Test-RsWordDisponible

Describe "render-word: un solo origen con -Title" -Skip:(-not $hayWord) {

    BeforeAll {
        $script:hook = Join-Path $PSScriptRoot ".." "hooks" "render-word.ps1"
        $script:tmp  = Join-Path ([IO.Path]::GetTempPath()) ("rsword-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tmp | Out-Null

        # ---- plantilla sintetica -------------------------------------------------
        $script:tpl = Join-Path $script:tmp "plantilla.dotx"
        $w = New-Object -ComObject Word.Application
        $w.Visible = $false
        $w.DisplayAlerts = 0
        $d = $w.Documents.Add()
        $sh = $d.Styles.Add("Encabezado de la tabla", 1)   # wdStyleTypeParagraph
        $sh.Font.Bold = $true
        $d.Styles.Add("Texto de la tabla", 1) | Out-Null
        $sel = $w.Selection
        $sel.Style = $d.Styles.Item(-63)                   # wdStyleTitle
        $sel.TypeText("TITULO DEL DOCUMENTO"); $sel.TypeParagraph()
        $sel.Style = $d.Styles.Item(-75)                   # wdStyleSubtitle
        $sel.TypeText("OBJETO DEL DOCUMENTO"); $sel.TypeParagraph()
        $sel.Style = $d.Styles.Item(-1)
        $sel.TypeParagraph()
        $ht = $d.Tables.Add($sel.Range, 7, 4)              # historial con 5 filas de relleno
        $ht.Cell(1, 1).Range.Text = "VERSION"
        $ht.Cell(1, 2).Range.Text = "FECHA"
        $ht.Cell(1, 3).Range.Text = "AUTOR"
        $ht.Cell(1, 4).Range.Text = "CAMBIOS"
        $sel.EndKey(6) | Out-Null
        $sel.TypeParagraph()
        $d.TablesOfContents.Add($sel.Range) | Out-Null
        $sel.EndKey(6) | Out-Null
        $sel.TypeParagraph()
        $ruta = [string]$script:tpl                        # [ref] no admite variable de ambito script
        $fmt  = 14                                         # wdFormatXMLTemplate (.dotx)
        $d.SaveAs([ref]$ruta, [ref]$fmt)
        $d.Close(0)
        $w.Quit()

        # ---- fichero Markdown de prueba ------------------------------------------
        $script:md = Join-Path $script:tmp "fuente.md"
        $texto = @'
# Titulo del fichero

Parrafo introductorio.

## Seccion primera

### Subseccion

- vineta nivel uno
- otra vineta
  - vineta anidada

## Seccion segunda

1. primero de la primera lista
2. segundo de la primera lista

Parrafo que separa las dos listas.

1. primero de la segunda lista
2. segundo de la segunda lista

```
codigo linea uno
codigo linea dos
```

| Cabecera A | Cabecera B |
|---|---|
| celda uno | celda dos |
'@
        [IO.File]::WriteAllText($script:md, $texto, [Text.UTF8Encoding]::new($false))

        # ---- render --------------------------------------------------------------
        $script:out = Join-Path $script:tmp "salida.docx"
        & $script:hook -Workspace $script:tmp -Sources $script:md -Template $script:tpl `
                       -Output $script:out -Title "Titulo de portada" -Objeto "Objeto" `
                       -Autor "RS" -Version "1.0" | Out-Null

        # ---- lectura del resultado (se cierra Word antes de aseverar) -------------
        $script:paras = @()
        $script:info  = @{}
        $w2 = New-Object -ComObject Word.Application
        $w2.Visible = $false
        $w2.DisplayAlerts = 0
        $d2 = $w2.Documents.Open($script:out, $false, $true)
        $script:est = @{
            h1   = $d2.Styles.Item(-2).NameLocal
            h2   = $d2.Styles.Item(-3).NameLocal
            bul1 = $d2.Styles.Item(-49).NameLocal
            bul2 = $d2.Styles.Item(-55).NameLocal
            num1 = $d2.Styles.Item(-50).NameLocal
            pre  = $d2.Styles.Item(-102).NameLocal
            nor  = $d2.Styles.Item(-1).NameLocal
        }
        foreach ($p in $d2.Paragraphs) {
            $t = ($p.Range.Text -replace "[\r\n\x07]", "").Trim()
            if ($t.Length -eq 0) { continue }
            $ls = ""
            try { $ls = $p.Range.ListFormat.ListString } catch { }
            $script:paras += [pscustomobject]@{ Texto = $t; Estilo = $p.Style.NameLocal; Lista = $ls }
        }
        $script:info.tablas    = $d2.Tables.Count
        $script:info.histFilas = $d2.Tables.Item(1).Rows.Count
        $script:info.cabTabla  = $d2.Tables.Item(2).Cell(1, 1).Range.Paragraphs.Item(1).Style.NameLocal
        $script:info.cuerpo    = $d2.Tables.Item(2).Cell(2, 1).Range.Paragraphs.Item(1).Style.NameLocal
        $d2.Close(0)
        $w2.Quit()
    }

    AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

    It "no duplica el título: el '#' del fichero no se vuelca al cuerpo" {
        @($script:paras | Where-Object { $_.Texto -eq "Titulo del fichero" }).Count | Should -Be 0
    }

    It "la portada lleva el -Title una sola vez" {
        @($script:paras | Where-Object { $_.Texto -eq "Titulo de portada" }).Count | Should -Be 1
    }

    It "los niveles suben uno: '##' es Título 1 y '###' Título 2" {
        ($script:paras | Where-Object { $_.Texto -eq "Seccion primera" }).Estilo | Should -Be $script:est.h1
        ($script:paras | Where-Object { $_.Texto -eq "Seccion segunda" }).Estilo | Should -Be $script:est.h1
        ($script:paras | Where-Object { $_.Texto -eq "Subseccion" }).Estilo      | Should -Be $script:est.h2
    }

    It "las viñetas usan el estilo de lista y no un carácter literal" {
        $v = $script:paras | Where-Object { $_.Texto -eq "vineta nivel uno" }
        $v.Estilo | Should -Be $script:est.bul1
        ($script:paras | Where-Object { $_.Texto -like "*vineta*" -or $_.Texto -like "*$([char]0x2022)*" } |
            Where-Object { $_.Texto -match [regex]::Escape([string][char]0x2022) }).Count | Should -Be 0
    }

    It "las viñetas anidadas usan la variante de segundo nivel" {
        ($script:paras | Where-Object { $_.Texto -eq "vineta anidada" }).Estilo | Should -Be $script:est.bul2
    }

    It "las listas numeradas usan el estilo y no llevan el número literal" {
        $n = $script:paras | Where-Object { $_.Texto -eq "primero de la primera lista" }
        $n.Estilo | Should -Be $script:est.num1
        @($script:paras | Where-Object { $_.Texto -match '^\d+\.\s' }).Count | Should -Be 0
    }

    It "dos listas numeradas independientes no encadenan la numeración" {
        ($script:paras | Where-Object { $_.Texto -eq "primero de la primera lista" }).Lista | Should -Be "1."
        ($script:paras | Where-Object { $_.Texto -eq "segundo de la primera lista" }).Lista | Should -Be "2."
        ($script:paras | Where-Object { $_.Texto -eq "primero de la segunda lista" }).Lista | Should -Be "1."
        ($script:paras | Where-Object { $_.Texto -eq "segundo de la segunda lista" }).Lista | Should -Be "2."
    }

    It "el bloque fenced usa el estilo preformateado" {
        ($script:paras | Where-Object { $_.Texto -eq "codigo linea uno" }).Estilo | Should -Be $script:est.pre
        ($script:paras | Where-Object { $_.Texto -eq "codigo linea dos" }).Estilo | Should -Be $script:est.pre
    }

    It "la tabla generada usa los estilos de tabla de la plantilla" {
        $script:info.tablas   | Should -Be 2
        $script:info.cabTabla | Should -Be "Encabezado de la tabla"
        $script:info.cuerpo   | Should -Be "Texto de la tabla"
    }

    It "el historial se queda solo con las filas usadas" {
        $script:info.histFilas | Should -Be 2
    }
}

Describe "render-word: varios orígenes y plantilla sin estilos de tabla" -Skip:(-not $hayWord) {

    BeforeAll {
        $script:hook = Join-Path $PSScriptRoot ".." "hooks" "render-word.ps1"
        $script:tmp2 = Join-Path ([IO.Path]::GetTempPath()) ("rsword2-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tmp2 | Out-Null

        # plantilla minima: portada y nada mas (sin estilos propios de tabla)
        $script:tpl2 = Join-Path $script:tmp2 "minima.dotx"
        $w = New-Object -ComObject Word.Application
        $w.Visible = $false
        $w.DisplayAlerts = 0
        $d = $w.Documents.Add()
        $sel = $w.Selection
        $sel.Style = $d.Styles.Item(-63)
        $sel.TypeText("TITULO DEL DOCUMENTO"); $sel.TypeParagraph()
        $sel.Style = $d.Styles.Item(-1)
        $sel.TypeParagraph()
        $ruta2 = [string]$script:tpl2
        $fmt2  = 14
        $d.SaveAs([ref]$ruta2, [ref]$fmt2)
        $d.Close(0)
        $w.Quit()

        $a = Join-Path $script:tmp2 "a.md"
        $b = Join-Path $script:tmp2 "b.md"
        [IO.File]::WriteAllText($a, "# Capitulo A`r`n`r`n## Punto A1`r`n`r`ntexto a`r`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($b, "# Capitulo B`r`n`r`n| C1 | C2 |`r`n|---|---|`r`n| v1 | v2 |`r`n", [Text.UTF8Encoding]::new($false))

        $script:out2 = Join-Path $script:tmp2 "salida.docx"
        & $script:hook -Workspace $script:tmp2 -Sources "$a;$b" -Template $script:tpl2 `
                       -Output $script:out2 -Title "Portada multiple" | Out-Null

        $script:paras2 = @()
        $w2 = New-Object -ComObject Word.Application
        $w2.Visible = $false
        $w2.DisplayAlerts = 0
        $d2 = $w2.Documents.Open($script:out2, $false, $true)
        $script:est2 = @{
            h1  = $d2.Styles.Item(-2).NameLocal
            h2  = $d2.Styles.Item(-3).NameLocal
            nor = $d2.Styles.Item(-1).NameLocal
        }
        foreach ($p in $d2.Paragraphs) {
            $t = ($p.Range.Text -replace "[\r\n\x07]", "").Trim()
            if ($t.Length -eq 0) { continue }
            $script:paras2 += [pscustomobject]@{ Texto = $t; Estilo = $p.Style.NameLocal }
        }
        $script:cab2 = $d2.Tables.Item(1).Cell(1, 1).Range.Paragraphs.Item(1).Style.NameLocal
        $d2.Close(0)
        $w2.Quit()
    }

    AfterAll { Remove-Item -Recurse -Force $script:tmp2 -ErrorAction SilentlyContinue }

    It "con varios orígenes cada '#' sigue siendo un capítulo en Título 1" {
        ($script:paras2 | Where-Object { $_.Texto -eq "Capitulo A" }).Estilo | Should -Be $script:est2.h1
        ($script:paras2 | Where-Object { $_.Texto -eq "Capitulo B" }).Estilo | Should -Be $script:est2.h1
        ($script:paras2 | Where-Object { $_.Texto -eq "Punto A1" }).Estilo   | Should -Be $script:est2.h2
    }

    It "sin estilos de tabla en la plantilla la tabla cae a Normal sin romper" {
        $script:cab2 | Should -Be $script:est2.nor
    }
}
