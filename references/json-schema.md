# JSON Schema — Modelo de BD

Ruta: `BD\<proyecto>-model.json`

---

## Schema completo

```json
{
  "version": "1.0",
  "project": "MiProyecto",
  "engine": "ORACLE",
  "datasource": "ORACLEDS",
  "schema": "MIPROYECTO",
  "updated_at": "2026-06-22T10:00:00",
  "subviews": {
    "Parametricas": ["RIDIOMA", "RCONTROLES", "RVERSIONES", "RMODULOS"]
  },
  "pii_policy": {
    "mode": "off",
    "transform": "hash",
    "patterns_add": ["OBSERVACION*", "*_CONTACTO"],
    "patterns_remove": ["NOMBRE*"]
  },
  "objetos": {
    "_firma": "sha256-16",
    "vistas": {
      "V_CLIENTES_ACTIVOS": {
        "estado": "VALID",
        "firma": "38e734fea6450050",
        "lineas": 12,
        "tablas_usadas": ["CLIENTES"],
        "source": "db"
      }
    },
    "secuencias": {}, "funciones": {}, "procedimientos": {},
    "paquetes": {}, "triggers": {}, "sinonimos": {}
  },
  "tables": {
    "CLIENTES": {
      "description": "Tabla maestra de clientes",
      "source": "db",
      "columns": {
        "ID_CLIENTE": {
          "type": "NUMBER(10)",
          "nullable": false,
          "pk": true,
          "description": "Identificador único del cliente",
          "source": "db"
        },
        "NOMBRE": {
          "type": "VARCHAR2(100)",
          "nullable": false,
          "pk": false,
          "description": "Nombre completo del cliente",
          "source": "db",
          "pii": true
        },
        "COD_ESTADO": {
          "type": "VARCHAR2(2)",
          "nullable": true,
          "default": "'A'",
          "pk": false,
          "description": "Código de estado del cliente",
          "source": "db",
          "safe": true
        },
        "ID_TIPO": {
          "type": "NUMBER(5)",
          "nullable": true,
          "pk": false,
          "description": "",
          "source": "db"
        }
      },
      "relations": [
        {
          "target_table": "PEDIDOS",
          "source_column": "ID_CLIENTE",
          "target_column": "ID_CLIENTE",
          "type": "1:N",
          "inferred_from": "JoinClause",
          "confidence": "high",
          "source_file": "OnLine\\Soluciones\\AgendaWeb\\RSDalc\\ClienteDalc.cs",
          "source": "dalc"
        },
        {
          "target_table": "TIPOS_CLIENTE",
          "source_column": "ID_TIPO",
          "target_column": "ID_TIPO",
          "type": "N:1",
          "inferred_from": "manual",
          "confidence": "high",
          "source_file": null,
          "source": "manual"
        }
      ]
    }
  }
}
```

---

## Campos del modelo

### Nivel raíz

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `version` | string | Versión del schema |
| `project` | string | Nombre del proyecto AIS |
| `engine` | `ORACLE` \| `SQLSERVER` | Motor de BD |
| `datasource` | string | Data Source / Server extraído de la cadena de la conexión principal de .rs-databases.json |
| `schema` | string | Schema Oracle o base de datos SQL Server |
| `updated_at` | ISO8601 | Última actualización |
| `subviews` | object | Mapa `<vista> → [tablas]`. La vista `Parametricas` la consume el instalador de cliente (`scripts/installer-inserts.py`) **y** la política PII, que trata esas tablas como no personales (ver abajo) |
| `pii_policy` | object | Política de protección de datos personales en `db_query`. Ausente = `mode: "off"` (ver abajo) |
| `_cobertura` | object | Cuánto del esquema alcanzó a ver la última sincronización (ver abajo). Lo escriben los hooks de sync; metadato, no datos del modelo |
| `tables` | object | Mapa de tablas por nombre |

### Formato del fichero (no es cosmético)

El `model.json` vive en el repositorio y se revisa por diff, así que su serialización es parte
del contrato: `indent=2`, `separators=(',', ': ')`, **`ensure_ascii=True`**, saltos **CRLF** y
UTF-8 **con BOM**. Lo impone `scripts/_modeljson.py`, que es el **único** escritor del plugin
—desde PowerShell se llega por `Save-RsModelJson` (`hooks/lib-modeljson.ps1`)—, y lo verifica
sobre el temporal antes de sustituir al modelo bueno: BOM, cero LF sueltos, cero bytes no-ASCII,
reparseo y comparación con el objeto que se quería escribir.

⛔ **Nunca escribir el modelo con `ConvertTo-Json` de PowerShell 5.1 ni con `json.dump` a pelo.**
El primero alinea cada valor a la columna de la clave padre (x3,2 de tamaño y todas las líneas
resangradas: diff inservible aunque el BOM y los CRLF sean correctos); el segundo, con
`ensure_ascii=False` y sin BOM, deja los acentos como bytes crudos y hace que el fichero cambie
de codificación según qué proceso lo tocó el último.

### Nivel tabla

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `description` | string | Descripción semántica (manual) |
| `source` | `db\|dalc\|manual` | Cómo se detectó esta tabla |
| `columns` | object | Mapa de columnas por nombre |
| `relations` | array | Relaciones con otras tablas |
| `visible` | boolean | Presente y `false` = la última sincronización **no vio** esta tabla. ⛔ No significa que no exista: con una cuenta que solo ve por GRANT, Oracle no permite distinguirlo. La tabla se conserva entera —columnas, relaciones e índices— y la marca desaparece sola cuando vuelve a verse. **Ausente = visible**, que es el caso normal (así el modelo no engorda con un campo por tabla) |
| `visible_check` | ISO8601 | Cuándo se dejó de ver, para distinguir una tabla que hoy no se ve de una que lleva meses sin verse |

### Nivel `_cobertura`

Lo que la sincronización alcanzó a ver frente a lo que el diccionario dice que hay. Existe
porque **un conteo bajo no significa "no hay"**: una cuenta que no es dueña del esquema ve por
GRANT per-object, y el PL/SQL exige GRANT `EXECUTE` (no `SELECT`) — con cero, `ALL_OBJECTS` y
`ALL_SOURCE` devuelven cero procedimientos **sin error**.

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `conexion` / `usuario` / `esquema` | string | Con qué se leyó. Sin esto, una lectura hecha como dueño es indistinguible de una hecha con la cuenta de consulta |
| `es_dueno` | boolean | `true` = visibilidad total; un descuadre es entonces un fallo del script, no de permisos |
| `grants` | object | `{PRIVILEGIO: n}` sobre el esquema (directos, por PUBLIC o por rol) |
| `secciones` | object | `{sección: {real, capturado, excluido, motivo, hueco, origen, fecha}}`. `excluido` es lo que el script descarta **a propósito** (secuencias de columna IDENTITY, recycle bin); declararlo evita que una exclusión legítima cuente como pérdida |
| `actualizado` | ISO8601 | Última escritura del bloque |

Se **mezcla por sección**, no se reescribe: cada sync conoce solo su parte (`sync-from-db` las
tablas, `sync-indexes` los índices, `sync-model-objects` los objetos), y cada sección guarda su
`origen` y su `fecha` para que un bloque viejo no se lea como si fuera de esta ejecución.

### Nivel `objetos` (inventario de objetos de BD)

Siete secciones fijas —`secuencias`, `vistas`, `funciones`, `procedimientos`, `paquetes`,
`triggers`, `sinonimos`— cada una un mapa `nombre` → ficha. Las claves que empiezan por `_`
son metadatos, no objetos. Lo rellena `hooks/sync-model-objects.ps1`.

⛔ **Se guarda la ficha y una firma del cuerpo, nunca el cuerpo.** El instalador sigue
extrayendo el DDL de la BD viva: esa es la garantía de que un paquete no puede entregar código
viejo. Si el modelo fuera la fuente, un `model.json` desactualizado entregaría un procedimiento
de hace meses sin que nada avisara. La firma da lo que faltaba —saber **qué cambió** desde la
última entrega, que el delta por VCS de `/rs-actualizador` no puede ver porque un procedimiento
modificado en BD no está en el repo— sin renunciar a esa garantía.

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `estado` | string | `VALID`, `INVALID`, `DISABLED`… tal como lo reporta el motor. Un trigger `DISABLED` en origen se instala deshabilitado |
| `firma` | string | 16 hex de SHA-256 sobre el cuerpo **normalizado** (CRLF→LF, sin relleno a la derecha, sin líneas en blanco finales). La indentación sí cuenta: es del autor. Se calcula sobre el mismo texto que emitiría el instalador, así que "la firma cambió" significa "lo que se entregaría ha cambiado" |
| `lineas` | integer | Tamaño del cuerpo normalizado |
| `tablas_usadas` | array | Tablas del modelo que aparecen en el cuerpo. ⛔ **Derivado por coincidencia de texto**, no del diccionario de dependencias: un nombre dentro de un comentario cuenta igual. Sirve para "qué procedimientos tocan `RCLIENTES`" antes de cambiar una columna, donde un falso positivo se descarta de un vistazo y un falso negativo duele |
| `source` | string | `db` |

En Oracle, la especificación y el cuerpo de un package son dos objetos en `ALL_SOURCE` pero
**una sola ficha** en `paquetes`: se firman los dos textos concatenados. SQL Server no tiene
paquetes, así que allí esa sección va siempre vacía.

### Nivel columna

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `type` | string | Tipo de dato con precisión (NUMBER(10), VARCHAR2(100)) |
| `nullable` | boolean | Admite nulos |
| `default` | string | Expresión del valor por defecto **tal cual la declara la BD** (`0`, `'N'`, `SYSDATE`, `((0))`, `getdate()`), sin la palabra `DEFAULT`. La rellena `hooks/sync-from-db.ps1` / `sync-model-tables.ps1`; ausente = la columna no tiene default. La emite `generate-sql.py` (SQL de desarrollo, `/rs-erd`) en el `CREATE TABLE`, entre el tipo y el `NOT NULL`. ⛔ **Ya no interviene en el instalador**: desde la 3.26.0 el DDL que se entrega lo extrae `installer-tablas.py` de la BD viva, así que un `default` desfasado en el modelo ya no puede llegar al cliente. Se sigue manteniendo porque es lo que documenta el esquema en el ERD y en el desarrollo. ⛔ Es una **expresión del motor de origen**, no un tipo: `adapt_type` no la traduce, así que al generar para otro motor sale comentada aparte en vez de inline. Sin este campo, en el cliente toda columna con default queda a NULL y **no salta ningún error** |
| `pk` | boolean \| integer | Posición dentro de la PK. `false` = no es PK. Un entero (`1`, `2`, `3`...) fija la **posición dentro de la clave**, que es la que escriben los hooks de sync: ese orden es el del índice que respalda la PK y no tiene por qué coincidir con el de las columnas de la tabla; con él cambiado se pierden los accesos por prefijo de clave. `true` se sigue admitiendo (modelos anteriores y el toggle del ERD) y significa "es PK, sin posición declarada" → se asume el orden de declaración. ⛔ Dentro de una tabla tiene que ser **todo ordinales o todo booleanos**. Si se mezclan, `pk_columns` **no ordena**: cae al orden de declaración y `pk_orden_ambiguo` lo marca para que el generador avise. Antes sí ordenaba, y era peor que no hacer nada — `true` contaba como ordinal 0 y se iba al final, así que una PK `(A=true, B=2)` salía como `(B, A)`, invertida y sin error. Quien escribe el modelo evita la mezcla: `hooks/lib-dbmodel.ps1` pone siempre el ordinal, y el toggle de PK del ERD renumera la clave entera a `1..n` (normalizando de paso cualquier `true` heredado) |
| `description` | string | Descripción semántica (manual o inferida) |
| `source` | `db\|dalc\|manual` | Origen del dato |
| `pii` | boolean | Marca explícita de dato personal. `true` → la columna se enmascara siempre. Manda sobre patrones, paramétricas y tipo (ver `pii_policy`) |
| `safe` | boolean | Marca explícita de dato NO personal. `true` → la columna sale en claro; `false` equivale a `pii: true`. Manda sobre patrones, paramétricas y tipo, con **una** excepción: la red de seguridad por forma de valor (ver `pii_policy`) |

### Nivel relación

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `target_table` | string | Tabla destino |
| `source_column` | string | Columna en la tabla actual |
| `target_column` | string | Columna en la tabla destino |
| `type` | `1:N\|N:1\|1:1\|N:M` | Cardinalidad |
| `inferred_from` | string | `JoinClause\|WhereClause\|manual` |
| `confidence` | `high\|medium\|low` | Confianza en la inferencia |
| `source_file` | string \| null | Fichero DALC donde se detectó |
| `source` | `dalc\|manual` | Origen de la relación |

---

## Política PII (`pii_policy`)

Bloque raíz que gobierna el enmascarado de datos personales en los resultados de `db_query`
(tool MCP y hook). Motor: `scripts/pii_policy.py` + `scripts/pii_mask.py`. Visión de usuario en
el README; la medida y sus límites en `docs/proteccion-pii-consultas-bd.md`.

⛔ El modelo puede pesar ~180K tokens: **nunca** editarlo con `Read`/`Edit`. Para cambiar el modo
está `/rs-pii audit|enforce|off`; para el resto de campos, un script de una invocación (patrón en
`agents/rs-pii.md`, "Cómo escribir `pii_policy.mode`").

| Campo | Tipo | Por defecto | Descripción |
|-------|------|-------------|-------------|
| `mode` | `off\|audit\|enforce` | `off` | `off` = no se evalúa nada, datos en claro. `audit` = se evalúa y se informa en el bloque `pii` de la respuesta, pero **los datos siguen saliendo en claro — no protege**. `enforce` = se aplica `transform` |
| `transform` | `hash\|suppress` | `hash` | `hash` → seudónimo `pii:` + 12 hex (HMAC-SHA256 con clave local, determinista: el mismo valor da siempre el mismo seudónimo). `suppress` → literal `[PII]`, sin correlación posible. Solo aplica en `enforce` |
| `patterns_add` | array\<string\> | `[]` | Patrones de nombre de columna **añadidos** a la lista base `scripts/pii_patterns.json` |
| `patterns_remove` | array\<string\> | `[]` | Patrones **eliminados** de la lista resultante (base + `patterns_add`) |

Bloque ausente, o campo ausente dentro del bloque, equivale al valor por defecto. Un `pii_policy`
sin `mode` es, por tanto, `off`.

**Patrones.** Sintaxis glob (`*`, `?`, `[seq]`) sobre el nombre de columna. Nombres y patrones se
comparan en mayúsculas, así que `dni*` y `DNI*` son el mismo patrón. `patterns_remove` elimina por
**patrón literal**, no por nombre de columna: para quitar `NOMBRE*` hay que escribir exactamente
`NOMBRE*`, y poner `NOMBRE` no quita nada. Se aplica después de `patterns_add`, de modo que puede
cancelar una entrada añadida ahí. Si `scripts/pii_patterns.json` no se puede leer, la lista pasa a
`["*"]` — todo se enmascara: una instalación rota degrada a inútil pero segura, nunca a "funciona
pero filtra".

**Precedencia**, por columna del resultset (`scripts/pii_policy.py`):

| # | Regla | Resultado |
|---|-------|-----------|
| 1a | Marca explícita en la columna: `"pii": true` o `"safe": false` | Enmascarar |
| 1b | Marca explícita `"safe": true` | En claro |
| 2 | El nombre casa con un patrón. Aplica **aunque la columna no esté en el modelo** | Enmascarar |
| 3 | Todas las tablas del ámbito están en `subviews["Parametricas"]` | En claro |
| 4 | `pk`, `fk`, o `type` que empieza por numérico/fecha (`NUMBER`, `INT`, `DECIMAL`, `DATE`, `TIMESTAMP`…) | En claro |
| 5 | Resto (texto) | Enmascarar |
| 6 | La columna no resuelve contra el modelo (alias, expresión calculada) | Se decide por la **forma de los valores** devueltos |

Las marcas van primero a propósito: son la válvula de escape cuando las reglas 2-6 se equivocan.
Cuando la consulta toca **varias** tablas y la columna existe en más de una, gana lo más
restrictivo: basta una definición con `pii`/`safe: false` para enmascarar, y las reglas 3 y 4 solo
dejan en claro si **todas** las definiciones lo permiten.

**La única excepción a la marca explícita** es la red de seguridad por forma de valor
(`mask_resultset` + `scripts/pii_detect.py`): toda columna que vaya a salir en claro —incluidas las
marcadas `"safe": true`— se reescanea, y si sus **valores** tienen forma de DNI, NIE, IBAN, correo,
teléfono o tarjeta, se enmascara igualmente y se reporta en `pii.suspect`. Solo va en la dirección
segura, nunca al revés: **no existe una marca de "en claro pase lo que pase"**, y es deliberado.

Los valores `NULL` y los que solo contienen espacios no se transforman: se devuelven tal cual
aunque la columna esté enmascarada.

**`subviews["Parametricas"]`** no es una lista específica de PII: es la misma que consume el
instalador de cliente para volcar los INSERT de tablas paramétricas. Se reutiliza a propósito para
no mantener dos listas que se desincronicen. Consecuencia a tener presente al editarla: **añadir
una tabla ahí también la saca en claro** en las consultas.

---

## Reglas de merge

Al actualizar el JSON (sync desde BD o análisis DALC):

1. **Tablas/columnas**: si existe en JSON → actualizar tipo/nullable/default, preservar description y las marcas manuales `pii`/`safe`
2. **Columnas nuevas**: añadir con `source: "db"` o `"dalc"`, description vacía
3. **Tablas no encontradas en BD**: marcar con `"orphan": true` (no eliminar)
4. **Relaciones manuales**: nunca sobreescribir (`source: "manual"`)
5. **Relaciones DALC duplicadas**: deduplicar por `target_table + source_column + target_column`

---

## Cómo consumen este modelo otros agentes

Los agentes leen `BD\<proyecto>-model.json` para:

```
# Consultar tipo de una columna antes de generar query
modelo.tables["CLIENTES"].columns["ID_CLIENTE"].type → "NUMBER(10)"

# Saber cómo hacer JOIN entre dos tablas
modelo.tables["CLIENTES"].relations → [{target_table: "PEDIDOS", source_column: "ID_CLIENTE", ...}]

# Adaptar SQL al motor correcto
modelo.engine → "ORACLE" → usar ROWNUM, NVL, TO_DATE, etc.
```
