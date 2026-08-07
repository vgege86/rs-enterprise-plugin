<#
.SYNOPSIS
    Distingue "el objeto no existe" de "mi cuenta no lo ve". Dot-sourcear desde todo hook que
    concluya algo a partir de lo que la BD le devolvio.

.NOTES
    EL PROBLEMA

    La cuenta de consulta de un proyecto no suele ser la duena del esquema: ve por GRANT
    per-object. Y Oracle no da forma de distinguir las dos cosas —ORA-00942 es deliberadamente
    ambiguo, y ALL_TABLES / ALL_OBJECTS / ALL_SOURCE estan TODAS filtradas por privilegio—.
    Una tabla sin GRANT no aparece en ningun sitio: para el hook es indistinguible de una tabla
    borrada.

    Medido en una instalacion de cliente: la sincronizacion daba 323 tablas; tras conceder los
    GRANT que faltaban, 329. Seis tablas reales figuraban como inexistentes, y la sincronizacion
    no solo se las iba a llevar por delante — les habia puesto los indices a 0, DEGRADANDO el
    modelo sin que nada lo dijera. Con el PL/SQL es peor todavia: exige GRANT EXECUTE, no
    SELECT, y con 0 grants EXECUTE tanto ALL_OBJECTS como ALL_SOURCE devuelven CERO
    procedimientos SIN ERROR. Tras conceder 13, aparecieron 12 procedimientos y 1 paquete.

    LA REGLA

    Si no se puede distinguir, no se concluye. Nunca se borra ni se degrada un objeto que
    simplemente no se ve: se conserva y se marca "no visible". Lo que si se puede saber, y este
    fichero saca a la luz, es CUANTO no se esta viendo:

      es_dueno    el usuario conectado es el owner del esquema -> visibilidad total, sin huecos
                  posibles. Es el unico caso en que un conteo bajo significa de verdad "no hay".
      grants      cuantos privilegios de cada tipo tiene la cuenta sobre el esquema. 0 EXECUTE
                  explica un 0 de procedimientos sin ninguna ambiguedad: no es que no haya, es
                  que no se ven.
      diccionario cuantos objetos de cada tipo ve ALL_OBJECTS. Contrastado con lo que el hook
                  llego a capturar, delata tanto los huecos de permisos como los filtros del
                  propio script que pierden objetos.

    SOLO ORACLE. En SQL Server la visibilidad no funciona igual y no hay ningun caso medido, asi
    que devuelve soportado=$false y el llamante se salta el bloque de cobertura en vez de
    inventarse una semantica sin probar. La regla de no degradar, que es independiente del
    motor, se aplica igual en los dos.
#>

# Marcador de linea, mismo patron que $script:RsDefMark de lib-dbmodel.ps1: separa las filas
# utiles del banner de sqlplus y de cualquier aviso.
$script:RsVisMark = '##VIS##'

# OBJECT_TYPE de ALL_OBJECTS -> seccion del inventario del modelo. PACKAGE BODY no esta: en el
# modelo la especificacion y el cuerpo son UNA ficha (ver scripts/_dbobjetos.py), asi que
# contarlo aparte daria un hueco falso permanente.
$script:RsTipoASeccion = @{
    'TABLE'     = 'tablas'
    'VIEW'      = 'vistas'
    'SEQUENCE'  = 'secuencias'
    'PROCEDURE' = 'procedimientos'
    'FUNCTION'  = 'funciones'
    'PACKAGE'   = 'paquetes'
    'TRIGGER'   = 'triggers'
    'SYNONYM'   = 'sinonimos'
    'INDEX'     = 'indices'
}

function Get-RsVisibilidad {
    <#  Diagnostico de visibilidad de una conexion sobre un esquema.

        Devuelve @{ ok; soportado; error; usuario; esquema; es_dueno; grants = @{PRIV = n};
                    diccionario = @{seccion = n}; tipos = @{OBJECT_TYPE = n} }.

        ⛔ Nunca lanza. Que no se pueda diagnosticar la visibilidad no puede tumbar una
        sincronizacion que, por lo demas, ha ido bien: el llamante avisa y sigue sin bloque de
        cobertura.  #>
    param(
        [Parameter(Mandatory=$true)][string]$Motor,
        [Parameter(Mandatory=$true)][string]$Esquema,
        [Parameter(Mandatory=$true)][string]$DataSource,
        [string]$Usuario = "",
        [string]$Password = ""
    )

    $res = @{ ok = $false; soportado = $false; error = ""; usuario = $Usuario
              esquema = "$Esquema".ToUpper(); es_dueno = $false
              grants = @{}; diccionario = @{}; tipos = @{} }

    if ("$Motor".ToUpper() -ne 'ORACLE') {
        # No es un error: es que aqui no hay nada medido que contar.
        $res.ok = $true
        $res.error = "diagnostico de visibilidad solo implementado para Oracle (motor: $Motor)"
        return $res
    }

    $esq     = "$Esquema".ToUpper()
    $tempSql = [System.IO.Path]::GetTempFileName() + ".sql"
    $tempOut = [System.IO.Path]::GetTempFileName() + ".txt"

    try {
        $connect = if ($Password) { "CONNECT $Usuario/$Password@$DataSource`n" } else { "" }

        # Las tres consultas van en la MISMA sesion: el reloj de esto se lo lleva el login, no
        # la consulta. Los grants se cuentan por lo que la cuenta puede usar de verdad —directo,
        # por PUBLIC o por rol—, no por lo que este declarado en la tabla.
        @"
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF VERIFY OFF TERMOUT ON
SET LINESIZE 32767 TRIMSPOOL ON TRIMOUT ON
$connect
SELECT '$($script:RsVisMark)USER|' || USER FROM DUAL;

SELECT '$($script:RsVisMark)OBJ|' || OBJECT_TYPE || '|' || COUNT(*)
  FROM ALL_OBJECTS
 WHERE OWNER = '$esq'
   AND OBJECT_NAME NOT LIKE 'BIN`$%'
 GROUP BY OBJECT_TYPE;

SELECT '$($script:RsVisMark)PRIV|' || PRIVILEGE || '|' || COUNT(*)
  FROM ALL_TAB_PRIVS
 WHERE TABLE_SCHEMA = '$esq'
   AND GRANTEE IN (SELECT USER FROM DUAL
                   UNION ALL SELECT 'PUBLIC' FROM DUAL
                   UNION ALL SELECT GRANTED_ROLE FROM USER_ROLE_PRIVS)
 GROUP BY PRIVILEGE;
EXIT;
"@ | Set-Content $tempSql -Encoding ASCII

        sqlplus -S /nolog "@$tempSql" > $tempOut 2>&1
        $salida = Get-Content $tempOut -ErrorAction SilentlyContinue

        $errLinea = @($salida | Where-Object { "$_".Trim() -match '^(ORA-|SP2-|PLS-)' } | Select-Object -First 1)
        if ($errLinea.Count -gt 0) {
            $res.error = "$($errLinea[0])".Trim()
            return $res
        }

        foreach ($ln in @($salida)) {
            $s = "$ln".Trim()
            if (-not $s.StartsWith($script:RsVisMark)) { continue }
            $partes = $s.Substring($script:RsVisMark.Length) -split '\|'
            # Sin `switch`: un `break` dentro de un switch anidado en este foreach abandonaria
            # el parseo entero en cuanto llegara una linea corta.
            if ($partes[0] -eq 'USER' -and $partes.Count -ge 2) {
                $res.usuario = $partes[1].Trim()
            }
            elseif ($partes[0] -eq 'OBJ' -and $partes.Count -ge 3) {
                $tipo = $partes[1].Trim()
                $n    = 0
                if ([int]::TryParse($partes[2].Trim(), [ref]$n)) {
                    $res.tipos[$tipo] = $n
                    $sec = $script:RsTipoASeccion[$tipo]
                    if ($sec) { $res.diccionario[$sec] = $n }
                }
            }
            elseif ($partes[0] -eq 'PRIV' -and $partes.Count -ge 3) {
                $n = 0
                if ([int]::TryParse($partes[2].Trim(), [ref]$n)) {
                    $res.grants[$partes[1].Trim()] = $n
                }
            }
        }

        $res.es_dueno  = ($res.usuario -and $res.usuario.ToUpper() -eq $esq)
        $res.soportado = $true
        $res.ok        = $true
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

function New-RsCobertura {
    <#  Cruza lo que el diccionario dice que hay con lo que el hook llego a capturar.

        -Capturado es una hashtable @{ seccion = n } con las MISMAS claves que
        $script:RsTipoASeccion produce ('tablas', 'vistas', 'indices'...).

        -Excluido es opcional: @{ seccion = @{ n = <cuantos>; motivo = "<por que>" } }, para lo
        que el propio script descarta a proposito (secuencias de columna IDENTITY, objetos del
        recycle bin). Sin esto, una exclusion legitima se cuenta como hueco y la cobertura cria
        avisos que nadie vuelve a mirar.

        Devuelve @{ es_dueno; usuario; esquema; grants; secciones = @( @{seccion; real;
        capturado; excluido; motivo; hueco} ); huecos = <n>; parcial = <bool>; nota }.

        `parcial` es lo que decide el exit 2 del hook llamante: hay hueco Y no somos el dueno,
        asi que el hueco puede ser perfectamente una tabla real que no se ve. Siendo el dueno,
        un descuadre es un fallo del script, no de permisos, y tambien se marca — pero se dice
        que la causa NO son los permisos, para no mandar a nadie a pedir GRANTs en balde.  #>
    param(
        [Parameter(Mandatory=$true)]$Visibilidad,
        [Parameter(Mandatory=$true)][hashtable]$Capturado,
        [hashtable]$Excluido = @{}
    )

    $cob = @{ es_dueno = [bool]$Visibilidad.es_dueno; usuario = "$($Visibilidad.usuario)"
              esquema = "$($Visibilidad.esquema)"; grants = $Visibilidad.grants
              secciones = @(); huecos = 0; parcial = $false; nota = "" }

    foreach ($sec in ($Capturado.Keys | Sort-Object)) {
        $real = if ($Visibilidad.diccionario.ContainsKey($sec)) { [int]$Visibilidad.diccionario[$sec] } else { $null }
        $cap  = [int]$Capturado[$sec]
        $exc  = 0
        $motivo = ""
        if ($Excluido.ContainsKey($sec)) {
            $exc    = [int]$Excluido[$sec].n
            $motivo = "$($Excluido[$sec].motivo)"
        }
        # Hueco = lo que el diccionario ve y el script no capturo ni excluyo a proposito.
        $hueco = if ($null -eq $real) { 0 } else { [Math]::Max(0, $real - $cap - $exc) }
        $cob.secciones += @{ seccion = $sec; real = $real; capturado = $cap
                             excluido = $exc; motivo = $motivo; hueco = $hueco }
        $cob.huecos += $hueco
    }

    if ($cob.huecos -gt 0) {
        $cob.parcial = $true
        $cob.nota = if ($cob.es_dueno) {
            "Descuadre con la cuenta DUENA del esquema: no son permisos, es un filtro del propio script."
        } else {
            "La cuenta no es duena del esquema: el hueco puede ser un objeto real sin GRANT. Nada se ha borrado."
        }
    } elseif (-not $cob.es_dueno) {
        $cob.nota = "Cuenta no duena del esquema, pero el conteo cuadra con el diccionario."
    }

    return $cob
}

function Merge-RsCobertura {
    <#  Vuelca la cobertura al bloque `_cobertura` del modelo, MEZCLANDO por seccion.

        Cada sincronizacion conoce solo su parte —sync-from-db las tablas, sync-indexes los
        indices, model-objects los objetos de BD—, asi que el bloque se acumula en vez de
        reescribirse: si sync-indexes borrara lo que puso sync-from-db, la cobertura solo diria
        la verdad justo despues de la ultima sincronizacion que se ejecuto.

        Cada seccion guarda quien la escribio y cuando, para que un bloque viejo no se lea como
        si fuera de esta ejecucion.

        Muta $Model (es un PSCustomObject y el llamante lo guarda despues).  #>
    param(
        [Parameter(Mandatory=$true)]$Model,
        [Parameter(Mandatory=$true)]$Cobertura,
        [Parameter(Mandatory=$true)][string]$Origen
    )

    $ahora = (Get-Date -Format "o")

    if (-not ($Model.PSObject.Properties.Name -contains '_cobertura') -or -not $Model._cobertura) {
        $Model | Add-Member -Force -NotePropertyName '_cobertura' -NotePropertyValue ([PSCustomObject]@{
            _nota = ("Conteo real del diccionario de la BD frente a lo que la sincronizacion " +
                     "llego a capturar. Un hueco con una cuenta que NO es duena del esquema " +
                     "significa 'no lo veo', no 'no existe': nada se borra por eso.")
        })
    }
    $cb = $Model._cobertura

    foreach ($campo in @('conexion', 'usuario', 'esquema', 'es_dueno', 'grants')) {
        if ($Cobertura.PSObject.Properties.Name -contains $campo -or
            ($Cobertura -is [hashtable] -and $Cobertura.ContainsKey($campo))) {
            $cb | Add-Member -Force -NotePropertyName $campo -NotePropertyValue $Cobertura.$campo
        }
    }
    $cb | Add-Member -Force -NotePropertyName 'actualizado' -NotePropertyValue $ahora

    if (-not ($cb.PSObject.Properties.Name -contains 'secciones') -or -not $cb.secciones) {
        $cb | Add-Member -Force -NotePropertyName 'secciones' -NotePropertyValue ([PSCustomObject]@{})
    }
    foreach ($s in $Cobertura.secciones) {
        $cb.secciones | Add-Member -Force -NotePropertyName $s.seccion -NotePropertyValue ([PSCustomObject]@{
            real       = $s.real
            capturado  = $s.capturado
            excluido   = $s.excluido
            motivo     = $s.motivo
            hueco      = $s.hueco
            origen     = $Origen
            fecha      = $ahora
        })
    }
    return $cb
}

function Set-RsTablaVisible {
    <#  Marca una tabla del modelo como vista o NO vista en esta sincronizacion.

        ⛔ Lo que NO hace: borrar la tabla, sus columnas o sus indices. Una tabla que no se ve
        con una cuenta sin GRANT es indistinguible de una borrada, y de las dos lecturas posibles
        solo una destruye informacion. Se conserva y se marca.

        Vista   -> se quita la marca `visible` (su ausencia significa "visible", que es el caso
                   normal: asi el modelo no engorda con un campo por tabla).
        No vista -> `visible = $false` y `visible_check` con la fecha, para poder distinguir una
                   tabla que hoy no se ve de una que lleva meses sin verse.  #>
    param(
        [Parameter(Mandatory=$true)]$Tabla,
        [Parameter(Mandatory=$true)][bool]$Vista,
        [string]$Fecha = ""
    )
    if ($Vista) {
        if ($Tabla.PSObject.Properties.Name -contains 'visible') {
            $Tabla.PSObject.Properties.Remove('visible')
        }
        if ($Tabla.PSObject.Properties.Name -contains 'visible_check') {
            $Tabla.PSObject.Properties.Remove('visible_check')
        }
        return
    }
    if (-not $Fecha) { $Fecha = (Get-Date -Format "o") }
    $Tabla | Add-Member -Force -NotePropertyName 'visible'       -NotePropertyValue $false
    $Tabla | Add-Member -Force -NotePropertyName 'visible_check' -NotePropertyValue $Fecha
}

function Format-RsCobertura {
    <#  El bloque de cobertura como lineas de texto, para el log del hook. Devuelve string[].  #>
    param([Parameter(Mandatory=$true)]$Cobertura)

    $l = @()
    $l += "---- Cobertura (conteo real en el diccionario vs capturado) ----"
    $quien = if ($Cobertura.es_dueno) { "DUENA del esquema" } else { "solo con GRANT per-object" }
    $l += ("   Cuenta: {0} sobre {1} ({2})" -f $Cobertura.usuario, $Cobertura.esquema, $quien)

    if ($Cobertura.grants -and $Cobertura.grants.Count -gt 0) {
        $g = ($Cobertura.grants.Keys | Sort-Object | ForEach-Object { "$_ $($Cobertura.grants[$_])" }) -join " . "
        $l += "   Grants: $g"
    } elseif (-not $Cobertura.es_dueno) {
        $l += "   Grants: NINGUNO detectado sobre este esquema."
    }

    foreach ($s in $Cobertura.secciones) {
        $real = if ($null -eq $s.real) { "n/d" } else { "$($s.real)" }
        $linea = "   {0,-16} diccionario {1,6}  capturado {2,6}" -f $s.seccion, $real, $s.capturado
        if ($s.excluido -gt 0) { $linea += "  excluidas $($s.excluido) ($($s.motivo))" }
        if ($s.hueco -gt 0)    { $linea += "  << HUECO $($s.hueco)" }
        $l += $linea
    }

    if ($Cobertura.nota) { $l += "   $($Cobertura.nota)" }
    if ($Cobertura.parcial -and -not $Cobertura.es_dueno) {
        $l += "   Para cerrarlo: conceder los GRANT que falten (SELECT para tablas/vistas,"
        $l += "   EXECUTE para procedimientos y paquetes) y repetir la sincronizacion."
    }
    return $l
}
