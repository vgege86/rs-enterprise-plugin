<#
.SYNOPSIS
    Instalador — genera los scripts SQL de instalación limpia en <destino>\Scripts:
      - <proyecto>-CreacionTablas.sql   (DDL de todas las tablas + índices, SIN schema)
      - <proyecto>-01-Secuencias.sql    (secuencias)
      - <proyecto>-02-Vistas.sql        (vistas)
      - <proyecto>-03-Funciones.sql     (funciones)
      - <proyecto>-04-Procedimientos.sql(procedimientos / packages)
      - <proyecto>-05-Triggers.sql      (triggers)
      - <proyecto>-06-Sinonimos.sql     (sinónimos)
      - <proyecto>-CreacionObjetos.sql  (maestro, en orden de dependencias)
      - Inserts\<TABLA>.sql             (un fichero por tabla paramétrica)

    Delega en los scripts Python del plugin:
      scripts\installer-ddl.py      (tablas + índices desde el model.json)
      scripts\installer-objects.py  (secuencias/vistas/funciones/procs/triggers/sinónimos
                                     desde la BD viva — no están en el model.json)
      scripts\installer-inserts.py  (inserts por tabla paramétrica, vista "Parametricas")

.PARAMETER workspace  Ruta trunk del proyecto
.PARAMETER destino    Carpeta Instalador
#>
param(
    [Parameter(Mandatory=$true)][string]$workspace,
    [Parameter(Mandatory=$true)][string]$destino
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$proyecto = if ((Split-Path $workspace -Leaf) -eq 'trunk') { Split-Path (Split-Path $workspace -Parent) -Leaf } else { Split-Path $workspace -Leaf }
$scriptsDir = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts"

$outScripts = Join-Path $destino "Scripts"
$insertsDir = Join-Path $outScripts "Inserts"
$ddlOut     = Join-Path $outScripts "$proyecto-CreacionTablas.sql"
New-Item -ItemType Directory -Path $insertsDir -Force | Out-Null

$avisos = $false

# --- DDL tablas + índices (sin schema) ---
Write-Host "== DDL creación de tablas e índices (sin schema) =="
python "$scriptsDir\installer-ddl.py" "$workspace" "$proyecto" "$ddlOut"
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: installer-ddl.py falló (exit $LASTEXITCODE)"; exit 1 }
if (!(Test-Path $ddlOut)) { Write-Host "ERROR: no se generó $ddlOut"; exit 1 }

# --- Resto de objetos desde la BD viva ---
Write-Host "`n== Objetos BD: secuencias, vistas, funciones, procedimientos, triggers, sinónimos =="
python "$scriptsDir\installer-objects.py" "$workspace" "$proyecto" "$outScripts"
$objCode = $LASTEXITCODE
if ($objCode -eq 1) { Write-Host "ERROR: installer-objects.py falló (exit 1)"; exit 1 }
if ($objCode -eq 2) { Write-Host "AVISO: algún tipo de objeto dio error (exit 2) — revisar log arriba."; $avisos = $true }

$maestro = Join-Path $outScripts "$proyecto-CreacionObjetos.sql"
if (!(Test-Path $maestro)) { Write-Host "ERROR: no se generó el maestro $maestro"; exit 1 }

# --- Inserts paramétricos (uno por tabla) ---
Write-Host "`n== Inserts tablas paramétricas =="
python "$scriptsDir\installer-inserts.py" "$workspace" "$proyecto" "$insertsDir"
$insCode = $LASTEXITCODE
if ($insCode -eq 1) { Write-Host "ERROR: installer-inserts.py falló (exit 1)"; exit 1 }
if ($insCode -eq 2) { Write-Host "AVISO: algunas tablas paramétricas dieron error (exit 2) — revisar log arriba."; $avisos = $true }

$nIns = (Get-ChildItem $insertsDir -Filter *.sql -File -ErrorAction SilentlyContinue).Count
Write-Host "`nOK — Scripts en $outScripts"
Write-Host "   Tablas/índices: $ddlOut"
Write-Host "   Maestro objetos: $maestro"
foreach ($f in (Get-ChildItem $outScripts -Filter "$proyecto-0*.sql" -File | Sort-Object Name)) {
    Write-Host ("   {0} ({1:N0} bytes)" -f $f.Name, $f.Length)
}
Write-Host "   Inserts: $nIns ficheros en $insertsDir"
if ($avisos) { exit 2 }
