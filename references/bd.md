# Reglas de Base de Datos

---

# 📥 Fuente de datos (CRÍTICO)

- **Esquema / tipos / columnas** → el modelo (`<proyecto>-model.json`, vía `search_model` / `get_model_index` / `get_table_schema`) es la fuente autoritativa.
- **Datos / valores de fila** → siempre `db_query` directo contra la BD.
- ⛔ **NUNCA** leer ficheros `.sql` de la carpeta `BD\` (ni subcarpetas) como fuente de datos ni de esquema: pueden estar desactualizados. De `BD\` solo se usa `<proyecto>-model.json`.
- Si la BD no es accesible → informar y pedir acceso; no sustituir la BD por scripts de `BD\`.

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