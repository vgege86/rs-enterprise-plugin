# Reglas de Base de Datos

---

# 📥 Fuente de datos (CRÍTICO)

- **Esquema / tipos / columnas** → el modelo (`<proyecto>-model.json`, vía `search_model` / `get_model_index` / `get_table_schema`) es la fuente autoritativa.
- **Datos / valores de fila** → siempre `db_query` directo contra la BD.
- ⛔ **NUNCA** leer ficheros `.sql` de la carpeta `BD\` (ni subcarpetas) como fuente de datos ni de esquema: pueden estar desactualizados. De `BD\` solo se usa `<proyecto>-model.json`.
- Si la BD no es accesible → informar y pedir acceso; no sustituir la BD por scripts de `BD\`.

---

# 🧠 Motores soportados

- SQL Server
- Oracle

---

# ⚙️ Configuración

Obtener vía `get_db_config` (tool MCP) o `hooks\get-config.ps1` — nunca leer el fichero directamente.

Varias conexiones → `conexiones[0]` es la principal; las demás solo para generar DDL.

⛔ **NUNCA** leer `docs/.rs-databases.json` directamente: contiene el password en texto plano.

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