# Estructuras, schema y grupos — RSValidador

Referencia de dominio del corazón de la herramienta: la **estructura** (interfaz de entrada) y su
JSON. Cargar siempre que el cambio toque campos, reglas de validación, grupos o versiones.

## 1. Modelo conceptual

| Concepto | Descripción |
|----------|-------------|
| **Proyecto** | Espacio de trabajo aislado; normalmente una implantación de cliente |
| **Mandante** | Sub-tenant dentro del proyecto (código + nombre). Por defecto: código `9999`, nombre `Genérico` |
| **Estructura** | Definición de un fichero (posicional o delimitado): nomenclatura, campos y reglas. Pertenece a proyecto + mandante |
| **Grupo de estructuras** | Agrupa estructuras dentro de un proyecto. **Estándar (SQL)** genera scripts SQL; los personalizados son solo de validación |
| **Relación** | Cruce entre dos estructuras (F1, F2) por claves, para integridad referencial |
| **Catálogo estándar** | Lista de valores permitidos sincronizada desde la tabla `RTABL` de SQL Server |

## 2. ⛔ La trampa nº1: el modelo Pydantic `Schema`

El schema de una estructura se guarda como **JSON blob** en la columna `estructura`. FastAPI
deserializa el body con el modelo Pydantic `Schema` **antes** de persistir.

> **Todo campo del JSON que no esté declarado en `Schema` se descarta en silencio.**
> Sin error, sin log, sin 422. El usuario guarda, la UI dice OK, y el dato no está.

Campos declarados actualmente: `name`, `file_type`, `delimiter`, `nomenclatura`, `date_format`,
`numeric_format`, `fields`, `comparisons`, `text_qualifier`, `unique_combos`.

**Regla:** añadir un campo al schema ⇒ declararlo en el modelo Pydantic `Schema` de `estructura.py`,
en el mismo cambio. Precedentes reales: `text_qualifier` y `unique_combos` — ambos se perdieron
silenciosamente hasta que se declararon.

Localizar el modelo: `grep -n "class Schema" estructura.py`.

## 3. Campos de una estructura

Cada campo soporta: `tipo`, `longitud`, `start` (posicional), `decimales`, `nullable`, `pk`,
`min`/`max`, `catalogo` (lista de códigos), `domain` (lista de valores), `date_format`,
`numeric_format`, `description`.

A nivel de estructura: `tiene_cabecera` (omite la primera línea al validar, al aplantillar y al
generar fichero de prueba), `obligatoria` (la validación masiva reporta su ausencia),
`nomenclatura` (con la que se asocia un fichero a su estructura en el lote).

**`text_qualifier`** (delimitados): carácter opcional de 1 posición (p. ej. `"`) para ficheros
RFC 4180 donde unos campos van entrecomillados y otros no. Si es truthy, `validator_service.py` usa
`csv.reader` con `delimiter` + `quotechar`; si es falsy, usa `line.split(delimiter)` (comportamiento
histórico). ⛔ No unificar ambos caminos sin verificar estructuras antiguas sin `text_qualifier`.

## 4. Reglas de validación soportadas

- **Tipos, longitudes, obligatoriedad, PK** (duplicados vía `pk_seen`).
- **Formatos de fecha**: `AAAAMMDD`, `DDMMAAAA`, `AAAA/MM/DD`, `DD/MM/AAAA`, `AAAAMMDDhhmmss`.
- **Formato numérico**: signo, separador decimal, decimales obligatorios, precisión.
- **Dominios y catálogos**: contra lista de valores permitidos.
- **Comparaciones entre campos** de la misma fila: `>=`, `<=`, `>`, `<`, `=`, `!=`.
- **`unique_combos`** (modelo `UniqueComboRule`): prohíbe dos filas con la misma combinación de
  valores en los campos indicados. Implementado con el patrón `unique_combo_seen` (lista de dicts,
  uno por combo), análogo a `pk_seen`. El error se reporta con `campo: "UNIQUE"`.
- **Integridad relacional**: valida en ambos sentidos (`f1_not_in_f2`, `f2_not_in_f1`).

Al añadir una regla nueva: (a) declararla en `Schema`, (b) implementarla en `validator_service.py`
siguiendo el patrón `*_seen` si es de unicidad, (c) exponerla en la pantalla que la configura,
(d) comprobar que la exportación a Excel de la validación masiva la refleja.

## 5. Grupos de estructuras — `grupo_id`

⛔ Convención crítica:

| Valor | Significado |
|-------|-------------|
| `grupo_id IS NULL` (BD) | Grupo **Estándar (SQL)** — estas estructuras **sí** generan scripts SQL |
| `grupo_id > 0` | Grupo personalizado — **solo validación** (p. ej. ficheros de agencias externas) |
| `grupo_id = 0` (frontend) | Representación **sintética** del estándar; no existe fila en `grupos_estructura` |

- El grupo es **por proyecto** (no por mandante); el nombre es único dentro del proyecto.
- Eliminar un grupo está bloqueado si tiene estructuras o relaciones asignadas.
- `GET /estructuras` y `GET /relaciones` aceptan `grupo_id: Optional[int]`: 0 o ausente → filtro
  `IS NULL`. `POST /guardar-estructura` y `/guardar-relacion` guardan `None` si llega 0 o falsy.
- La pantalla de scripts SQL **no envía** `grupo_id` → el backend filtra `IS NULL` → ninguna
  estructura de grupo personalizado llega nunca a la generación de scripts. Este es el mecanismo que
  mantiene limpia la configuración de uCollect: no romperlo.
- ⛔ Nunca construir una URL con `&grupo_id=` vacío → 422 (ver `arquitectura.md` §5).

## 6. Versionado de estructuras

`EstructuraVersion` (`estructura_versiones`) guarda el histórico del schema. Endpoints:
`GET /estructuras/{id}/versiones`, `GET .../versiones/{n}`, `POST .../versiones/{n}/restaurar`.
Un cambio en la forma del schema debe seguir siendo **legible desde versiones antiguas** — las
funciones de carga absorben formatos históricos; no eliminar esa absorción.

## 7. Validación masiva

- Asocia cada fichero a su estructura por **nomenclatura** (gana la coincidencia más larga).
- Aplica las relaciones aplicables entre ficheros del lote.
- Reporta ficheros **obligatorios ausentes** y ficheros **sin estructura**.
- `/validar-masivo-informe` genera el Excel en el **mismo pase** y lo devuelve como `excel_b64`
  (base64) dentro del JSON; puede ser `null` si la generación falla. El frontend decodifica con
  `atob()` + `Uint8Array`. `/validar-masivo` (StreamingResponse) sigue existiendo pero no lo usa el
  flujo principal.
- Umbral de informe HTML/PDF: constante `MAX_ERRORES_INFORME` en el JS de la pantalla de validación
  masiva. Por encima, los botones de informe se deshabilitan; el Excel técnico siempre disponible.
