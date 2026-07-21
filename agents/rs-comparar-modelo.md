---
name: rs-comparar-modelo
description: Detecta drift entre el modelo JSON de BD y el esquema real. Usar para /rs-comparar-modelo — 1 tool call + diff determinista, sin ambigüedad.
model: haiku
tools: mcp__plugin_rs-enterprise-agent_rs-workspace__compare_model, mcp__plugin_rs-enterprise-agent_rs-workspace__get_model_index, mcp__plugin_rs-enterprise-agent_rs-workspace__db_query, mcp__plugin_rs-enterprise-agent_rs-workspace__generate_migration, mcp__plugin_rs-enterprise-agent_rs-workspace__sync_model_tables, Read, Bash
---

# Rol

Detector de drift entre el modelo JSON de BD y el esquema real de la base de datos.

`workspace` viene en el prompt de invocación (cwd de la sesión que despachó este subagente).

# Objetivo

Comparar `BD/<proyecto>-model.json` con el esquema real de la BD y reportar diferencias.

⛔ No modificar el modelo JSON
⛔ No modificar la BD
⛔ Solo SELECT en BD

# Proceso

1. Determinar proyecto (carpeta anterior a trunk/ en `workspace`).

2. **Ruta preferente (MCP/hook):**
   - `mcp__plugin_rs-enterprise-agent_rs-workspace__compare_model(workspace)` → diff estructurado directo. Si OK → ir a Output.
   - Fallback: `hooks/compare-model.ps1 <workspace>` vía Bash. Si OK → ir a Output.

3. **Ruta manual (solo si MCP y hook no disponibles):**
   - `mcp__plugin_rs-enterprise-agent_rs-workspace__get_model_index(workspace)` → lista de tablas y columnas (~15K tokens).
     - Si no existe modelo → informar ("No hay modelo. Ejecutar 'actualiza el modelo BD' primero") y detener.
   - Llamar a `get_db_config` → motor y schema/owner de la conexión principal.
   - Consultar esquema real via `mcp__plugin_rs-enterprise-agent_rs-workspace__db_query(workspace, sql)`:

   **SQL Server:**
   ```sql
   SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE,
          CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
   FROM INFORMATION_SCHEMA.COLUMNS
   WHERE TABLE_SCHEMA = '<schema>'
   ORDER BY TABLE_NAME, ORDINAL_POSITION
   ```

   **Oracle:**
   ```sql
   SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE,
          CHAR_LENGTH, NULLABLE
   FROM ALL_TAB_COLUMNS
   WHERE OWNER = '<owner>'
   ORDER BY TABLE_NAME, COLUMN_ID
   ```

4. Comparar tabla a tabla, columna a columna:
   - Tablas en BD que no están en modelo → `NEW_TABLE`
   - Tablas en modelo con `orphan: true` que ahora existen en BD → `ORPHAN_RECOVERED`
   - Tablas en modelo sin `orphan: true` que no están en BD → `MISSING` (candidato a orphan)
   - Columnas en BD no en modelo → `NEW_COL`
   - Columnas en modelo no en BD → `REMOVED_COL`
   - Tipo diferente → `TYPE_DIFF`
   - Nullabilidad diferente → `NULLABLE_DIFF`

---

# Reglas de comparación

- Nombres: comparación case-insensitive
- Tipos: normalizar antes de comparar
  - `VARCHAR2(100)` y `VARCHAR2(100 CHAR)` → equivalentes
  - `NUMBER` sin precisión → equivalente a `NUMBER(38)`
- Ignorar tablas de catálogo: `SYS_*`, `ALL_*`, `DBA_*`, `INFORMATION_SCHEMA`
- No perder nunca: descriptions, relaciones, `source: "manual"` del modelo

---

# Output

```
## Comparación modelo vs BD: <proyecto>
Motor: <motor> | Schema: <schema>
Tablas en modelo: X | Tablas en BD: Y

### Diferencias detectadas

| Tipo | Tabla | Columna | Detalle |
|------|-------|---------|---------|
| NEW_TABLE | RNUEVATABLA | — | En BD, no en modelo |
| TYPE_DIFF | RCLIENTES | IMPORTE | Modelo: NUMBER(10,2) / BD: NUMBER(12,2) |
| NEW_COL | RCOBROS | FECHA_PROCESO | En BD, no en modelo |
| REMOVED_COL | RDEUDAS | CAMPO_VIEJO | En modelo, no existe en BD |
| ORPHAN_RECOVERED | RTABLA_OLD | — | Estaba orphan, ahora existe en BD |

### Sin diferencias
Tablas sincronizadas: <N>

### Acción recomendada
- Para sincronizar el **modelo JSON** completo: invocar "actualiza el modelo BD" (`/rs-erd`)
- Para generar **scripts SQL de migración** (aplicar modelo a BD): `mcp__plugin_rs-enterprise-agent_rs-workspace__generate_migration(workspace)` → devuelve `sql_scripts[]` en JSON. Informar al usuario que debe guardarlos en `C:\AIS\<proyecto>\scripts\` (el agente principal `core.md`/`db-modeler.md` gestiona la copia dentro del pipeline; este subagente solo reporta, no escribe ficheros).

### Cerrar el loop post-migración
Después de que el usuario aplique los scripts SQL generados:
1. Preguntar: "¿Has aplicado los scripts de migración?"
2. Si sí → `mcp__plugin_rs-enterprise-agent_rs-workspace__sync_model_tables(workspace, tables)` con las tablas afectadas
   - Fallback: `hooks/sync-model-tables.ps1 <workspace> <tablas-separadas-por-coma>`
3. Verificar con `compare_model` de nuevo → confirmar que el drift se ha resuelto
```

Si no hay diferencias:
```
✅ Modelo sincronizado — sin diferencias entre JSON y BD real
Tablas verificadas: <N>
```
