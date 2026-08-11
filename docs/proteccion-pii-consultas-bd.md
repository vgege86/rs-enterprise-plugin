# Protección de datos personales en consultas a BD desde herramientas de IA

**Fecha:** 2026-08-05 (rev. 1.3 — inventario entregado y medida en `enforce` en la 1.ª solución)
**Ámbito:** Soluciones uCollect/RS consultadas mediante el plugin `rs-enterprise-agent`
**Destinatario:** Departamento de Sistemas / Administración de Bases de Datos
**Estado:** Medida provisional **activa** en la primera solución (inventario entregado);
petición de control definitivo pendiente de decisión de Sistemas

---

## 1. Resumen ejecutivo

Las herramientas de desarrollo asistido por IA que usamos ejecutan consultas `SELECT`
contra las bases de datos de las soluciones uCollect/RS y **envían el resultado íntegro
a un proveedor externo** (Anthropic) como parte del contexto de la conversación.

Sin ningún filtro por medio, eso incluye columnas con datos personales: nombres, DNI,
teléfonos, direcciones, correos y números de cuenta de personas deudoras. Es la situación de
partida, y sigue siendo la de toda solución donde la medida provisional no esté activa.

Este documento pide a Sistemas el control que resuelve el problema de raíz —
**que la base de datos no emita esos datos** — y describe la medida provisional que
Desarrollo **ya ha implantado** mientras tanto, junto con lo que esa medida **no** puede
proteger.

**Estado a fecha de esta revisión.** La medida provisional está **activa en la primera
solución**, con el inventario de columnas afectadas ya generado y entregado (§6). Todo lo que
esta petición hacía depender de Desarrollo está hecho para esa solución; lo que falta para el
control definitivo son decisiones de Sistemas (§7). En el resto de soluciones el despliegue
sigue pendiente.

En §3 se presentan **todas** las opciones técnicas disponibles, con y sin coste de
licencia, en igualdad de condiciones. Desarrollo no tiene visibilidad sobre las
licencias contratadas ni sobre el presupuesto: **la elección corresponde a Sistemas.**

**Punto de partida verificado.** En la instalación comprobada, el plugin ya conecta con un
usuario de consulta que **no es el propietario** del esquema consultado: son dos principales
distintos. Eso significa que los mecanismos de redacción del §3.2 **sí pueden aplicarse a la
credencial que ya está en uso**, y que el trabajo del §3.1 se reduce a reapuntar sus permisos
en lugar de crear un usuario nuevo. La comprobación está hecha sobre **una sola instalación**:
**se pide a Sistemas que confirme si vale igual para el resto de proyectos y entornos** (§2.4).

**Hay una pregunta previa que decide el alcance de todo lo demás** y que solo Sistemas
puede responder: **¿ese usuario de consulta lo utiliza algo más aparte de las
herramientas de desarrollo?** De la respuesta depende que baste con reapuntar permisos
o que haya que crear un usuario dedicado (pregunta previa del §3).

| | Control definitivo (Sistemas) | Medida provisional (Desarrollo) |
|---|---|---|
| Dónde actúa | En el motor de BD | En la herramienta, tras recibir el dato |
| ¿Se puede eludir? | No | Sí (ver §5.2) |
| Coste de licencia | Según opción elegida (§3.2) | Ninguno |
| Esfuerzo | Entre 1 y 5 jornadas de DBA según la opción, más unas horas de reapuntado de permisos (§3.1) | Estimado 8-12 jornadas de desarrollo |
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

Así es el camino **sin** la medida provisional, y es el que sigue vigente en las soluciones
donde todavía no está activa: ningún punto intermedio inspecciona ni filtra los valores. Donde
la medida sí está activa (§6), se interpone entre el resultado y el contexto — con los límites
del §5, que no son menores: el dato **ya ha salido del motor**.

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

### 2.4 El usuario de conexión actual: qué habilita y qué no protege

En la instalación verificada —la única comprobada al redactar este documento— el plugin
**no conecta con el propietario del esquema**. La conexión declarada en su configuración usa
un usuario de consulta, `<USUARIO_CONSULTA>`, mientras que el esquema consultado es
`<ESQUEMA>`: son dos principales distintos.

Conviene decirlo con precisión, porque cambia qué medidas son aplicables:

- En **Oracle**, un usuario que no es el propietario **no disfruta del acceso
  automático** del dueño a sus propias tablas, que es lo que anula cualquier redacción.
  Las políticas de las opciones C y D, y el esquema de vistas de la opción A, pueden
  por tanto surtir efecto sobre él.
- En **SQL Server**, siempre que ese usuario **no pertenezca a `db_owner`**, no
  conserva el privilegio `UNMASK`, de modo que el enmascarado de la opción B también
  le aplica.

Dicho de otro modo: los mecanismos del §3.2 **sí pueden** actuar sobre la credencial
que ya se usa. No hace falta crear un usuario para desbloquearlos.

**La advertencia sigue en pie, reformulada.** La propiedad que protege no es «ser de
solo lectura», es **«no poder llegar a la columna original»**. Son cosas distintas y se
confunden con facilidad:

- Un usuario de solo lectura con `SELECT` sobre la tabla base **sigue devolviendo el
  DNI en claro**. No poder escribir no es no poder leer.
- Mientras ese `SELECT` directo exista, una vista redactada (opción A) es un rodeo
  voluntario: nada impide que la consulta vaya a la tabla en lugar de a la vista.

Por eso el §3.1 no pide crear un usuario, sino **quitarle a este el camino directo a las
tablas con datos personales** y dejarle únicamente el que pasa por el mecanismo de
redacción que se elija.

**Alcance de esta comprobación.** Lo anterior está verificado **únicamente** sobre una
instalación. Este documento **no puede afirmar** que ocurra lo mismo en el resto de proyectos
ni en el resto de entornos (desarrollo, test, producción) de ese mismo proyecto: Desarrollo no
tiene visibilidad sobre cómo se dieron de alta esas credenciales. **Se pide a Sistemas que lo confirme entorno por entorno.** Allí donde la
conexión sí sea la del propietario del esquema, la advertencia original se mantiene
íntegra: mientras se use esa credencial ninguna opción del §3.2 es efectiva, y lo
primero es sustituirla.

---

## 3. Control definitivo: petición a Sistemas

**PREGUNTA PREVIA — ¿el usuario de consulta es exclusivo de Desarrollo?**

**Esta es la pregunta que decide cuál de los dos caminos de esta sección se aplica, y
Desarrollo no puede responderla.** Se pide a Sistemas que la conteste antes que
cualquier otra cosa.

> **¿El usuario de conexión de las herramientas de desarrollo —`<USUARIO_CONSULTA>`— lo
> utiliza algo más? ¿Informes, procesos batch, integraciones, alguna aplicación, tareas
> programadas, cuadros de mando?**

| Respuesta | Consecuencia |
|---|---|
| **Es exclusivo de las herramientas de desarrollo** | El paso 3.1 está prácticamente hecho: el usuario ya existe y ya no es propietario. Solo queda reapuntar sus permisos y elegir el mecanismo de redacción del §3.2. Es el camino corto y es cuestión de horas. |
| **Lo comparten otros consumidores** | Revocarle el `SELECT` sobre las tablas de deudores **los rompe todos a la vez**. Y lo que sucede después es previsible: se restituye el permiso para recuperar el servicio y con él desaparece la protección. En ese caso hay que crear un usuario dedicado **antes** de tocar permisos, como se describe al final del §3.1. |

El segundo escenario es el que conviene anticipar: una protección que se retira bajo
presión operativa a las pocas horas de implantarse no es una protección, y deja además
la impresión de que el problema ya está resuelto.

La pregunta se plantea por entorno y por proyecto, junto con la del §2.4.

### 3.1 Paso 1 — Reapuntar los permisos del usuario de consulta (imprescindible)

El objetivo de este paso no es disponer de una credencial nueva: es **que la credencial
con la que conectan las herramientas no tenga camino directo a las columnas con datos
personales**. En la instalación verificada esa credencial ya existe y ya no es la del
propietario (§2.4), de modo que el trabajo se reduce a reapuntar sus permisos.

> **Notación.** `<USUARIO_CONSULTA>` designa el usuario de conexión de las herramientas de
> desarrollo en el entorno de que se trate, y `<ESQUEMA>` el esquema consultado. Este
> documento no nombra proyectos, esquemas ni credenciales concretos: los valores reales de
> cada entorno acompañan a este documento por el canal correspondiente, no dentro de él.

La forma concreta depende del mecanismo que se elija en §3.2, y son dos familias:

- **Opción A (vistas redactadas):** hay que **revocar** el `SELECT` sobre las tablas
  base y **conceder** el `SELECT` sobre las vistas.
- **Opciones B, C y D (redacción sobre la propia tabla):** el `SELECT` sobre la tabla
  base **se conserva** —es por donde llega el dato ya redactado— y lo que hay que
  garantizar es que el usuario **no tenga el privilegio que elude la redacción**.

**Oracle**

```sql
-- El usuario ya existe: NO hay que crearlo.
-- Comprobación previa: que no sea el propietario del esquema y que no arrastre
-- privilegios que anulen cualquier redacción.
SELECT * FROM DBA_ROLE_PRIVS WHERE GRANTEE = '<USUARIO_CONSULTA>';
SELECT * FROM DBA_SYS_PRIVS  WHERE GRANTEE = '<USUARIO_CONSULTA>'
   AND PRIVILEGE IN ('SELECT ANY TABLE',
                     'EXEMPT ACCESS POLICY',
                     'EXEMPT REDACTION POLICY');

-- Con la Opción A (vistas redactadas): quitar el camino directo…
REVOKE SELECT ON <ESQUEMA>.RDEUDORES FROM <USUARIO_CONSULTA>;
--   …una sentencia por cada tabla base con datos personales (inventario del §6)…

-- …y dejar solo el que pasa por la vista:
GRANT SELECT ON <ESQUEMA>.V_RDEUDORES TO <USUARIO_CONSULTA>;

-- Con las Opciones C o D no se revoca el SELECT de la tabla base: basta con
-- asegurar que el usuario NO tiene EXEMPT ACCESS POLICY ni EXEMPT REDACTION POLICY.
```

**SQL Server**

```sql
-- Comprobación previa: que no pertenezca a db_owner. Si perteneciera, conserva
-- UNMASK y ningún enmascarado le aplica.
SELECT r.name AS rol
  FROM sys.database_role_members m
  JOIN sys.database_principals  r ON r.principal_id   = m.role_principal_id
  JOIN sys.database_principals  u ON u.principal_id   = m.member_principal_id
 WHERE u.name = '<USUARIO_CONSULTA>';
-- ALTER ROLE db_owner DROP MEMBER <USUARIO_CONSULTA>;   -- solo si figura

DENY UNMASK TO <USUARIO_CONSULTA>;   -- necesario para que la Opción B aplique

-- Con la Opción A (vistas redactadas):
REVOKE SELECT ON dbo.RDEUDORES   FROM <USUARIO_CONSULTA>;
GRANT  SELECT ON dbo.V_RDEUDORES TO   <USUARIO_CONSULTA>;
```

**Si el usuario resultase estar compartido (pregunta previa del §3), este paso cambia:** entonces sí hay
que crear un usuario dedicado por entorno, sin privilegios administrativos y sin
`SELECT` directo sobre las tablas con datos personales (`CREATE USER` + `GRANT CREATE
SESSION` en Oracle; `CREATE LOGIN`/`CREATE USER` sin `db_owner` ni `db_datareader` en
SQL Server), y entregar su credencial a Desarrollo para reapuntar el plugin. Un usuario
dedicado sigue siendo la respuesta correcta en ese escenario, y también si se prefiere
poder auditar por separado el acceso de las herramientas.

- **Coste de licencia:** ninguno.
- **Esfuerzo:** menos de media jornada si el usuario es exclusivo de Desarrollo; menos
  de una jornada si hay que crear uno dedicado.
- **Efecto por sí solo:** ninguno hasta completar el paso 2, pero **sin este paso
  ninguna otra medida es efectiva**.
- **Orden:** con la Opción A conviene ejecutar el `REVOKE` y el `GRANT` en la misma
  ventana. Revocar antes de que existan las vistas deja las herramientas sin acceso a
  esas tablas —un estado seguro, pero inoperante.

### 3.2 Paso 2 — Redacción en el motor

Se recogen a continuación **todas** las opciones evaluadas, con y sin coste de
licencia. Ninguna se descarta desde Desarrollo: se exponen con sus requisitos,
ventajas e inconvenientes para que Sistemas decida en función de las licencias
contratadas y del presupuesto disponible.

Todas ellas requieren previamente el paso 3.1. La comparativa resumida está en §3.3.

#### Opción A — Vistas redactadas (Oracle y SQL Server, coste cero, cualquier edición)

Se crea una vista por cada tabla con datos personales. La vista devuelve las columnas
no sensibles tal cual y sustituye las sensibles por un valor sin capacidad
identificativa. El usuario de consulta recibe permiso **solo sobre la vista**.

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

GRANT SELECT ON V_RDEUDORES TO <USUARIO_CONSULTA>;
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
    expression    => 'SYS_CONTEXT(''USERENV'',''SESSION_USER'') = ''<USUARIO_CONSULTA>''');
END;
/
```

- **Requisito:** Oracle Enterprise Edition **+ opción Advanced Security** (de pago,
  licenciada por procesador o por usuario nombrado).
- **Ventaja:** es la opción más completa y la de menor esfuerzo de implantación y
  mantenimiento; no requiere vistas ni cambios en la aplicación; el redactado se
  aplica por expresión, de modo que la misma tabla puede verse íntegra por la
  aplicación de producción y redactada por el usuario de consulta.
- **Inconveniente:** coste de licencia. Los usuarios con `EXEMPT REDACTION POLICY` la eluden.
- **Nota:** Advanced Security incluye también TDE. Si ya está contratada por ese
  motivo, Data Redaction está disponible sin coste incremental — **conviene verificarlo
  antes de descartarla**.

#### Opción E — SQL Server Always Encrypted (sin coste, alto impacto en la aplicación)

Cifra la columna de extremo a extremo; la clave reside en el cliente y el motor nunca
ve el valor en claro. Un cliente sin la clave —como sería el usuario de consulta— recibe solo
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
| **A** Vistas redactadas | Oracle y SQL Server | Cualquiera | No | 3-4 jornadas | Ninguno (solo el usuario de consulta) | Sí |
| **B** Dynamic Data Masking | SQL Server | 2016 SP1, cualquiera | No | 1-2 jornadas | Ninguno | No |
| **C** VPD column-masking | Oracle | **Enterprise** | No, incluida en EE | 2-3 jornadas | Ninguno | No |
| **D** Data Redaction | Oracle | **Enterprise** | **Sí — Advanced Security** | 1-2 jornadas | Ninguno | Configurable |
| **E** Always Encrypted | SQL Server | 2016 SP1, cualquiera | No | 5+ jornadas | **Alto — requiere cambios** | Solo determinista |
| **F** Producto de terceros | Ambos | — | **Sí — según producto** | Proyecto | Variable | Sí |

Todas las opciones exigen el paso 3.1 (reapuntar los permisos del usuario de consulta,
o crear uno dedicado si el actual está compartido). Sin él, ninguna es efectiva.

### 3.4 Paso 3 — Registro de acceso (recomendado, no bloqueante)

Auditoría de las conexiones del usuario de consulta para poder acreditar qué se
consultó y cuándo. Si ese usuario está compartido con otros consumidores (pregunta previa del §3), la
auditoría no distingue quién hizo cada consulta: es un argumento adicional a favor de
un usuario dedicado.

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
| 1 | **Responder la pregunta previa del §3**: ¿el usuario de consulta es exclusivo de las herramientas de desarrollo? Y confirmar, entorno por entorno, que la conexión no es la del propietario del esquema (§2.4) | **Sistemas** | Ninguna | Consulta, no desarrollo |
| 2 | Reapuntar los permisos de ese usuario: quitarle el camino directo a las tablas con datos personales y dejarle solo el del mecanismo elegido (§3.1). Si el usuario está compartido, crear antes uno dedicado | Sistemas | Ninguna | < 1/2 jornada (< 1 jornada si hay que crear usuario) |
| 3 | **Decidir opción de redacción** entre A-F | **Sistemas** | según opción | — |
| 4 | Implantar la opción elegida | Sistemas | según opción | 1-5 jornadas |
| 5 | Confirmar a Desarrollo que la credencial en uso es la definitiva, o entregar la nueva si se ha creado un usuario dedicado | Sistemas | — | — |
| 6 | Activar registro de acceso del usuario de consulta | Sistemas | Ninguna (§3.4) | 1 jornada |
| 7 | Entregar el inventario de columnas con datos personales | **Desarrollo** | — | ✅ hecho para la 1.ª solución (§6); pendiente en el resto |

El punto 1 **no depende de ninguna decisión pendiente** y puede resolverse de inmediato:
es una consulta al alta de credenciales, no un desarrollo. El punto 2 depende
parcialmente del punto 3 —qué se revoca y qué se concede lo determina el mecanismo
elegido—, salvo la creación del usuario dedicado, que si procede puede acometerse ya. El
punto 7 lo aporta Desarrollo: la medida provisional descrita en §4 genera ese inventario
como subproducto, de modo que Sistemas no parte de cero y trabaja sobre un alcance
cerrado.

---

## 4. Medida provisional (Desarrollo)

Mientras no exista el control en BD, el plugin filtra los resultados antes de que
entren en el contexto de la conversación. Está implantado y activo en la primera solución.

### 4.1 Funcionamiento

Se enmascara en el punto donde la herramienta recibe el resultado de la consulta,
antes de convertirlo a texto. El valor se sustituye por un pseudónimo determinista
(HMAC-SHA256 con clave local, truncado):

```
IDDEUDOR | NOMBRE            | DNI               | SALDO
---------+-------------------+-------------------+--------
1024     | pii:3f9a2c1b40de  | pii:7e04dd51a6c2  | 1250.00
1025     | pii:c8b17ff29b31  | pii:11a6b930f4e8  |  340.50
1026     | pii:3f9a2c1b40de  | pii:7e04dd51a6c2  |  980.00   <- misma persona, detectable
```

La clave reside en el perfil local del desarrollador, fuera del repositorio.

El dominio del pseudónimo es el **nombre de la columna**, no la tabla, de modo que la
correlación que ilustra el ejemplo no se limita a un resultado: el mismo valor devuelve el
mismo pseudónimo en cualquier consulta y en cualquier tabla donde la columna se llame igual.
Esa propiedad es deliberada —es la que permite unir las filas de una misma persona, contar
distintos y detectar duplicados sin ver ningún dato personal—, y es también la que distingue
esta medida de un enmascarado dinámico de servidor (§3.2, Opción B), que al no ser determinista
inutiliza cualquier cruce. Su contrapartida: dos columnas homónimas con significados distintos
comparten dominio, y un pseudónimo no es comparable entre máquinas, porque la clave es local.

### 4.2 Qué se considera dato personal

Reglas evaluadas en cada consulta, sin necesidad de anotar el modelo por adelantado:

| Regla | Resultado |
|---|---|
| Marca explícita en la columna del modelo de BD | Manda sobre el resto de reglas de esta tabla |
| Nombre de columna con patrón sensible (`TELEFON*`, `DNI*`, `*IBAN*`, `EMAIL*`…) | Enmascarado |
| Tabla paramétrica (idiomas, controles, versiones, módulos) | En claro |
| Tipo numérico, fecha, clave primaria o ajena | En claro |
| Resto de columnas de texto | Enmascarado |
| Columna que no se puede resolver (alias, expresión calculada) | Depende de la forma de los valores devueltos — ver debajo |

Las tablas paramétricas se toman de la lista que el modelo de BD ya mantiene para el
instalador de cliente, de modo que no hay una segunda lista que sincronizar.

**Lo único que puede revertir una marca explícita** es el detector de forma de valor del
§4.3: una columna declarada segura cuyos valores tengan forma de dato personal se
enmascara igualmente. Es la única excepción y va siempre en la dirección segura —nunca al
revés—, porque el modelo de BD lo mantienen personas y una marca equivocada no debe poder
abrir un agujero permanente. Si salta sobre una columna que se sabe segura (un
identificador interno de ocho dígitos, una referencia con forma de IBAN), lo procedente es
comprobar el contenido real de la columna; si efectivamente es un falso positivo, la
salida es no devolver esa columna en bruto en la consulta o asumir el enmascarado. No
existe una marca de "en claro pase lo que pase", y es deliberado.

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
IBAN, correo, teléfono, tarjeta). Si los valores de una columna considerada segura
coinciden, la columna se **reclasifica como sensible** —se enmascara igualmente en modo
estricto— y se añade a la lista `suspect` que acompaña a cada resultado:

```
pii.suspect = ["NUM1"]
   => columna en claro con valores con forma de dato personal; enmascarada y pendiente de revisar
```

La lista es de **nombres de columna**: ni el aviso ni ningún otro punto del sistema
reproduce un valor detectado. La herramienta tiene instrucción explícita de trasladar
esa lista al usuario en la respuesta de la consulta, no de tratarla como información
interna. Para el detalle por columna (categoría detectada y cuántos valores de la
muestra coinciden) está el inventario del §6, que se genera muestreando a propósito.

Este detector es también el que produce el **inventario de columnas con datos
personales** que Sistemas necesita para el paso 3.2. El trabajo no se duplica.

### 4.4 Despliegue por fases

La medida se despliega apagada y se activa de forma controlada, para no romper de
golpe los diez agentes que consultan datos:

| Modo | Consultas | Guardas (cliente de BD directo, escritura a fichero) |
|---|---|---|
| `off` | Datos en claro. Cada consulta lo indica (`pii.mode = "off"`), sin advertencia adicional | **No bloquean** |
| `audit` | Datos en claro + informe de qué se habría enmascarado. **No protege** | Bloquean |
| `enforce` | Enmascarado activo | Bloquean |

**El modo es del workspace, y las guardas lo siguen.** Desde la versión 3.3.0 las dos guardas
—la que impide invocar el cliente de base de datos directamente y la que impide escribir un dato
personal en un fichero— consultan el modo del workspace al que pertenece cada operación, y no
actúan en `off`. Antes bloqueaban siempre, en cualquier proyecto del ordenador, estuviera el modo
donde estuviera.

Es lo que hace utilizable el planteamiento en un equipo de desarrollo: lo normal es tener la
protección apagada, y encenderla **solo en el workspace cuya base de datos contiene datos reales**.
Una operación que no cae dentro de ningún workspace uCollect/RS queda fuera del alcance del plugin y
no se bloquea. Con una excepción deliberada: dentro de un workspace cuyo modo **no se puede
determinar** —una política declarada que no se puede leer— las guardas sí actúan. Un workspace roto
no puede degradar en silencio a un workspace sin protección, que es el mismo criterio que ya aplica
el filtro de las consultas.

En `audit` las guardas bloquean aunque los datos aún salgan en claro: `audit` es la fase en la que
se mide un workspace que va a protegerse, y es justo cuando no interesa que se coja la costumbre de
rodear la herramienta.

**El modo se lee de la configuración de la solución, y no poder leerla no equivale a `off`.**
Si esa configuración declara dónde vive la política y ese fichero no está, o está y no se puede
interpretar, la consulta **no se ejecuta y no devuelve ninguna fila**: responde con un error que
nombra el fichero que falta e indica cómo regenerarlo. Se aplica por igual a las dos vías de
consulta del §5.2g. La alternativa —tratarlo como "no hay política"— haría que una solución
configurada en `enforce` con el fichero perdido devolviese los datos en claro y se anunciase
como una solución sin política declarada, indistinguible de una que nunca configuró nada.

Una solución que **nunca** ha declarado política sí conserva el comportamiento anterior
(`off`, datos en claro): esa es la situación ordinaria mientras el despliegue está en curso, y
distinguir las dos es justamente lo que evita que un fichero perdido pase por una decisión.

### 4.5 Qué camino pasa por el filtro

El filtro vive en **un solo sitio**: el punto donde la herramienta recibe las filas de una
consulta libre. Conviene decirlo explícitamente, porque el plugin habla con la base de datos por
más de un camino y no todos transportan datos de negocio.

**Pasa por el filtro:** la consulta libre —la que ejecuta un `SELECT` escrito para la ocasión— y
su vía de respaldo (§5.2g). Es el único camino por el que pueden salir filas de tablas de
negocio, y por tanto el único que necesita filtrarse.

**No pasa por el filtro:** las funciones que mantienen el **mapa del esquema** —sincronizar el
modelo de datos, comparar el modelo con la base real, leer índices, inferir relaciones, generar
DDL, dibujar el diagrama—. No es una omisión: esas funciones leen del **catálogo del sistema**
—nombres de tabla, de columna, tipos, longitudes, nullabilidad, índices— y del propio fichero de
modelo. Ahí no hay datos de personas: hay metadatos de la estructura. Filtrarlos no protegería
nada y dejaría el mapa inservible.

**La consecuencia práctica, y es contraintuitiva.** Si en lugar de usar esas funciones se
interroga el catálogo del sistema **con la consulta libre** (`ALL_TAB_COLUMNS`,
`INFORMATION_SCHEMA.COLUMNS`, `USER_OBJECTS`), el resultado sale **enmascarado** con la medida
activa: esas tablas no están en el modelo de datos, así que sus columnas caen en "no se puede
resolver" (§4.2) y sus valores son texto, no números. Los nombres de tabla y de columna vuelven
convertidos en pseudónimos.

No es un fallo del filtro sino su regla general aplicada a un caso donde sobra, y la decisión
consciente es **no** abrir una excepción: cada excepción es un camino más por el que una
consulta puede salir sin filtrar, y el rodeo es barato —para leer estructura están las funciones
de mapa del esquema, que no pasan por aquí—.

Si aun así hace falta cruzar estructura con la consulta libre, la salida es **preguntar por
números**: los nombres viajan dentro del `SELECT` y de vuelta solo vienen recuentos o códigos
numéricos, que salen en claro por la prueba del §4.2. Con dos cuidados: un entero de nueve o más
dígitos sin decimales se enmascara igual (tiene forma de identificador), y una columna que salga
entera vacía también.

---

## 5. Límites de la medida provisional

Esta sección es deliberadamente explícita. Presentar la medida provisional como
equivalente al control en BD sería incorrecto y no resistiría una revisión.

### 5.1 Lo que sí protege

- Consultas realizadas a través de la herramienta de consulta del plugin —y solo ese camino:
  las funciones que mantienen el mapa del esquema leen metadatos y no pasan por el filtro (§4.5).
- El contenido que la herramienta escribe **directamente** en un fichero: se inspecciona
  antes de escribirlo y se bloquea si contiene una forma de DNI/NIE, IBAN o correo.
- El registro interno de ejecuciones, que se sanea siempre.

Conviene ser preciso con el segundo punto: la inspección cubre las escrituras de fichero
que hace la herramienta *como tal*. **No** cubre los ficheros que generan los procesos
auxiliares del plugin —generación de DDL, paquetes de instalación y de actualización,
exportación del modelo, informes HTML y la propia escritura de la configuración de esta
medida—, que escriben en disco por otra vía. Esos artefactos se entregan al cliente por
diseño y pueden contener datos reales; su control es organizativo, no automático.

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

Lo único que hace la medida provisional aquí es **avisar**: cuando una consulta filtra
por una columna con datos personales, el resultado incluye esa columna en
`predicate_warning` y la herramienta tiene instrucción de trasladarlo al usuario. No se
bloquea —bloquear rompería el filtrado legítimo, que es la mitad del trabajo diario—, así
que el aviso deja constancia pero no impide la reconstrucción descrita arriba.

**d) El pseudónimo sigue siendo dato personal.** Conforme al art. 4(5) del RGPD, la
seudonimización **reduce** el riesgo pero no excluye el dato del ámbito de la norma.
`pii:3f9a2c1b40de` continúa siendo dato personal y continúa transfiriéndose al proveedor
externo. Si el requisito es que el dato personal **no salga en claro**, la medida lo
cumple. Si el requisito es que **no salga**, no lo cumple: eso exige supresión total
o el control en BD.

**e) Depende de que la herramienta esté instalada, no de configuración personal.**
*(Resuelto en la versión 3.4.0; se conserva el apartado porque describe una limitación real
durante la fase inicial y explica una decisión de diseño.)*

Durante las primeras versiones las guardas se registraban **a mano en la configuración
personal** de cada desarrollador, que no viaja con el repositorio. Eso traía tres problemas,
y el tercero era grave:

- Un puesto nuevo quedaba desprotegido en silencio hasta que alguien las registrara.
- Al ser configuración personal, aplicaban a **todos** los proyectos de esa persona, tuvieran
  o no que ver con estas soluciones.
- Y guardaban la **ruta absoluta** del script de cada guarda. El almacén local de la
  herramienta organiza cada versión en su propia carpeta, de modo que **cada actualización
  del plugin dejaba esas rutas apuntando a una carpeta que ya no existía**: la guarda se
  lanzaba, fallaba, y no bloqueaba nada, porque el código de error de un script que no se
  encuentra no es el que interrumpe la operación. Fallaba abierta, sin ninguna señal. Se
  comprobó sobre una instalación real: la ruta registrada apuntaba a la versión anterior.

Desde 3.4.0 las guardas las declara el **propio plugin**, con una variable que se resuelve a
la versión en curso. Se instalan, se actualizan y se retiran con él; no hay ruta que
envejezca, ni configuración personal que tocar, ni puesto que quede a medias. Las entradas
manuales que quedaran de antes se retiran solas al arrancar una sesión, con copia previa.

Queda una dependencia, menor y ordinaria: **si el plugin no está instalado, no hay guardas**.
Y una ventana: la herramienta resuelve los hooks al arrancar, así que un plugin recién
instalado o actualizado no las tiene vivas hasta reiniciar. La verificación de entorno
distingue las dos caras — si están **disponibles** (instalación) y si **bloquean aquí**
(modo del workspace, §4.4) — y comprueba además que el fichero de cada guarda exista, para no
poder declarar protegido lo que no lo está.

**f) Una columna marcada como segura por error no se detecta.** Nombres, apellidos y
direcciones no tienen patrón reconocible. Si alguien los declara seguros, ninguna
comprobación automática lo advierte. Solo lo detecta la revisión del cambio en el
control de versiones.

**g) La vía alternativa de consulta puede devolver datos sin filtrar.** Además de la
herramienta principal existe una vía de respaldo, que se usa cuando aquella no está
disponible. Si en ese camino el filtro **no se puede ni ejecutar** (falta el intérprete
o el fichero del filtro en el puesto), la consulta devuelve los datos **sin enmascarar**,
señalándolo en la respuesta. Es una decisión deliberada: dejar sin servicio la consulta
empujaría al desarrollador a usar el cliente de base de datos directamente, que no pasa
por ningún filtro y es peor. Es el único punto de la medida donde un componente capaz de
enmascarar decide no hacerlo. Si el filtro **sí se ejecuta** y falla —modelo corrupto,
política ilegible, error interno— la consulta **no devuelve ninguna fila**.

Las dos vías aplican la misma regla ante una política declarada que no se puede cargar: la
consulta falla y no devuelve filas (§4.4). Hasta la versión 3.1.0 la vía principal no lo hacía
—devolvía los datos en claro etiquetados como "sin política"—, que era la forma más silenciosa
que podía tomar el fallo descrito en el apartado (a).

### 5.3 Fuera del alcance técnico

- **Ficheros de entrega al cliente.** El instalador vuelca las tablas paramétricas
  reales, por diseño. Si alguna contiene datos de empleados (gestores, usuarios), esos
  datos van al fichero de entrega. Es un tratamiento legítimo pero debe constar.
- **Encargo de tratamiento.** La transferencia al proveedor de IA requiere el acuerdo
  correspondiente y su reflejo en el registro de actividades de tratamiento. Es una
  cuestión contractual, no técnica, y no la resuelve ninguna medida de este documento.

---

## 6. Inventario de columnas afectadas

**Generado para la primera solución**, y pendiente para el resto. Se obtiene ejecutando la
medida provisional en modo `audit` sobre cada solución, lo que produce la lista de tablas y
columnas con datos personales en el formato que Sistemas necesita para implantar la opción
que elija en §3.2, cualquiera que sea.

| Solución | Estado | Fichero |
|---|---|---|
| Primera solución desplegada | **Generado** — la medida está en `enforce` | `docs/inventario-pii.md` de su workspace |
| Resto de soluciones | Pendiente | — |

El inventario de cada solución **es un anexo, no parte de este documento**: contiene nombres
de tablas y columnas del cliente. Se entrega por separado, junto con la identificación del
proyecto al que corresponde.

Formato del fichero:

| Solución | Tabla | Columna | Tipo | Categoría | Tratamiento propuesto |
|---|---|---|---|---|---|
| | | | | Identificativo / Contacto / Financiero | Pseudónimo / Supresión |

Cada inventario se genera **muestreando valores reales**, de modo que recoge también las
columnas que el nombre no delata (§4.3). Ningún valor muestreado se reproduce en el fichero:
solo tabla, columna, categoría detectada y número de coincidencias.

El inventario de una solución **se entrega antes de solicitar el trabajo del paso 3.2 sobre
esa solución**, para que Sistemas trabaje sobre un alcance cerrado y no sobre una estimación.
Para la primera solución esa condición ya está cumplida.

---

## 7. Plan propuesto

Las fases 1-3 son **por solución**. Su estado en la primera solución es el que marca la
columna correspondiente; en el resto siguen pendientes.

| Fase | Acción | Responsable | Dependencia | 1.ª solución |
|---|---|---|---|---|
| 1 | Implantar la medida provisional en modo `audit` | Desarrollo | — | ✅ Hecho |
| 2 | Generar el inventario de §6 | Desarrollo | Fase 1 | ✅ Hecho |
| 3 | Activar modo `enforce` | Desarrollo | Fase 2 | ✅ Hecho |
| 4 | **Responder la pregunta previa del §3** y confirmar por entorno que la conexión no es la del propietario (§2.4) | Sistemas | — | ⏳ Pendiente |
| 5 | **Decidir la opción de redacción** (§3.2) | Sistemas | — | ⏳ Pendiente |
| 6 | Implantar la opción elegida y reapuntar los permisos del usuario de consulta (§3.1) | Sistemas | Fases 2, 4 y 5 | ⏳ Pendiente |
| 7 | Reapuntar el plugin a la credencial definitiva, solo si la fase 4 obliga a crear un usuario dedicado | Desarrollo | Fase 6 | — |
| 8 | Reducir la medida provisional a segunda capa | Desarrollo | Fase 7 | — |

Las fases 1-3 (Desarrollo) y las fases 4-5 (Sistemas) son independientes y pueden
avanzar en paralelo. La fase 4 no depende de la decisión de la fase 5 y **puede
resolverse de inmediato**: es la de mayor efecto por unidad de esfuerzo, porque
determina si el reapuntado de permisos del §3.1 basta o hay que crear antes un usuario
dedicado, y sin ese paso ninguna de las opciones de §3.2 es efectiva.

**Dónde está hoy el trabajo.** En la primera solución, todo lo que dependía de Desarrollo
está hecho: la medida está en `enforce` y el inventario entregado. La fase 6 ya solo espera a
las fases 4 y 5, que son de Sistemas y no dependen de nada nuestro. Conviene decirlo sin
rodeos porque cambia quién tiene la pelota: **el motivo de que el control definitivo no esté
implantado ya no es que falte el inventario.**

---

## 8. Conclusión

La medida provisional reduce la exposición de forma sustancial y es lo mejor
disponible sin intervención en base de datos, pero **actúa después de que el dato
haya salido del motor** y es evitable por varias vías documentadas en §5.2.

El control efectivo consta de dos piezas: un **usuario de conexión que no pueda llegar
a la columna original** de las tablas con datos personales (§3.1) y un **mecanismo de
redacción en el motor** (§3.2). La primera pieza está a medio camino: en la instalación
verificada la conexión ya usa un usuario de consulta que no es el propietario del esquema, de
modo que basta con reapuntar sus permisos en lugar de crear uno nuevo. Lo que sigue faltando
es que ese usuario **pierda el `SELECT` directo**: ser de solo lectura no impide
devolver un DNI en claro. Para la segunda pieza existen seis opciones, con y sin coste
de licencia, comparadas en §3.3. Desarrollo las expone todas y **no recomienda
ninguna**: la elección depende de las licencias contratadas y del presupuesto,
información que Desarrollo no posee.

Se solicita a Sistemas:

1. **Responder de inmediato la pregunta previa del §3** —si el usuario de consulta lo usa
   algo más que las herramientas de desarrollo— y confirmar, entorno por entorno, lo
   que §2.4 solo ha podido verificar en una instalación. No depende de ninguna decisión
   pendiente, no consume jornadas de desarrollo y determina si el §3.1 se resuelve
   reapuntando permisos o exige crear un usuario dedicado.
2. **Reapuntar los permisos** de ese usuario según el §3.1, de modo que pierda el acceso
   directo a las tablas con datos personales. Menos de media jornada si el usuario es
   exclusivo de Desarrollo; sin ello ninguna otra medida es efectiva.
3. **Decidir la opción de redacción** entre las seis de §3.2, verificando previamente si
   ya se dispone de Oracle Enterprise Edition y de la opción Advanced Security —en cuyo
   caso la opción D estaría disponible sin coste incremental.
4. **Fijar una fecha objetivo** para la implantación, que Desarrollo necesita para
   dimensionar hasta cuándo debe sostenerse la medida provisional.

El inventario cerrado de columnas afectadas (§6) **ya está entregado para la primera
solución**, con la medida provisional en `enforce` sobre ella. Para el resto de soluciones se
entregará antes de solicitar el trabajo del §3.2 sobre cada una, con el mismo criterio.

Dicho de otro modo: los puntos 1 y 2 de esta lista no dependen de nada que falte por nuestra
parte, y el 3 tampoco. Sobre la primera solución, lo único que separa hoy la medida
provisional del control definitivo son decisiones de Sistemas.
