<#
.SYNOPSIS
    Lee de la BD viva el valor DEFAULT de cada columna y lo devuelve como un mapa
    "TABLA.COLUMNA" -> expresion, para que sync-from-db.ps1 y sync-model-tables.ps1 lo
    graben en el model.json (campo `default` de la columna).

    Sin este campo en el modelo, `installer-ddl.py` no puede emitirlo: el
    <Proyecto>-CreacionTablas.sql del instalador sale con los tipos y los NOT NULL pero SIN
    los valores por defecto, y en el cliente toda columna con DEFAULT queda a NULL en el
    primer INSERT que no la nombre.

.NOTES
    POR QUE UNA PASADA APARTE, Y NO UNA COLUMNA MAS EN EL SELECT PRINCIPAL

    En Oracle `ALL_TAB_COLS.DATA_DEFAULT` es de tipo LONG. Un LONG no se puede concatenar ni
    pasar por REPLACE/TRIM/SUBSTR dentro de una sentencia SQL (ORA-00932/ORA-00997), y sacado
    tal cual por sqlplus con `SET COLSEP '|'` arrastra sus saltos de linea a la salida: la fila
    se parte en varias lineas y el troceo por '|' del hook llamante devuelve basura. En un
    bloque PL/SQL, en cambio, una variable LONG se comporta como VARCHAR2(32760) y admite
    REPLACE: los saltos se neutralizan ANTES de imprimir. De ahi el DBMS_OUTPUT con marcador,
    el mismo patron que usa scripts/installer-objects.py para ALL_VIEWS.TEXT.

    En SQL Server `COLUMN_DEFAULT` es nvarchar(4000) y no tendria ese problema, pero se extrae
    igual en su propia pasada para que el hook llamante tenga UN solo camino de mezcla y las
    consultas principales (que ya funcionan) no se toquen.

    QUE NO SE DEVUELVE
      - Columnas IDENTITY de Oracle: su DATA_DEFAULT es `"<ESQ>"."ISEQ$$_1234".nextval`, que no
        es un DEFAULT reescribible — lo crea el propio CREATE TABLE de la columna identity.
        Emitirlo produciria un DDL que apunta a una secuencia inexistente en el destino.
      - Columnas virtuales y ocultas (VIRTUAL_COLUMN / HIDDEN_COLUMN): su "default" es la
        expresion de la columna generada, no un valor por defecto.
#>

# Marcador de linea de salida. Sirve para separar las filas utiles del banner de sqlplus/sqlcmd
# y de cualquier aviso: se ignora todo lo que no empiece por el.
$script:RsDefMark = '##DEF##'

function ConvertTo-RsDefaultsMap {
    <#  Parsea la salida marcada de cualquiera de los dos motores.
        Formato por linea: ##DEF##<TABLA>|<COLUMNA>|<expresion>
        La expresion puede contener '|' (p.ej. un literal 'A|B'), asi que el troceo es a 3
        campos como maximo y el resto se queda entero en el ultimo.  #>
    param([string[]]$Lineas)

    $mapa = @{}
    foreach ($ln in @($Lineas)) {
        $s = "$ln".Trim()
        if (-not $s.StartsWith($script:RsDefMark)) { continue }
        $partes = $s.Substring($script:RsDefMark.Length) -split '\|', 3
        if ($partes.Count -lt 3) { continue }
        $tabla = $partes[0].Trim()
        $col   = $partes[1].Trim()
        $expr  = $partes[2].Trim()
        if (-not $tabla -or -not $col -or -not $expr) { continue }
        # NULL literal: Oracle guarda el texto 'NULL' cuando se declara DEFAULT NULL, que es
        # exactamente lo mismo que no tener default. No merece la pena ensuciar el DDL con el.
        if ($expr -eq 'NULL') { continue }
        $mapa["$tabla.$col"] = $expr
    }
    return $mapa
}

function Get-RsColumnDefaults {
    <#  Devuelve @{ ok = <bool>; error = <string>; defaults = @{ "TABLA.COL" = "expr" } }.

        ⛔ Nunca lanza: que la BD no sepa dar los defaults no puede tumbar una sincronizacion
        de modelo que, por lo demas, ha ido bien. El llamante avisa y sigue.  #>
    param(
        [Parameter(Mandatory=$true)][string]$Motor,
        [Parameter(Mandatory=$true)][string]$Esquema,
        [Parameter(Mandatory=$true)][string]$DataSource,
        [string]$Usuario = "",
        [string]$Password = "",
        [string[]]$Tablas = @()
    )

    $res = @{ ok = $false; error = ""; defaults = @{} }
    $motorU = "$Motor".ToUpper()
    $esq    = "$Esquema".ToUpper()

    $tempSql = [System.IO.Path]::GetTempFileName() + ".sql"
    $tempOut = [System.IO.Path]::GetTempFileName() + ".txt"

    try {
        if ($motorU -eq 'ORACLE') {
            $filtroTablas = ""
            if ($Tablas -and $Tablas.Count -gt 0) {
                $lista = ($Tablas | ForEach-Object { "'" + ("$_".ToUpper().Replace("'","''")) + "'" }) -join ","
                $filtroTablas = "       AND TABLE_NAME IN ($lista)`n"
            }
            $connect = if ($Password) { "CONNECT $Usuario/$Password@$DataSource`n" } else { "" }

            # SUBSTR(...,1,3000) acota la linea de DBMS_OUTPUT (limite 32767) sin trocear nada
            # real: un DEFAULT de mas de 3000 caracteres no existe en la practica, y si existiera
            # es una expresion que hay que revisar a mano, no copiar a ciegas al instalador.
            @"
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF VERIFY OFF TERMOUT ON
SET LINESIZE 32767 TRIMSPOOL ON TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
$connect
DECLARE
  l_def LONG;
BEGIN
  FOR r IN (SELECT TABLE_NAME, COLUMN_NAME
              FROM ALL_TAB_COLS
             WHERE OWNER = '$esq'
               AND DEFAULT_LENGTH IS NOT NULL
               AND VIRTUAL_COLUMN = 'NO'
               AND HIDDEN_COLUMN  = 'NO'
$filtroTablas             ORDER BY TABLE_NAME, COLUMN_ID) LOOP
    SELECT DATA_DEFAULT INTO l_def
      FROM ALL_TAB_COLS
     WHERE OWNER = '$esq' AND TABLE_NAME = r.TABLE_NAME AND COLUMN_NAME = r.COLUMN_NAME;
    l_def := TRIM(REPLACE(REPLACE(l_def, CHR(13), ' '), CHR(10), ' '));
    IF l_def IS NOT NULL AND INSTR(UPPER(l_def), 'ISEQ`$`$') = 0 THEN
      DBMS_OUTPUT.PUT_LINE('$($script:RsDefMark)' || r.TABLE_NAME || '|' || r.COLUMN_NAME || '|' || SUBSTR(l_def, 1, 3000));
    END IF;
  END LOOP;
END;
/
EXIT;
"@ | Set-Content $tempSql -Encoding ASCII

            sqlplus -S /nolog "@$tempSql" > $tempOut 2>&1
            $salida = Get-Content $tempOut -ErrorAction SilentlyContinue
        }
        elseif ($motorU -eq 'SQLSERVER') {
            $filtroTablas = ""
            if ($Tablas -and $Tablas.Count -gt 0) {
                $lista = ($Tablas | ForEach-Object { "'" + ("$_".ToUpper().Replace("'","''")) + "'" }) -join ","
                $filtroTablas = "  AND UPPER(t.TABLE_NAME) IN ($lista)`n"
            }
            @"
SET NOCOUNT ON;
SELECT '$($script:RsDefMark)' + t.TABLE_NAME + '|' + c.COLUMN_NAME + '|'
     + LTRIM(RTRIM(REPLACE(REPLACE(c.COLUMN_DEFAULT, CHAR(13), ' '), CHAR(10), ' ')))
FROM INFORMATION_SCHEMA.TABLES t
JOIN INFORMATION_SCHEMA.COLUMNS c
  ON c.TABLE_NAME = t.TABLE_NAME AND c.TABLE_SCHEMA = t.TABLE_SCHEMA
WHERE t.TABLE_TYPE = 'BASE TABLE'
  AND c.COLUMN_DEFAULT IS NOT NULL
$($filtroTablas)ORDER BY t.TABLE_NAME, c.ORDINAL_POSITION;
"@ | Set-Content $tempSql -Encoding ASCII

            $previo = $env:SQLCMDPASSWORD
            try {
                $argumentos = @('-S', $DataSource, '-d', $Esquema, '-i', $tempSql, '-h', '-1', '-W', '-y', '0', '-Y', '0')
                if ($Usuario) {
                    $env:SQLCMDPASSWORD = $Password
                    $argumentos += @('-U', $Usuario)
                } else {
                    $argumentos += '-E'
                }
                & sqlcmd @argumentos > $tempOut 2>&1
            } finally {
                if ($null -eq $previo) { Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue }
                else { $env:SQLCMDPASSWORD = $previo }
            }
            $salida = Get-Content $tempOut -ErrorAction SilentlyContinue
        }
        else {
            $res.error = "Motor no soportado: $Motor"
            return $res
        }

        $errLinea = @($salida | Where-Object { "$_".Trim() -match '^(ORA-|SP2-|PLS-|Msg\s+\d+)' } | Select-Object -First 1)
        if ($errLinea.Count -gt 0) {
            $res.error = "$($errLinea[0])".Trim()
            return $res
        }

        $res.defaults = ConvertTo-RsDefaultsMap -Lineas $salida
        $res.ok = $true
        return $res
    }
    catch {
        $res.error = $_.Exception.Message
        return $res
    }
    finally {
        Remove-Item $tempSql, $tempOut -Force -ErrorAction SilentlyContinue
    }
}
