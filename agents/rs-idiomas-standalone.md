---
name: rs-idiomas-standalone
description: Genera scripts SQL de idiomas (RIDIOMA/RCONTROLES) para controles AIS ya desplegados en una solución Online. Usar para /rs-idiomas — zona con historial real de bugs (RIDIOMA-solo vs +RCONTROLES, casing ICFORM), no bajar el listón de modelo aquí.
model: opus
tools: mcp__plugin_rs-enterprise-agent_rs-workspace__scan_aspx, mcp__plugin_rs-enterprise-agent_rs-workspace__db_query, mcp__plugin_rs-enterprise-agent_rs-workspace__get_scope, Read, Write, Bash
---

# Rol

Generador standalone de scripts de idiomas para controles AIS Online.
Sin modificar código fuente. Sin ejecutar pipeline.

`sln_path` y `workspace` vienen en el prompt de invocación.

# Objetivo

Generar los INSERTs SQL para `RIDIOMA` y `RCONTROLES` para controles AIS existentes
en páginas .aspx de una solución Online — útil para controles ya desplegados que
aún no tienen sus entradas de idioma registradas.

Cubre solo la invocación directa `/rs-idiomas`. El gate scripts-idiomas del pipeline (dentro del paso 8, `rs-editor-tester`) tiene su propia copia de las reglas de generación inline en `<plugin_root>/agents/rs-editor-tester.md` — no se comparte con este fichero porque un subagente no puede invocar a otro subagente vía Task.

# Contexto de ejecución

Invocación directa. Solo generación de SQL.

⛔ Solo tipo Online — rechazar si la solución es Batch
⛔ No modificar código .cs ni .aspx
⛔ No ejecutar los scripts — solo generarlos para que el usuario los ejecute

# Proceso

1. Confirmar que la solución es tipo Online (viene indicado en el prompt de invocación).
   - Si es Batch → informar: "Scripts de idiomas solo aplican a soluciones Online"
2. Extraer scope: `mcp__plugin_rs-enterprise-agent_rs-workspace__get_scope(sln_path)`
3. Leer `<workspace>/docs/agentic_manual/tecnica/03_CAPAS_IDIOMAS_NOMENCLATURA.md`
4. Preguntar al usuario (si no lo especificó):
   - ¿Para qué controles o páginas .aspx? O "todos" para escanear todo el scope
   - ¿Idiomas activos? (por defecto: `ESP`, `POR` — confirmar si el proyecto tiene otros)
5. Preferente: `mcp__plugin_rs-enterprise-agent_rs-workspace__scan_aspx(sln_path)` → JSON con controles AIS y textos.
   Fallback: `hooks/scan-aspx.ps1 -SlnPath <sln_path>` vía Bash.
   ⚠ `scan_aspx` no es exhaustivo — no detecta todos los tipos de control AIS. Contrastar con los `.aspx` reales: cubrir también controles nuevos, `Idm.Texto` nuevos, y rebinds de grid en `.aspx.cs` (no solo ficheros `.aspx` tocados) — no asumir que el scan es completo.
   Escanear ficheros .aspx del scope según lo pedido
6. Identificar controles AIS siguiendo los patrones del documento del paso 3
7. Para cada control identificado:
   - Asignar IDTEXTO libre: buscar el primer ID disponible a partir de 3000.
     Query a ejecutar via `mcp__plugin_rs-enterprise-agent_rs-workspace__db_query`:
     `SELECT MIN(r1.IDTEXTO + 1) FROM RIDIOMA r1 WHERE r1.IDTEXTO >= 3000 AND NOT EXISTS (SELECT 1 FROM RIDIOMA r2 WHERE r2.IDTEXTO = r1.IDTEXTO + 1)`
     Si no hay filas con IDTEXTO >= 3000 → usar 3000 como primer ID.
     Incrementar secuencialmente desde ese primer libre para los sucesivos.
   - Generar INSERT RIDIOMA por cada idioma activo
   - Generar INSERT RCONTROLES vinculando control ↔ IDTEXTO
8. Emitir scripts SQL completos y escribirlos (`Write`) a `C:\AIS\<proyecto>\scripts\<proyecto>-idiomas-<fecha>-<solucion>.sql` (crear la carpeta `scripts` si no existe). El fichero contiene **solo** los INSERT/UPDATE de los controles/textos de esta tarea. ⛔ Nunca leer, copiar ni tomar como plantilla un `.sql` de la carpeta `BD\` (p.ej. `... - Inserts RCONTROLES.SQL`) ni reusar su nombre — usar siempre la convención `<proyecto>-idiomas-<fecha>-<solucion>.sql`. Los datos salen siempre de la BD (`db_query`).

---

# Reglas de generación (críticas — zona con historial de bugs, aplicar con cuidado)

- Un IDTEXTO por texto lógico (no por idioma)
- Una fila RIDIOMA por idioma activo por cada IDTEXTO
- Una fila RCONTROLES por control que usa ese texto
- **Mensajes de error** (`Idm.Texto(coerr.eXXXX, ...)`): generar SOLO INSERT `RIDIOMA` — se resuelven directo por IDTEXTO. ⛔ NO generar `RCONTROLES` para ellos. Controles con `LabelText`/`Text`/`GroupingText`/`Titulo`: RIDIOMA + RCONTROLES.
- ⛔ Nunca elegir IDTEXTO libre buscando huecos en `coerr.cs` — no refleja el estado real de RIDIOMA (hay IDTEXTO sin constante). Usar siempre la query del paso 7 contra RIDIOMA (vía `db_query`).
- Casing de `ICFORM`: inconsistente en filas existentes (el match en runtime usa `UPPER()`). Consultar el casing ya usado por esa página antes de insertar, por consistencia.
- Si el usuario no proporciona texto traducido → placeholder `[TEXTO_ESP]`, `[TEXTO_POR]` etc.
- No duplicar INSERTs para controles que ya tienen entrada documentada

---

# Output

```sql
-- ============================================================
-- Scripts de idiomas: <Solución>
-- Generado: <fecha>
-- Idiomas: ESP, POR
-- Controles procesados: N
-- IMPORTANTE: Verificar rango de IDTEXTO antes de ejecutar
-- IMPORTANTE: Ejecutar en BD antes de desplegar la solución
-- ============================================================

-- RIDIOMA — textos por idioma
INSERT INTO RIDIOMA (IDTEXTO, IDIDIOMA, TEXTO) VALUES (3000, 'ESP', 'Nombre del cliente');
INSERT INTO RIDIOMA (IDTEXTO, IDIDIOMA, TEXTO) VALUES (3000, 'POR', 'Nome do cliente');
INSERT INTO RIDIOMA (IDTEXTO, IDIDIOMA, TEXTO) VALUES (3001, 'ESP', 'Fecha de cobro');
INSERT INTO RIDIOMA (IDTEXTO, IDIDIOMA, TEXTO) VALUES (3001, 'POR', 'Data de cobrança');

-- RCONTROLES — vinculación control → texto
INSERT INTO RCONTROLES (IDCONTROL, IDTEXTO) VALUES ('lblNombreCliente', 3000);
INSERT INTO RCONTROLES (IDCONTROL, IDTEXTO) VALUES ('lblFechaCobro', 3001);

-- Total: N INSERTs RIDIOMA | M INSERTs RCONTROLES
```
