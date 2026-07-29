<#
.SYNOPSIS
    Ejecuta, en orden alfabetico y con parada al primer error, los scripts SQL que acompanan
    a este paquete (carpeta Scripts\ en instalacion limpia, scripts\ en un actualizador).

    Es el segundo paso de la instalacion: Instalar.ps1 copia ficheros y NO toca la BD;
    este script es el unico que escribe en la base de datos.

.DESCRIPTION
    Datos de conexion: rutas.json -> entornos.<ENTORNO>.bd (motor, conexion, usuario).
    La contrasena NUNCA esta en el JSON: se pide por consola o se pasa con -Password.

    Motor ORACLE    -> sqlplus, con WHENEVER SQLERROR EXIT FAILURE (para al primer error)
    Motor SQLSERVER -> sqlcmd -b (para al primer error)

    Todo el output se guarda en <carpeta>\_ejecucion_<timestamp>.log.

.PARAMETER Entorno
    DESA | TEST | PROD. Debe existir en rutas.json.

.PARAMETER Carpeta
    Carpeta con los .sql. Default: Scripts\ o scripts\ junto a este script.

.PARAMETER RutasJson
    Ruta del rutas.json. Default: el que acompana a este script.

.PARAMETER Password
    Contrasena del usuario de BD. Si se omite, se pide por consola (recomendado).

.PARAMETER Simular
    Lista los scripts en el orden en que se ejecutarian, sin conectar a la BD.

.EXAMPLE
    .\Ejecutar-Scripts.ps1 -Entorno TEST
    .\Ejecutar-Scripts.ps1 -Entorno PROD -Simular
#>
param(
    [Parameter(Mandatory=$true)][ValidateSet('DESA','TEST','PROD')][string]$Entorno,
    [string]$Carpeta = "",
    [string]$RutasJson = "",
    [string]$Password = "",
    [switch]$Simular
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$paquete = $PSScriptRoot
if (-not $RutasJson) { $RutasJson = Join-Path $paquete "rutas.json" }
if (!(Test-Path $RutasJson)) { Write-Host "ERROR: no se encuentra rutas.json: $RutasJson"; exit 1 }

if (-not $Carpeta) {
    foreach ($c in @("Scripts", "scripts")) {
        $p = Join-Path $paquete $c
        if (Test-Path $p) { $Carpeta = $p; break }
    }
}
if (-not $Carpeta -or !(Test-Path $Carpeta)) { Write-Host "ERROR: no se encuentra la carpeta de scripts."; exit 1 }

$scripts = @(Get-ChildItem $Carpeta -Filter *.sql -File | Sort-Object Name)
if ($scripts.Count -eq 0) { Write-Host "AVISO: no hay ficheros .sql en $Carpeta — nada que ejecutar."; exit 0 }

Write-Host "== Scripts SQL — entorno $Entorno =="
Write-Host "Carpeta: $Carpeta"
$i = 0
$scripts | ForEach-Object { $i++; Write-Host ("  {0,2}. {1}" -f $i, $_.Name) }

if ($Simular) { Write-Host "`n(-Simular: no se conecta a la BD)"; exit 0 }

$cfg = Get-Content $RutasJson -Raw -Encoding UTF8 | ConvertFrom-Json
$ent = $cfg.entornos.$Entorno
if (-not $ent -or -not $ent.bd) { Write-Host "ERROR: entorno '$Entorno' sin bloque 'bd' en rutas.json"; exit 1 }

$motor    = ("$($ent.bd.motor)").ToUpper()
$conexion = $ent.bd.conexion
$usuario  = $ent.bd.usuario
if (-not $conexion -or -not $usuario) { Write-Host "ERROR: 'conexion' o 'usuario' vacios para $Entorno en rutas.json"; exit 1 }

if (-not $Password) {
    $sec = Read-Host "Password de $usuario@$conexion ($motor)" -AsSecureString
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$log   = Join-Path $Carpeta "_ejecucion_$stamp.log"
"== Ejecucion $stamp — entorno $Entorno — $motor $usuario@$conexion ==" | Out-File $log -Encoding UTF8

Write-Host "`nConfirma antes de escribir en la BD de $Entorno."
$resp = Read-Host "Ejecutar los $($scripts.Count) scripts sobre $usuario@$conexion? (S/N)"
if ($resp -notmatch '^[SsYy]') { Write-Host "Cancelado por el usuario."; exit 0 }

$ok = 0
foreach ($s in $scripts) {
    Write-Host "`n--- $($s.Name) ---"
    "`n--- $($s.Name) ---" | Out-File $log -Append -Encoding UTF8

    if ($motor -eq 'ORACLE') {
        # Wrapper: sin WHENEVER SQLERROR, sqlplus devuelve 0 aunque el script falle.
        $wrap = [System.IO.Path]::GetTempFileName() + ".sql"
        @(
            "WHENEVER SQLERROR EXIT FAILURE",
            "WHENEVER OSERROR EXIT FAILURE",
            "SET DEFINE OFF",
            "@`"$($s.FullName)`"",
            "EXIT SUCCESS"
        ) | Set-Content $wrap -Encoding UTF8
        $out = & sqlplus -L -S "$usuario/$Password@$conexion" "@$wrap" 2>&1
        $code = $LASTEXITCODE
        Remove-Item $wrap -Force -ErrorAction SilentlyContinue
    }
    elseif ($motor -eq 'SQLSERVER') {
        $out = & sqlcmd -S $conexion -U $usuario -P $Password -b -i "$($s.FullName)" 2>&1
        $code = $LASTEXITCODE
    }
    else {
        Write-Host "ERROR: motor no soportado: '$motor' (usa ORACLE o SQLSERVER)"; exit 1
    }

    $out | ForEach-Object { Write-Host "  $_" }
    $out | Out-File $log -Append -Encoding UTF8

    if ($code -ne 0) {
        Write-Host "`nERROR: $($s.Name) fallo (exit $code). Se detiene la ejecucion."
        Write-Host "Scripts ejecutados correctamente antes del fallo: $ok de $($scripts.Count)."
        Write-Host "Log: $log"
        exit $code
    }
    $ok++
    Write-Host "OK — $($s.Name)"
}

Write-Host "`n== $ok/$($scripts.Count) scripts ejecutados correctamente =="
Write-Host "Log: $log"
