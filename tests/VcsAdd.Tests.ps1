<#
    Tests Pester de svn-add.ps1, git-add.ps1 y vcs-revert.ps1 con repositorios REALES en TestDrive.

    POR QUE EXISTE. En una instalacion de cliente, svn_add recibio el parametro mal escrito, le
    llego la lista vacia y anadio todo lo no versionado del working copy: 57 elementos que se
    expandieron a 1925 ficheros (binarios, logs, configuracion y trabajo de otros
    desarrolladores), con success:true. Lo que se fija aqui (3.31.0):
      - lista vacia, '.', la raiz, fuera del workspace o comodines -> error, sin tocar nada;
      - se anade solo lo pedido, y added cuenta lo que quedo REALMENTE programado;
      - una carpeta que arrastra mas de -MaxFiles no anade nada;
      - lo ya versionado no se recorre (antes, svn add --force lo hacia);
      - vcs-revert no acepta carpetas (en Git revertiria el arbol entero).

    ⛔ Las condiciones de -Skip van escritas en cada It: Pester 5 las evalua al descubrir los
    tests, antes de BeforeAll.

    Ejecutar: Invoke-Pester tests/VcsAdd.Tests.ps1
#>

BeforeAll {
    $script:svnAdd = Join-Path $PSScriptRoot "../hooks/svn-add.ps1"
    $script:gitAdd = Join-Path $PSScriptRoot "../hooks/git-add.ps1"
    $script:revert = Join-Path $PSScriptRoot "../hooks/vcs-revert.ps1"

    function Invoke-RsHook {
        <#
        .SYNOPSIS
            Ejecuta un hook y devuelve su JSON y su codigo de salida.
        .PARAMETER Script
            Ruta del hook.
        .PARAMETER Parametros
            Parametros con nombre del hook.
        .OUTPUTS
            @{ json; code }
        #>
        param([string]$Script, [hashtable]$Parametros)
        $salida = & $Script @Parametros
        $code = $LASTEXITCODE
        return @{ json = (($salida -join "`n") | ConvertFrom-Json); code = $code }
    }

    function New-RsFicheros {
        <#
        .SYNOPSIS
            Crea N ficheros de texto en una carpeta (la crea si no existe).
        .PARAMETER Carpeta
            Ruta de la carpeta.
        .PARAMETER Numero
            Cuantos ficheros crear.
        #>
        param([string]$Carpeta, [int]$Numero)
        New-Item -ItemType Directory -Path $Carpeta -Force | Out-Null
        1..$Numero | ForEach-Object { Set-Content -LiteralPath (Join-Path $Carpeta "f$_.cs") -Value "$_" }
    }

    function New-RsSvnWc {
        <#
        .SYNOPSIS
            Repositorio SVN local con un working copy y una carpeta Ver/ versionada con a.cs.
        .OUTPUTS
            Ruta del working copy.
        #>
        $base = Join-Path $TestDrive ("svn_" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $base -Force | Out-Null
        $repo = Join-Path $base "repo"
        $wc   = Join-Path $base "wc"
        & svnadmin create $repo
        $url = "file:///" + ($repo -replace '\\', '/').TrimStart('/')
        & svn checkout -q $url $wc
        New-RsFicheros (Join-Path $wc "Ver") 1
        & svn add -q (Join-Path $wc "Ver")
        & svn commit -q -m init $wc
        return $wc
    }

    function Get-RsSvnA {
        <#
        .SYNOPSIS
            Cuantos elementos hay en estado A en el working copy.
        .PARAMETER Wc
            Ruta del working copy.
        #>
        param([string]$Wc)
        return @(& svn status -q $Wc | Where-Object { "$_".StartsWith("A") }).Count
    }

    function New-RsGitRepo {
        <#
        .SYNOPSIS
            Repositorio Git con a.cs y Ver/f1.cs commiteados y un .gitignore de *.log.
        .OUTPUTS
            Ruta del repositorio.
        #>
        $repo = Join-Path $TestDrive ("git_" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        & git -C $repo init -q
        & git -C $repo config user.email "t@t"
        & git -C $repo config user.name "t"
        Set-Content -LiteralPath (Join-Path $repo "a.cs") -Value "original"
        Set-Content -LiteralPath (Join-Path $repo ".gitignore") -Value "*.log"
        New-RsFicheros (Join-Path $repo "Ver") 2
        & git -C $repo add -A
        & git -C $repo commit -q -m init
        return $repo
    }

    function Get-RsGitNuevos {
        <#
        .SYNOPSIS
            Ficheros nuevos en el indice.
        .PARAMETER Repo
            Ruta del repositorio.
        #>
        param([string]$Repo)
        return @(& git -C $Repo diff --cached --name-only --diff-filter=A | Where-Object { $_ })
    }
}

Describe "svn-add.ps1" {

    It "lista vacia: error y no anade nada" -Skip:(-not (Get-Command svn -ErrorAction SilentlyContinue)) {
        $wc = New-RsSvnWc
        New-RsFicheros (Join-Path $wc "Suelto") 3
        $r = Invoke-RsHook $script:svnAdd @{ Workspace = $wc; Files = "" }
        $r.code         | Should -Be 1
        $r.json.success | Should -Be $false
        Get-RsSvnA $wc  | Should -Be 0
    }

    It "'<ruta>' se rechaza sin tocar nada" -Skip:(-not (Get-Command svn -ErrorAction SilentlyContinue)) -ForEach @(
        @{ ruta = "." }, @{ ruta = "Ver/.." }, @{ ruta = "../fuera.cs" }, @{ ruta = "*.cs" }
    ) {
        $wc = New-RsSvnWc
        New-RsFicheros (Join-Path $wc "Suelto") 3
        $r = Invoke-RsHook $script:svnAdd @{ Workspace = $wc; Files = $ruta }
        $r.json.success | Should -Be $false
        @($r.json.rejected).Count | Should -BeGreaterThan 0
        Get-RsSvnA $wc  | Should -Be 0
    }

    It "la raiz del workspace en ruta absoluta se rechaza" -Skip:(-not (Get-Command svn -ErrorAction SilentlyContinue)) {
        $wc = New-RsSvnWc
        $r = Invoke-RsHook $script:svnAdd @{ Workspace = $wc; Files = $wc }
        $r.json.success | Should -Be $false
        Get-RsSvnA $wc  | Should -Be 0
    }

    It "un fichero en carpeta nueva: anade el fichero y sus carpetas padre, no a sus vecinos" -Skip:(-not (Get-Command svn -ErrorAction SilentlyContinue)) {
        $wc = New-RsSvnWc
        New-RsFicheros (Join-Path $wc "Nueva/Sub") 1
        New-RsFicheros (Join-Path $wc "Nueva") 2
        $r = Invoke-RsHook $script:svnAdd @{ Workspace = $wc; Files = "Nueva/Sub/f1.cs" }
        $r.code             | Should -Be 0
        $r.json.success     | Should -Be $true
        $r.json.added_count | Should -Be 3
        $r.json.warning     | Should -Not -BeNullOrEmpty
        Get-RsSvnA $wc      | Should -Be 3
        (@($r.json.added) -join "|") | Should -Not -Match "Nueva[\\/]f2\.cs"
    }

    It "una carpeta por encima de MaxFiles no anade nada y da el desglose" -Skip:(-not (Get-Command svn -ErrorAction SilentlyContinue)) {
        $wc = New-RsSvnWc
        New-RsFicheros (Join-Path $wc "Grande") 60
        $r = Invoke-RsHook $script:svnAdd @{ Workspace = $wc; Files = "Grande" }
        $r.code                  | Should -Be 1
        $r.json.success          | Should -Be $false
        $r.json.expanded[0].files | Should -Be 60
        Get-RsSvnA $wc           | Should -Be 0
    }

    It "con MaxFiles suficiente la carpeta entra y added cuenta todo lo programado" -Skip:(-not (Get-Command svn -ErrorAction SilentlyContinue)) {
        $wc = New-RsSvnWc
        New-RsFicheros (Join-Path $wc "Grande") 60
        $r = Invoke-RsHook $script:svnAdd @{ Workspace = $wc; Files = "Grande"; MaxFiles = 100 }
        $r.json.success     | Should -Be $true
        $r.json.added_count | Should -Be 61
        Get-RsSvnA $wc      | Should -Be 61
    }

    It "una carpeta ya versionada se omite y NO se recorre (antes --force la recorria)" -Skip:(-not (Get-Command svn -ErrorAction SilentlyContinue)) {
        $wc = New-RsSvnWc
        Set-Content -LiteralPath (Join-Path $wc "Ver/nuevo.cs") -Value "x"
        $r = Invoke-RsHook $script:svnAdd @{ Workspace = $wc; Files = "Ver" }
        $r.json.added_count        | Should -Be 0
        @($r.json.skipped).Count   | Should -Be 1
        Get-RsSvnA $wc             | Should -Be 0
    }

    It "acepta ';' y ',' como separador" -Skip:(-not (Get-Command svn -ErrorAction SilentlyContinue)) {
        $wc = New-RsSvnWc
        New-RsFicheros (Join-Path $wc "Ver") 3
        $r = Invoke-RsHook $script:svnAdd @{ Workspace = $wc; Files = "Ver/f2.cs;Ver/f3.cs" }
        $r.json.added_count | Should -Be 2
        $wc2 = New-RsSvnWc
        New-RsFicheros (Join-Path $wc2 "Ver") 3
        (Invoke-RsHook $script:svnAdd @{ Workspace = $wc2; Files = "Ver/f2.cs,Ver/f3.cs" }).json.added_count | Should -Be 2
    }
}

Describe "git-add.ps1" {

    It "lista vacia: error y no anade nada" -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $repo = New-RsGitRepo
        New-RsFicheros (Join-Path $repo "Suelto") 3
        $r = Invoke-RsHook $script:gitAdd @{ Workspace = $repo; Files = "" }
        $r.code                | Should -Be 1
        $r.json.success        | Should -Be $false
        Get-RsGitNuevos $repo  | Should -BeNullOrEmpty
    }

    It "'.' se rechaza sin tocar nada" -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $repo = New-RsGitRepo
        New-RsFicheros (Join-Path $repo "Suelto") 3
        $r = Invoke-RsHook $script:gitAdd @{ Workspace = $repo; Files = "." }
        $r.json.success       | Should -Be $false
        Get-RsGitNuevos $repo | Should -BeNullOrEmpty
    }

    It "un fichero en carpeta nueva: solo ese fichero" -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $repo = New-RsGitRepo
        New-RsFicheros (Join-Path $repo "Nueva") 3
        $r = Invoke-RsHook $script:gitAdd @{ Workspace = $repo; Files = "Nueva/f1.cs" }
        $r.json.success     | Should -Be $true
        $r.json.added_count | Should -Be 1
        @(Get-RsGitNuevos $repo) | Should -Be @("Nueva/f1.cs")
    }

    It "una carpeta por encima de MaxFiles no anade nada" -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $repo = New-RsGitRepo
        New-RsFicheros (Join-Path $repo "Grande") 60
        $r = Invoke-RsHook $script:gitAdd @{ Workspace = $repo; Files = "Grande" }
        $r.code                   | Should -Be 1
        $r.json.expanded[0].files | Should -Be 60
        Get-RsGitNuevos $repo     | Should -BeNullOrEmpty
    }

    It "lo ignorado por .gitignore no se fuerza y lo trackeado se omite" -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $repo = New-RsGitRepo
        Set-Content -LiteralPath (Join-Path $repo "traza.log") -Value "x"
        $r = Invoke-RsHook $script:gitAdd @{ Workspace = $repo; Files = "traza.log;a.cs" }
        $r.json.success          | Should -Be $false
        @($r.json.failed).Count  | Should -Be 1
        @($r.json.skipped).Count | Should -Be 1
        Get-RsGitNuevos $repo    | Should -BeNullOrEmpty
    }
}

Describe "vcs-revert.ps1" {

    It "una carpeta se rechaza y no revierte nada (en Git seria el arbol entero)" -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $repo = New-RsGitRepo
        Set-Content -LiteralPath (Join-Path $repo "Ver/f1.cs") -Value "cambio 1"
        Set-Content -LiteralPath (Join-Path $repo "Ver/f2.cs") -Value "cambio 2"
        $r = Invoke-RsHook $script:revert @{ Workspace = $repo; Files = "Ver" }
        $r.code         | Should -Be 1
        $r.json.success | Should -Be $false
        (Get-Content -LiteralPath (Join-Path $repo "Ver/f1.cs")) | Should -Be "cambio 1"
        (Get-Content -LiteralPath (Join-Path $repo "Ver/f2.cs")) | Should -Be "cambio 2"
    }

    It "'.' se rechaza y no revierte nada" -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $repo = New-RsGitRepo
        Set-Content -LiteralPath (Join-Path $repo "a.cs") -Value "cambio"
        $r = Invoke-RsHook $script:revert @{ Workspace = $repo; Files = "." }
        $r.json.success | Should -Be $false
        (Get-Content -LiteralPath (Join-Path $repo "a.cs")) | Should -Be "cambio"
    }

    It "un fichero valido se revierte, y con -DryRun no" -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $repo = New-RsGitRepo
        Set-Content -LiteralPath (Join-Path $repo "a.cs") -Value "cambio"
        $plan = Invoke-RsHook $script:revert @{ Workspace = $repo; Files = "a.cs"; DryRun = $true }
        $plan.json.planned[0].action | Should -Be "revert"
        (Get-Content -LiteralPath (Join-Path $repo "a.cs")) | Should -Be "cambio"

        $r = Invoke-RsHook $script:revert @{ Workspace = $repo; Files = "a.cs" }
        $r.json.success | Should -Be $true
        (Get-Content -LiteralPath (Join-Path $repo "a.cs")) | Should -Be "original"
    }
}
