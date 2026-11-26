# Reglas de Base de Datos

---

# 📥 Fuente de datos (CRÍTICO)

- **Esquema / tipos / columnas, para DESARROLLAR** → el modelo (`<proyecto>-model.json`, vía `search_model` / `get_model_index` / `get_table_schema`). Es rápido, no consume sesiones de BD y lleva las descripciones y las marcas PII.
- **Esquema, para ENTREGAR al cliente** → ⛔ **la BD, siempre**. Nunca el modelo. Ver abajo.
- **Datos / valores de fila** → siempre `db_query` directo contra la BD.
- ⛔ **NUNCA** leer ficheros `.sql` de la carpeta `BD\` (ni subcarpetas) como fuente de datos ni de esquema: pueden estar desactualizados. De `BD\` solo se usa `<proyecto>-model.json`.
- Si la BD no es accesible → informar y pedir acceso; no sustituir la BD por scripts de `BD\`.

## ⛔ Lo que se entrega sale de la BD, no del modelo

El modelo es una **traducción** de la BD, y la traducción es lossy. Medido en una entrega real:
12 FK → 0, 3 CHECK → 0, 1 IDENTITY → una columna `NUMBER` pelada, 22 DEFAULT → 21, cuatro
columnas con el tamaño de hace meses y 15 columnas `RAW` sin longitud (ORA-00906: el DDL
entregado no compilaba). **Ninguna de esas pérdidas da error al generar**; todas lo dan en el
servidor del cliente.

No se arregla sincronizando mejor el modelo: el problema no es que esté mal hoy, es que puede
estarlo cualquier día y nada lo delata.

| Artefacto | Fuente | Quién lo genera |
|---|---|---|
| DDL de tablas del instalador | **BD viva** (`ALL_*` / `sys.*`) | `scripts/installer-tablas.py` |
| Secuencias, vistas, PL/SQL, triggers, sinónimos | **BD viva** | `scripts/installer-objects.py` |
| Inserts de paramétricas | **BD viva** | `scripts/installer-inserts.py` |
| SQL de desarrollo (`/rs-erd`) | modelo | `scripts/generate-sql.py` |
| ERD, descripciones, marcas PII | modelo | — |

Si se detecta deriva modelo↔BD al generar, se **reporta** y no se bloquea: lo entregado sale de
la BD, que es la fuente. El modelo nunca manda sobre lo que viaja al cliente.

⛔ **`DBMS_METADATA.GET_DDL` no está disponible** y no hay que buscar la forma de usarlo: la
cuenta de entrega es de solo lectura por diseño de la política PII y no tiene
`SELECT_CATALOG_ROLE`, así que cualquier `GET_DDL` sobre otro esquema devuelve `ORA-31603:
object not found`. Todo el DDL se reconstruye desde el diccionario `ALL_*`, legible con
`GRANT SELECT`.

⛔ **Las descripciones y las marcas `pii`/`safe` son EXCLUSIVAS de desarrollo.** No viajan al
cliente, y eso no se da por supuesto: `scripts/installer-gate-fuga.py` revisa el paquete
generado y **falla la entrega** si aparece alguna.

---

# 👁️ "No lo veo" NO es "no existe" (CRÍTICO)

La cuenta de consulta de un proyecto **no suele ser la dueña del esquema**: ve por GRANT
per-object. Y Oracle **no da forma de distinguir las dos cosas** — ORA-00942 es deliberadamente
ambiguo, y `ALL_TABLES`, `ALL_OBJECTS`, `ALL_SOURCE`, `ALL_INDEXES` y `ALL_SEQUENCES` están
**todas** filtradas por privilegio. Un objeto sin GRANT no aparece en ningún sitio y no se
distingue de uno borrado.

- ⛔ **Nunca concluir que un objeto desapareció** porque una consulta no lo devolvió. La lectura
  honesta es "esta cuenta no lo ve".
- ⛔ **Nunca borrar ni degradar** una tabla, columna o índice del modelo por esa razón. Los hooks
  ya no lo hacen: conservan la tabla entera y la marcan `visible: false`.
- **Antes de decidir nada sobre el modelo, mirar `cobertura`** (la devuelven `sync_from_db`,
  `sync_indexes` y `sync_model_objects`; queda en `_cobertura` del modelo). Con
  `es_dueno: false` y hueco, la causa probable es un GRANT que falta.
- **El PL/SQL exige `GRANT EXECUTE`, no `SELECT`.** Con cero grants EXECUTE, `ALL_OBJECTS` y
  `ALL_SOURCE` devuelven **cero** procedimientos y paquetes **sin error**. Un "no hay
  procedimientos" con `EXECUTE: 0` en `cobertura.grants` no es un hecho, es una ceguera.
- **Los sinónimos PRIVADOS no los expone ningún GRANT**: solo se ven leyendo como dueño del
  esquema.

Para leer con otra cuenta, `conexion=<id>` en las tools y `-Conexion <id>` en los hooks —resuelve
contra `conexiones[]` de `.rs-databases.json`—. ⛔ **No** editar a mano el fichero de credenciales
para poner otra conexión la primera: eso es persistente, no queda registrado en ninguna salida y
arrastra consigo la política PII (el modelo se resuelve **por conexión**).

---

# 🔒 Datos personales en los resultados de `db_query`

`db_query` aplica la política de protección de datos personales del workspace y devuelve
siempre un bloque `pii`. **Ese bloque hay que leerlo y trasladar al usuario lo que traiga —
nunca ignorarlo en silencio.** Tabla completa de campos y de qué decir en cada caso:
`references/mcp.md` → "El bloque `pii` de `db_query`". En corto:

- `pii.error` / `pii.model_error` → el filtro **no** se aplicó. Avisar siempre. Con
  `model_error` la consulta viene además con `success: false` y cero filas: hay un modelo BD
  declarado que no se puede usar y el mensaje dice cómo generarlo (`/rs-init`, `/rs-erd`).
- `pii.suspect` → columnas en claro con valores con forma de dato personal. Nombrarlas.
- `pii.predicate_warning` → se está filtrando por una columna con datos personales; el valor
  se puede inferir aunque la salida vaya enmascarada. Avisar.
- `pii.mode` → `off` sin protección, `audit` **los datos salen en claro**, `enforce` activo.
  No decir "protegido" salvo con `enforce`.

⛔ Un valor `pii:xxxxxxxx` es un pseudónimo: no reproducirlo como si fuera el dato, y **no
rodear el filtro** (misma columna con otra expresión, `sqlplus`/`sqlcmd` directos). Si un dato
se necesita en claro, declarar la columna como segura en el modelo BD (`/rs-pii`).

## ✅ Los pseudónimos SÍ se pueden cruzar entre tablas

Enmascarado **no** significa inservible. El pseudónimo es determinista:
`HMAC(clave, NOMBRE_COLUMNA + valor)`. **El mismo valor devuelve siempre el mismo
`pii:xxxxxxxx`, en cualquier consulta y en cualquier tabla.** Es una propiedad de diseño, no un
accidente: sirve justamente para poder trabajar sin ver el dato.

Con eso se puede, sin desenmascarar nada:

- **Unir filas de la misma persona entre tablas** — si `pii:7e04dd51a6c2` sale en `TABLA_A.DNI`
  y en `TABLA_B.DNI`, es la misma persona. Un cruce válido para investigar una incidencia.
- **Contar distintos** (`COUNT(DISTINCT ...)` sobre el pseudónimo), detectar duplicados,
  verificar integridad referencial, comprobar si un alta llegó a las N tablas que debía.
- **Comparar entre entornos o entre consultas** dentro de la misma máquina.

⚠️ **La condición es el nombre de la columna de salida, no el de la tabla.** El dominio del HMAC
es el nombre con el que la columna **vuelve en el resultset**. `TABLA_A.DNI` ↔ `TABLA_B.DNI`
cruzan. `TABLA_A.DNI` ↔ `TABLA_B.NIF` **no** cruzan, aunque contengan el mismo dato — se alinean
con un alias: `SELECT NIF AS DNI ...`. Cuidado con el reverso: dos columnas con el mismo nombre y
significados distintos comparten dominio, así que un pseudónimo repetido entre ellas solo dice
"mismo texto", no "misma entidad".

⚠️ El cruce es por **coincidencia exacta** del valor normalizado (solo se colapsan los espacios).
Distinto casing, un acento de más o un formato distinto → pseudónimos distintos. Que dos no
cuadren **no** prueba que sean personas distintas.

⛔ Con `transform: "suppress"` (literal `[PII]`) no hay correlación posible: ahí sí se pierde.
⛔ La clave vive en el perfil local (`%LOCALAPPDATA%`). Un `pii:xxxxxxxx` **no es comparable entre
máquinas ni entre usuarios**: no vale como identificador estable en un ticket, un commit, un
informe ni una tabla de resultados que vaya a leer otra persona.

## La política es de `db_query`, no del plugin entero

`db_query` es la **única** tool que enmascara. Las que mantienen el modelo y leen estructura
—`sync_from_db`, `sync_indexes`, `compare_model`, `analyze_dalc`, `generate_sql`,
`generate_migration`, `export_dmd`, `render_erd`, `get_object_ddl`— van a su hook con conexión directa y no
importan `pii_*`; `get_table_schema`, `search_model` y `get_model_index` leen el
`model.json` y ni tocan la BD. Nombres de tabla, columna, vista, índice y objeto salen
**siempre en claro**, también con `mode=enforce`. (`sync-from-db.ps1` menciona `pii` solo para
**conservar** las marcas `pii`/`safe` que ya tenga el modelo al re-sincronizar.)

## Catálogo del sistema

**Primero, la tool adecuada** (no pasan por el enmascarado):

| Necesito | Tool |
|---|---|
| Cuerpo de un trigger, procedimiento, paquete, función o vista | `get_object_ddl(workspace, objeto, seccion?)` |
| Qué objetos usan una tabla (impacto) | `get_db_objects(workspace, tabla=...)` |
| Columnas, tipos, PK, índices | `get_table_schema` / `get_model_index` / `search_model` |
| ¿El modelo está desfasado frente a la BD? | `compare_model` (o `/rs-erd` → "actualiza el modelo BD") |

**Si aun así se consulta el catálogo con `db_query`** (desde 3.28.0, `scripts/pii_catalogo.py`):
sale **en claro** cuando la consulta *solo* lee estructura. Se tienen que cumplir las cuatro:

1. **Todas** las tablas del `FROM`/`JOIN` (subconsultas incluidas) son vistas de estructura de
   una lista cerrada: Oracle `ALL_`/`USER_`/`DBA_` + `TABLES`, `TAB_COLUMNS`, `TAB_COLS`,
   `COL_COMMENTS`, `TAB_COMMENTS`, `TRIGGERS`, `TRIGGER_COLS`, `SOURCE`, `OBJECTS`,
   `CONSTRAINTS`, `CONS_COLUMNS`, `INDEXES`, `IND_COLUMNS`, `IND_EXPRESSIONS`, `VIEWS`,
   `SEQUENCES`, `SYNONYMS`, `DEPENDENCIES`, `ARGUMENTS`, `PROCEDURES`, `ERRORS`, `TAB_PRIVS`
   (sin esquema o con `SYS.`); SQL Server **calificadas**: `INFORMATION_SCHEMA.*` y `sys.*` de
   estructura (`tables`, `columns`, `objects`, `triggers`, `sql_modules`, `indexes`…). Una
   sola tabla de negocio en la consulta → reglas normales para todo.
2. Ninguna está en el modelo (una tabla propia llamada `USER_OBJECTS` es de negocio).
3. El `SELECT` es **simple**: `*`, `alias.*` o columnas de estructura sueltas, con alias
   opcional. Funciones, expresiones, `||`, literales, `CASE`, subconsultas escalares, `WITH`
   o `UNION`/`MINUS`/`INTERSECT` → no hay excepción (por ahí se sacarían datos de negocio con
   un `FROM` de catálogo).
4. Solo salen en claro las columnas de estructura de la lista (`COLUMN_NAME`, `DATA_TYPE`,
   `TRIGGER_BODY`, `TEXT`, `NAME`, `DEFINITION`…).

⛔ **Siguen enmascaradas aunque sean catálogo:** `LOW_VALUE`/`HIGH_VALUE` de `ALL_TAB_COLUMNS`
(son el mínimo y el máximo **reales** de la columna), los histogramas (`ALL_TAB_HISTOGRAMS`) y
`V$SQL` (`SQL_TEXT` lleva los literales de las consultas).

🔎 **Dato personal dentro del código.** En las columnas de código (`TEXT`, `TRIGGER_BODY`,
`DATA_DEFAULT`, `SEARCH_CONDITION`, `VIEW_DEFINITION`, `ROUTINE_DEFINITION`, `DEFINITION`,
`COMMENTS`…) se buscan DNI/NIE (con letra de control válida), IBAN y correos **dentro** del
texto, y se sustituye solo ese trozo por su `pii:…`: el código se sigue leyendo. La columna sale
en `pii.redacted` y en `pii.suspect`.

`pii.catalog = true` en la respuesta dice que se aplicó la excepción. Si un nombre de columna o
un cuerpo de objeto llega como `pii:…`, la consulta no la cumple: ⛔ **no sortearlo**
(`CASE`→números, `SUBSTR`, `ASCII`…) — reescribir la consulta como simple o usar las tools de
la tabla de arriba.

---

# 🧠 Motores soportados

- SQL Server
- Oracle

---

# ⚙️ Configuración

Obtener vía `get_db_config` (tool MCP) o `hooks\get-config.ps1` — nunca leer el fichero directamente.

Varias conexiones → `conexiones[0]` es la principal; las demás solo para generar DDL.

⛔ **NUNCA** leer `docs/.rs-databases.json` directamente: puede contener el password (en texto plano
o cifrado). Usar `get-config.ps1` / `get_db_config` (que nunca emiten el password) o `db_query`.

> 🔐 **Cifrado en reposo (opcional):** el password del `cadena` puede guardarse cifrado con DPAPI como
> `Password=enc:<base64>`. Los lectores lo descifran al vuelo (`Unprotect-RsSecret` en PS,
> `_unprotect_secret` en Python); un valor sin el prefijo `enc:` se trata como texto plano. Para migrar
> los secretos existentes: `/rs-cifrar` (hook `secure-credentials.ps1`).

---

# 🟡 SQL Server

Catálogo:

INFORMATION_SCHEMA.COLUMNS

---

## Longitud

CHARACTER_MAXIMUM_LENGTH

---

# 🟣 Oracle

Catálogo:

ALL_TAB_COLUMNS

---

## Longitud

CHAR_LENGTH ✅

---

## VARCHAR2 en DDL (CRÍTICO)

En scripts CREATE TABLE y ALTER TABLE, todos los campos VARCHAR2 deben declararse con semántica de caracteres:

```sql
-- ✅ Correcto
OGEMPRESA VARCHAR2(6 CHAR)
CLNOMBRE  VARCHAR2(80 CHAR)

-- ❌ Incorrecto
OGEMPRESA VARCHAR2(6)
CLNOMBRE  VARCHAR2(80)
```

Sin `CHAR`, Oracle usa semántica de bytes por defecto. Con caracteres multibyte (UTF-8) un VARCHAR2(6) puede truncar strings de 6 caracteres. Especificar `CHAR` garantiza que el tamaño es en caracteres, igual que el diseño lógico.

---

# 🚫 Prohibido

- usar DATA_LENGTH
- asumir equivalencias entre motores
- omitir `CHAR` en VARCHAR2 de Oracle (CREATE TABLE / ALTER TABLE)

---

# 🔍 Validaciones obligatorias

---

## Tipos

- verificar compatibilidad con C#
- evitar conversiones implícitas

---

## Longitud

- validar tamaño vs código
- evitar truncamientos

---

## Nullabilidad

- validar campos NULL
- controlar en código

---

# ⚠️ Problemas comunes

- string más largo que BD → truncamiento
- null no controlado → excepción
- tipo incorrecto → fallo en runtime