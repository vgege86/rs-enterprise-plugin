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
          "source": "db"
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
| `tables` | object | Mapa de tablas por nombre |

### Nivel tabla

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `description` | string | Descripción semántica (manual) |
| `source` | `db\|dalc\|manual` | Cómo se detectó esta tabla |
| `columns` | object | Mapa de columnas por nombre |
| `relations` | array | Relaciones con otras tablas |

### Nivel columna

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `type` | string | Tipo de dato con precisión (NUMBER(10), VARCHAR2(100)) |
| `nullable` | boolean | Admite nulos |
| `pk` | boolean \| integer | Es parte de la PK. `true` = sí, sin posición definida (se asume el orden de declaración de las columnas). Un entero (`1`, `2`, `3`...) fija la **posición dentro de la PK**: úsalo cuando el orden de la PK real no coincide con el de las columnas, porque ese orden es el del índice que respalda la PK y con él cambiado se pierden los accesos por prefijo de clave |
| `description` | string | Descripción semántica (manual o inferida) |
| `source` | `db\|dalc\|manual` | Origen del dato |

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

## Reglas de merge

Al actualizar el JSON (sync desde BD o análisis DALC):

1. **Tablas/columnas**: si existe en JSON → actualizar tipo/nullable, preservar description
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
