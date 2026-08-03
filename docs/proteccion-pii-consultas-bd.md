# Protección de datos personales en consultas a BD desde herramientas de IA

**Fecha:** 2026-08-03
**Ámbito:** Soluciones uCollect/RS consultadas mediante el plugin `rs-enterprise-agent`
**Destinatario:** Departamento de Sistemas / Administración de Bases de Datos
**Estado:** Petición de control definitivo + medida provisional en curso

---

## 1. Resumen ejecutivo

Las herramientas de desarrollo asistido por IA que usamos ejecutan consultas `SELECT`
contra las bases de datos de las soluciones uCollect/RS y **envían el resultado íntegro
a un proveedor externo** (Anthropic) como parte del contexto de la conversación.

Hoy eso incluye, sin ningún filtro, columnas con datos personales: nombres, DNI,
teléfonos, direcciones, correos y números de cuenta de personas deudoras.

Este documento pide a Sistemas el control que resuelve el problema de raíz —
**que la base de datos no emita esos datos** — y describe la medida provisional que
Desarrollo implantará mientras tanto, junto con lo que esa medida **no** puede proteger.

En §3 se presentan **todas** las opciones técnicas disponibles, con y sin coste de
licencia, en igualdad de condiciones. Desarrollo no tiene visibilidad sobre las
licencias contratadas ni sobre el presupuesto: **la elección corresponde a Sistemas.**

| | Control definitivo (Sistemas) | Medida provisional (Desarrollo) |
|---|---|---|
| Dónde actúa | En el motor de BD | En la herramienta, tras recibir el dato |
| ¿Se puede eludir? | No | Sí (ver §5.2) |
| Coste de licencia | Según opción elegida (§3.2) | Ninguno |
| Esfuerzo | Entre 1 y 5 jornadas de DBA según opción | Estimado 8-12 jornadas de desarrollo |
| Válido ante auditoría | Sí | Parcialmente, con salvedades documentadas |

---

## 2. Situación actual y riesgo

### 2.1 Cómo fluye el dato hoy

```
Agente IA  ──SELECT──▶  Oracle / SQL Server
                             │
                             ▼
                     Resultado en claro
                             │
                             ▼
              Contexto de la conversación (texto)
                             │
                             ▼
                   Proveedor externo (Anthropic)
```

No existe ningún punto intermedio que inspeccione o filtre los valores.

### 2.2 Alcance real

Diez agentes del plugin consultan datos de negocio de forma habitual: análisis de
impacto, validación de tipos contra BD, comparación de esquemas entre entornos,
generación de scripts de idiomas y preparación de entregas.

Las consultas están limitadas a `SELECT` (existe una guarda que bloquea `INSERT`,
`UPDATE`, `DELETE`, `MERGE`, sentencias múltiples y CTE con verbos de escritura),
de modo que **no hay riesgo de modificación de datos**. El riesgo es exclusivamente
de **exposición**.

### 2.3 Calificación del riesgo

- Las categorías de datos afectadas son datos personales identificativos y datos
  financieros de personas físicas en situación de impago.
- La transferencia a un tercero no está cubierta por una base de licitud específica
  para esta finalidad concreta.
- La exposición es **silenciosa**: no queda constancia de qué datos concretos se
  enviaron ni cuándo, más allá del historial de conversaciones.

### 2.4 Por qué el usuario de conexión actual agrava el problema

En las instalaciones actuales, el desarrollador conecta con el **usuario propietario
del esquema**. Ese usuario tiene `SELECT` sobre todo. Cualquier control que dependa
de permisos, políticas o redacción queda anulado si se mantiene esa credencial: en
Oracle el propietario ve siempre sus propias tablas sin redactar, y en SQL Server los
miembros de `db_owner` conservan el privilegio `UNMASK`.

**Cambiar la credencial es el primer paso y habilita todos los demás.**

---

## 3. Control definitivo: petición a Sistemas

### 3.1 Paso 1 — Usuario dedicado de solo lectura (imprescindible)

Crear un usuario de BD por entorno destinado exclusivamente a las herramientas de
desarrollo asistido, **sin** privilegios administrativos y **sin** `SELECT` directo
sobre las tablas que contienen datos personales.

**Oracle**

```sql
CREATE USER RS_AGENTE IDENTIFIED BY "<password>";
GRANT CREATE SESSION TO RS_AGENTE;
-- Sin GRANT SELECT sobre las tablas base con datos personales.
-- El acceso llega exclusivamente por el mecanismo de redacción que se elija en 3.2.
```

**SQL Server**

```sql
CREATE LOGIN RS_AGENTE WITH PASSWORD = '<password>';
CREATE USER  RS_AGENTE FOR LOGIN RS_AGENTE;
-- Sin db_owner, sin db_datareader global.
DENY UNMASK TO RS_AGENTE;   -- necesario para que el enmascarado del paso 2 aplique
```

- **Coste de licencia:** ninguno.
- **Esfuerzo:** menos de una jornada.
- **Efecto por sí solo:** ninguno hasta completar el paso 2, pero **sin este paso
  ninguna otra medida es efectiva**.

### 3.2 Paso 2 — Redacción en el motor

Se recogen a continuación **todas** las opciones evaluadas, con y sin coste de
licencia. Ninguna se descarta desde Desarrollo: se exponen con sus requisitos,
ventajas e inconvenientes para que Sistemas decida en función de las licencias
contratadas y del presupuesto disponible.

Todas ellas requieren previamente el paso 3.1. La comparativa resumida está en §3.3.

#### Opción A — Vistas redactadas (Oracle y SQL Server, coste cero, cualquier edición)

Se crea una vista por cada tabla con datos personales. La vista devuelve las columnas
no sensibles tal cual y sustituye las sensibles por un valor sin capacidad
identificativa. El usuario `RS_AGENTE` recibe permiso **solo sobre la vista**.

```sql
CREATE OR REPLACE VIEW V_RDEUDORES AS
SELECT
    IDDEUDOR,                                        -- identificador técnico, se conserva
    IDEXPEDIENTE,
    SALDO_PENDIENTE,
    FECHA_ALTA,
    STANDARD_HASH(NOMBRE,   'SHA256') AS NOMBRE,     -- pseudónimo estable
    STANDARD_HASH(DNI,      'SHA256') AS DNI,
    STANDARD_HASH(TELEFONO, 'SHA256') AS TELEFONO,
    CAST(NULL AS VARCHAR2(200))       AS DIRECCION   -- suprimida
FROM RDEUDORES;

GRANT SELECT ON V_RDEUDORES TO RS_AGENTE;
```

`STANDARD_HASH` está disponible en Oracle 12c y superiores sin opciones adicionales.
En SQL Server el equivalente es `HASHBYTES('SHA2_256', <col>)`. Si la versión no
dispone de función de hash, basta con devolver `NULL` o un literal fijo.

El uso de un pseudónimo estable en vez de `NULL` es deliberado: permite seguir
detectando duplicados y correlacionar filas de la misma persona, que es lo que
necesitan las tareas de diagnóstico, sin revelar el valor.

> **Nota técnica:** Oracle **no** admite `GRANT SELECT` a nivel de columna — solo
> `INSERT`, `UPDATE` y `REFERENCES`. Por eso la vista es la vía correcta y no existe
> un atajo con permisos por columna.

- **Coste de licencia:** ninguno. Funciona en Standard Edition y en SQL Server Express.
- **Esfuerzo:** proporcional al número de tablas afectadas. Estimado 3-4 jornadas
  para el inventario que se adjunta en §6.
- **Mantenimiento:** una tabla nueva con datos personales requiere su vista. Se puede
  detectar automáticamente (ver §4.3).

#### Opción B — Dynamic Data Masking (solo SQL Server, coste cero desde 2016 SP1)

Sin crear vistas: se marca la columna en la propia tabla.

```sql
ALTER TABLE RDEUDORES ALTER COLUMN NOMBRE
    ADD MASKED WITH (FUNCTION = 'default()');
ALTER TABLE RDEUDORES ALTER COLUMN TELEFONO
    ADD MASKED WITH (FUNCTION = 'partial(0,"XXXXX",0)');
ALTER TABLE RDEUDORES ALTER COLUMN EMAIL
    ADD MASKED WITH (FUNCTION = 'email()');
```

Disponible en **todas las ediciones** de SQL Server desde 2016 SP1. Los usuarios con
`UNMASK` (entre ellos `db_owner`) siguen viendo el valor real, de ahí el `DENY UNMASK`
del paso 1.

- **Ventaja frente a las vistas:** no duplica objetos ni obliga a reescribir consultas.
- **Limitación:** el enmascarado de DDM no es determinista, por lo que **no permite
  correlacionar filas**. Si esa capacidad importa, usar la Opción A.

#### Opción C — Oracle VPD con enmascarado de columna (requiere Enterprise Edition)

Virtual Private Database (`DBMS_RLS`) admite *column-masking*: la política devuelve
`NULL` en las columnas sensibles para las sesiones afectadas, sin crear vistas ni
tocar la aplicación.

```sql
BEGIN
  DBMS_RLS.ADD_POLICY(
    object_schema    => 'UCOLLECT',
    object_name      => 'RDEUDORES',
    policy_name      => 'PII_AGENTE',
    policy_function  => 'PKG_SEGURIDAD.F_PII',
    sec_relevant_cols        => 'NOMBRE,DNI,TELEFONO,DIRECCION',
    sec_relevant_cols_opt    => DBMS_RLS.ALL_ROWS);   -- devuelve NULL, no filtra filas
END;
/
```

- **Requisito:** Oracle **Enterprise Edition**. VPD va incluido en EE, **no** exige la
  opción Advanced Security. No disponible en Standard Edition.
- **Coste adicional si ya se dispone de EE:** ninguno.
- **Ventaja:** transparente para la aplicación; no duplica objetos; una política cubre
  todas las sesiones del usuario.
- **Inconveniente:** solo suprime (`NULL`), no seudonimiza — se pierde la capacidad de
  correlacionar filas. Los usuarios con `EXEMPT ACCESS POLICY` la eluden.

#### Opción D — Oracle Data Redaction (requiere licencia Advanced Security)

`DBMS_REDACT` es la solución nativa de Oracle para este caso exacto. Redacta en el
momento de la consulta, con políticas declarativas y varios modos (total, parcial,
expresión regular, aleatorio).

```sql
BEGIN
  DBMS_REDACT.ADD_POLICY(
    object_schema => 'UCOLLECT',
    object_name   => 'RDEUDORES',
    column_name   => 'DNI',
    policy_name   => 'RED_DEUDORES',
    function_type => DBMS_REDACT.PARTIAL,
    function_parameters => 'VVVVVVVVV,VVVVVVVVV,*,1,5',
    expression    => 'SYS_CONTEXT(''USERENV'',''SESSION_USER'') = ''RS_AGENTE''');
END;
/
```

- **Requisito:** Oracle Enterprise Edition **+ opción Advanced Security** (de pago,
  licenciada por procesador o por usuario nombrado).
- **Ventaja:** es la opción más completa y la de menor esfuerzo de implantación y
  mantenimiento; no requiere vistas ni cambios en la aplicación; el redactado se
  aplica por expresión, de modo que la misma tabla puede verse íntegra por la
  aplicación de producción y redactada por `RS_AGENTE`.
- **Inconveniente:** coste de licencia. Los usuarios con `EXEMPT REDACTION POLICY` la eluden.
- **Nota:** Advanced Security incluye también TDE. Si ya está contratada por ese
  motivo, Data Redaction está disponible sin coste incremental — **conviene verificarlo
  antes de descartarla**.

#### Opción E — SQL Server Always Encrypted (sin coste, alto impacto en la aplicación)

Cifra la columna de extremo a extremo; la clave reside en el cliente y el motor nunca
ve el valor en claro. Un cliente sin la clave —como sería `RS_AGENTE`— recibe solo
texto cifrado.

- **Requisito:** SQL Server 2016 SP1 o superior, **todas las ediciones**. Sin coste.
- **Ventaja:** es el control más fuerte de los listados; el dato en claro no existe ni
  siquiera dentro del motor.
- **Inconveniente serio:** rompe `LIKE`, comparaciones de rango, `ORDER BY` y la mayor
  parte de funciones sobre las columnas cifradas. El cifrado determinista solo admite
  igualdad. **Las aplicaciones uCollect existentes requerirían cambios significativos.**
  No se recomienda adoptarlo únicamente para resolver este problema, pero se incluye
  por completitud y por si encaja en una iniciativa más amplia de cifrado.

#### Opción F — Herramientas de enmascarado de terceros (de pago)

Productos comerciales de enmascaramiento dinámico o de generación de entornos
saneados (Delphix, Informatica Dynamic Data Masking, IBM Optim, Oracle Data Masking
and Subsetting Pack, entre otros).

- **Requisito:** licencia por producto, más despliegue de infraestructura propia.
- **Ventaja:** cobertura homogénea sobre varios motores y aplicaciones a la vez, con
  catálogo de datos sensibles y trazabilidad integrada. Interesa si el problema excede
  este caso concreto y afecta a más sistemas de la organización.
- **Inconveniente:** el de mayor coste y plazo. Desproporcionado si el alcance se
  limita a las consultas descritas en este documento.

#### Lo que no resuelve este problema

Conviene descartarlo explícitamente para evitar una conclusión errónea frecuente:

- **TDE (Transparent Data Encryption)**, tanto en Oracle como en SQL Server, cifra los
  ficheros de datos y las copias de seguridad. Protege frente a la sustracción del
  soporte físico. **Una sesión autenticada sigue viendo todos los datos en claro**, por
  lo que no aporta nada al escenario descrito. Si ya está implantado, no cubre este riesgo.
- **Cifrado del canal (TLS)** protege el tránsito, no el destinatario. El dato llega
  en claro a la herramienta y de ahí al proveedor externo.

### 3.3 Comparativa de opciones

| Opción | Motor | Edición mínima | Licencia adicional | Esfuerzo DBA | Impacto en la aplicación | Correlación de filas |
|---|---|---|---|---|---|---|
| **A** Vistas redactadas | Oracle y SQL Server | Cualquiera | No | 3-4 jornadas | Ninguno (solo `RS_AGENTE`) | Sí |
| **B** Dynamic Data Masking | SQL Server | 2016 SP1, cualquiera | No | 1-2 jornadas | Ninguno | No |
| **C** VPD column-masking | Oracle | **Enterprise** | No, incluida en EE | 2-3 jornadas | Ninguno | No |
| **D** Data Redaction | Oracle | **Enterprise** | **Sí — Advanced Security** | 1-2 jornadas | Ninguno | Configurable |
| **E** Always Encrypted | SQL Server | 2016 SP1, cualquiera | No | 5+ jornadas | **Alto — requiere cambios** | Solo determinista |
| **F** Producto de terceros | Ambos | — | **Sí — según producto** | Proyecto | Variable | Sí |

Todas las opciones exigen el paso 3.1 (usuario dedicado). Sin él, ninguna es efectiva.

### 3.4 Paso 3 — Registro de acceso (recomendado, no bloqueante)

Auditoría de las conexiones de `RS_AGENTE` para poder acreditar qué se consultó y cuándo.

| Vía | Motor | Licencia |
|---|---|---|
| Unified Auditing (`AUDIT POLICY`) | Oracle | Incluido |
| SQL Server Audit / Extended Events | SQL Server | Incluido |
| Oracle Audit Vault and Database Firewall | Oracle | **De pago** — centraliza y protege la evidencia frente a manipulación |

Es lo que convierte «creemos que no se expuso nada» en una afirmación demostrable,
que es lo que pide un procedimiento de auditoría.

### 3.5 Decisión requerida y petición

**Desarrollo no puede decidir sobre licenciamiento.** Se solicita a Sistemas que
determine qué opción de §3.2 se adopta, en función de las licencias ya contratadas
—en particular, si existe Oracle Enterprise Edition y si Advanced Security está ya
disponible por TDE u otro motivo— y del presupuesto.

| # | Acción | Responsable | Licencia | Esfuerzo |
|---|---|---|---|---|
| 1 | Crear usuario `RS_AGENTE` de solo lectura por entorno | Sistemas | Ninguna | < 1 jornada |
| 2 | Denegar acceso directo a tablas con datos personales | Sistemas | Ninguna | incluido en 1 |
| 3 | **Decidir opción de redacción** entre A-F | **Sistemas** | según opción | — |
| 4 | Implantar la opción elegida | Sistemas | según opción | 1-5 jornadas |
| 5 | Entregar credencial de `RS_AGENTE` a Desarrollo | Sistemas | — | — |
| 6 | Activar registro de acceso de `RS_AGENTE` | Sistemas | Ninguna (§3.4) | 1 jornada |
| 7 | Entregar el inventario de columnas con datos personales | **Desarrollo** | — | ver §6 |

Los puntos 1 y 2 **no dependen de la decisión del punto 3** y pueden ejecutarse de
inmediato. El punto 7 lo aporta Desarrollo: la medida provisional descrita en §4
genera ese inventario como subproducto, de modo que Sistemas no parte de cero y
trabaja sobre un alcance cerrado.

---

## 4. Medida provisional (Desarrollo)

Mientras no exista el control en BD, el plugin filtrará los resultados antes de que
entren en el contexto de la conversación.

### 4.1 Funcionamiento

Se enmascara en el punto donde la herramienta recibe el resultado de la consulta,
antes de convertirlo a texto. El valor se sustituye por un pseudónimo determinista
(HMAC-SHA256 con clave local, truncado):

```
IDDEUDOR | NOMBRE        | DNI           | SALDO
---------+---------------+---------------+--------
1024     | pii:3f9a2c1b  | pii:7e04dd51  | 1250.00
1025     | pii:c8b17ff2  | pii:11a6b930  |  340.50
1026     | pii:3f9a2c1b  | pii:7e04dd51  |  980.00   <- misma persona, detectable
```

La clave reside en el perfil local del desarrollador, fuera del repositorio.

### 4.2 Qué se considera dato personal

Reglas evaluadas en cada consulta, sin necesidad de anotar el modelo por adelantado:

| Regla | Resultado |
|---|---|
| Marca explícita en la columna del modelo de BD | Manda sobre todo lo demás |
| Nombre de columna con patrón sensible (`TELEFON*`, `DNI*`, `*IBAN*`, `EMAIL*`…) | Enmascarado |
| Tabla paramétrica (idiomas, controles, versiones, módulos) | En claro |
| Tipo numérico, fecha, clave primaria o ajena | En claro |
| Resto de columnas de texto | Enmascarado |
| Columna que no se puede resolver (alias, expresión calculada) | Depende de la forma de los valores devueltos — ver debajo |

Las tablas paramétricas se toman de la lista que el modelo de BD ya mantiene para el
instalador de cliente, de modo que no hay una segunda lista que sincronizar.

**Columna que no se puede resolver.** Un alias o una expresión calculada (`COUNT(*) AS TOTAL`,
`SUBSTR(DNI,1,8) AS X`) no tiene definición en el modelo de BD, así que ninguna de las reglas
anteriores aplica. En ese caso se decide por la **forma de los valores devueltos**, en dos pasos:

1. Primero se pasa el mismo detector de forma del §4.3 (DNI, NIE, IBAN, correo, teléfono,
   tarjeta). Si la mayoría de los valores tiene alguna de esas formas, se enmascara ahí mismo —
   es lo que le pasa a `SUBSTR(DNI,1,8) AS X`: ocho dígitos sin letra tienen la forma de un DNI
   sin su letra de control.
2. Si no se detecta ninguna forma personal, se aplica una prueba numérica **estricta**: valores
   limpios (sin signo `+`, sin notación `inf`/`nan`, sin separadores de miles, y sin ser un
   entero de 9 o más dígitos sin parte decimal —la forma de un teléfono, una cuenta, un contrato
   o una tarjeta— aunque en teoría pudiera ser un recuento real por encima de esa magnitud)
   salen **en claro**; cualquier otra cosa —texto, o un entero largo sin decimales— se
   **enmascara**. Una muestra completamente vacía también se enmascara: no hay información para
   decidir a favor de dejarla en claro.

Así `SELECT COUNT(*) AS TOTAL` sigue devolviendo un número útil sin pasar por el modelo. Este
comportamiento es una decisión deliberada, no una tabla estática.

### 4.3 Detección de lo que las reglas no cubren

Sobre los valores que salen **en claro** se pasa un detector de patrones (DNI/NIE,
IBAN, correo, teléfono, tarjeta). Si un valor de una columna considerada segura
coincide, se avisa y —en modo estricto— se enmascara:

```
RDEUDORES.NUM1 -> 12 de 200 valores con forma de teléfono móvil
   => columna reclasificada como sensible; revisar
```

Este detector es también el que produce el **inventario de columnas con datos
personales** que Sistemas necesita para el paso 3.2. El trabajo no se duplica.

### 4.4 Despliegue por fases

La medida se despliega apagada y se activa de forma controlada, para no romper de
golpe los diez agentes que consultan datos:

| Modo | Comportamiento |
|---|---|
| `off` | Comportamiento actual. Aviso visible en cada consulta. |
| `audit` | Datos en claro + informe de qué se habría enmascarado. **No protege.** |
| `enforce` | Enmascarado activo. |

---

## 5. Límites de la medida provisional

Esta sección es deliberadamente explícita. Presentar la medida provisional como
equivalente al control en BD sería incorrecto y no resistiría una revisión.

### 5.1 Lo que sí protege

- Consultas realizadas a través de la herramienta de consulta del plugin.
- Los ficheros que la herramienta genera y el registro interno de ejecuciones.

### 5.2 Lo que no protege

**a) El dato sale de la base de datos.** El motor sigue emitiendo el valor en claro;
el filtro actúa después. Cualquier fallo, error de configuración o ruta no prevista
lo expone. El control en BD no tiene esta propiedad.

**b) Es evitable.** El agente dispone de acceso a línea de comandos y puede invocar
`sqlplus` o `sqlcmd` directamente. Existirá un bloqueo por patrón de comando, pero es
un **guardarraíl frente al descuido, no una frontera de seguridad**: se elude
escribiendo un script intermedio o invocando el binario por otra vía. La única
frontera real para este vector es la credencial del paso 3.1.

**c) La condición del filtro se puede consultar.** Aunque el valor salga enmascarado,
una consulta puede interrogarlo en la cláusula `WHERE`:

```sql
SELECT COUNT(*) FROM RDEUDORES WHERE DNI LIKE '1234%';   -- 3
SELECT COUNT(*) FROM RDEUDORES WHERE DNI LIKE '12345%';  -- 1
```

El recuento es numérico y sale en claro por diseño. Repitiendo la consulta se
reconstruye el valor sin haber visto nunca un dato enmascarado. Con vistas redactadas
esto no ocurre, porque la columna original no está expuesta a la sesión.

**d) El pseudónimo sigue siendo dato personal.** Conforme al art. 4(5) del RGPD, la
seudonimización **reduce** el riesgo pero no excluye el dato del ámbito de la norma.
`pii:3f9a2c1b` continúa siendo dato personal y continúa transfiriéndose al proveedor
externo. Si el requisito es que el dato personal **no salga en claro**, la medida lo
cumple. Si el requisito es que **no salga**, no lo cumple: eso exige supresión total
o el control en BD.

**e) Depende de configuración local no versionada.** Parte de las guardas se registran
en la configuración personal de Claude Code de cada desarrollador, que no viaja con el
repositorio. Un equipo nuevo sin configurar queda desprotegido. Se mitiga con una
verificación de entorno que falla si no están registradas, pero sigue siendo una
dependencia de puesto de trabajo.

**f) Una columna marcada como segura por error no se detecta.** Nombres, apellidos y
direcciones no tienen patrón reconocible. Si alguien los declara seguros, ninguna
comprobación automática lo advierte. Solo lo detecta la revisión del cambio en el
control de versiones.

### 5.3 Fuera del alcance técnico

- **Ficheros de entrega al cliente.** El instalador vuelca las tablas paramétricas
  reales, por diseño. Si alguna contiene datos de empleados (gestores, usuarios), esos
  datos van al fichero de entrega. Es un tratamiento legítimo pero debe constar.
- **Encargo de tratamiento.** La transferencia al proveedor de IA requiere el acuerdo
  correspondiente y su reflejo en el registro de actividades de tratamiento. Es una
  cuestión contractual, no técnica, y no la resuelve ninguna medida de este documento.

---

## 6. Inventario de columnas afectadas

Pendiente de generar. Se obtendrá ejecutando la medida provisional en modo `audit`
sobre cada solución, lo que produce la lista de tablas y columnas con datos personales
en el formato que Sistemas necesita para implantar la opción que elija en §3.2,
cualquiera que sea.

Formato previsto:

| Solución | Tabla | Columna | Tipo | Categoría | Tratamiento propuesto |
|---|---|---|---|---|---|
| | | | | Identificativo / Contacto / Financiero | Pseudónimo / Supresión |

**Se entregará antes de solicitar el trabajo del paso 3.2**, para que Sistemas
trabaje sobre un alcance cerrado y no sobre una estimación.

---

## 7. Plan propuesto

| Fase | Acción | Responsable | Dependencia |
|---|---|---|---|
| 1 | Implantar la medida provisional en modo `audit` | Desarrollo | — |
| 2 | Generar el inventario de §6 | Desarrollo | Fase 1 |
| 3 | Activar modo `enforce` | Desarrollo | Fase 2 |
| 4 | Crear usuario `RS_AGENTE` y denegar acceso directo | Sistemas | — |
| 5 | **Decidir la opción de redacción** (§3.2) | Sistemas | — |
| 6 | Implantar la opción elegida | Sistemas | Fases 2, 4 y 5 |
| 7 | Repuntar el plugin a la credencial `RS_AGENTE` | Desarrollo | Fase 6 |
| 8 | Reducir la medida provisional a segunda capa | Desarrollo | Fase 7 |

Las fases 1-3 (Desarrollo) y las fases 4-5 (Sistemas) son independientes y pueden
avanzar en paralelo. La fase 4 no depende de la decisión de la fase 5 y **puede
iniciarse de inmediato**: es la de mayor efecto por unidad de esfuerzo, porque sin
ella ninguna de las opciones de §3.2 es efectiva.

---

## 8. Conclusión

La medida provisional reduce la exposición de forma sustancial y es lo mejor
disponible sin intervención en base de datos, pero **actúa después de que el dato
haya salido del motor** y es evitable por varias vías documentadas en §5.2.

El control efectivo consta de dos piezas: un **usuario de solo lectura sin acceso
directo** a las tablas con datos personales (§3.1) y un **mecanismo de redacción en el
motor** (§3.2). Existen seis opciones para la segunda pieza, con y sin coste de
licencia, comparadas en §3.3. Desarrollo las expone todas y **no recomienda ninguna**:
la elección depende de las licencias contratadas y del presupuesto, información que
Desarrollo no posee.

Se solicita a Sistemas:

1. **Ejecutar de inmediato** la creación del usuario dedicado y la denegación de acceso
   directo (§3.1). No depende de ninguna decisión pendiente, cuesta menos de una jornada
   y sin ello ninguna otra medida es efectiva.
2. **Decidir la opción de redacción** entre las seis de §3.2, verificando previamente si
   ya se dispone de Oracle Enterprise Edition y de la opción Advanced Security —en cuyo
   caso la opción D estaría disponible sin coste incremental.
3. **Fijar una fecha objetivo** para la implantación, que Desarrollo necesita para
   dimensionar hasta cuándo debe sostenerse la medida provisional.

Desarrollo se compromete a entregar el inventario cerrado de columnas afectadas (§6)
antes de que Sistemas inicie el trabajo del punto 2.
