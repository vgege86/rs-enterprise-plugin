# Gates del pipeline principal

Detalle de los dos gates bloqueantes del `PIPELINE OBLIGATORIO` (`skills/rs-enterprise-agent/SKILL.md`). El SKILL solo referencia estos gates por nombre; aquí está el procedimiento completo.

---

## Gate A — Aprobación del plan (paso 2b)

**Invariante:** ninguna solicitud de desarrollo (`<Sln>.sln - <cambio>`) toca código sin que el usuario apruebe el `PLAN` del Planner. El Planner emite SIEMPRE su bloque `PLAN`; el orquestador SIEMPRE lo presenta y **detiene el turno** hasta aprobación explícita. Aplica con el Plan Mode del harness ON u OFF:
- Plan Mode ON → la aprobación vía ExitPlanMode del harness satisface el gate.
- Plan Mode OFF → este gate lo garantiza igual: presentar el `PLAN` y terminar el turno, sin encadenar Core en el mismo turno.

**Procedimiento:**
1. Presentar el bloque `PLAN` **tal cual lo emitió el Planner** (no reconstruirlo): objetivo · análisis (símbolos/tablas reales) · etapas de `STAGES` · despliega a AIS (sí/no) · genera/valida tests (sí/no) · impacto en datos/BD · actualiza docs (sí/no).
2. Cerrar con: `¿Apruebas este plan? (aprobado / cambios: <qué ajustar>)`. Terminar el turno ahí.
3. Reanudar en el siguiente mensaje:
   - `aprobado`/`adelante`/`ok` → ejecutar `STAGES`.
   - `cambios: ...` → reinvocar Planner con el ajuste y volver a este gate.
   - Cualquier otra cosa → tratar como no aprobado, no tocar código.

⛔ No invocar `rs-editor-core` ni ninguna etapa de escritura antes de la aprobación.

Si el Planner devolvió `STATUS: NEEDS_INPUT`, resolver esa pregunta con el usuario **antes** de presentar el plan para aprobación.

---

## Gate B — Checklist final (paso previo al Log)

Antes de reportar éxito y registrar en el historial, el orquestador confirma explícitamente, con los `STATUS`/`SUMMARY` ya recibidos de cada etapa (no asumir):

- **Build real:** si `build` estaba en `STAGES`, se ejecutó de verdad (no solo el `compile_check` del validator) y hay evidencia concreta de la copia a AIS (en el `SUMMARY` de `rs-editor-build`).
- **Scripts SQL:** si se generó algún `.sql` (DDL/migración/idiomas), quedó copiado a `C:\AIS\<proyecto-lowercase>\scripts\`, no solo en el repo (ver `FILES_CHANGED` de la etapa que lo generó).
- **Esquema BD vía modelo:** cualquier consulta de esquema usó `model.json` vía tools (`get_table_schema`/`sync_model_tables`), no polling de vistas catálogo.
- **Documentación funcional + resumen:** si el cambio afectó comportamiento/estructura/tablas, `documentar` se ejecutó y actualizó la doc **funcional** y el **resumen por-solución** (`soluciones/<Sln>.md`) — hay `FILES_CHANGED` de `rs-documentar` en esos árboles. Si el run cerró OK y no se ejecutó → completarlo ahora; si quedó `partial` → avisar "⚠️ Docs pendientes — /rs-doc".
- **Manual técnico (patrón nuevo):** si `core` devolvió `NEW_PATTERN`, confirmar que `documentar` produjo una `TECNICA_PROPUESTA` y que el orquestador la **surfaceó** en el reporte final como acción pendiente de confirmación. ⛔ NO exigir que esté aplicada — el manual de convenciones solo se escribe tras confirmación humana explícita; el gate solo garantiza que la propuesta no se pierde.

⛔ Si falta cualquiera de estos → completarlo antes de continuar, no reportar éxito.

---

## Log (última instrucción, SIEMPRE)

Incluso si algún paso falló:
```
mcp__plugin_rs-enterprise-agent_rs-workspace__log_execution(workspace, solution, task,
  status="success|fail|partial",
  agents="<etapas de STAGES realmente ejecutadas, ej: core, validator, tester, build>")
```
Si se omite, el historial queda incompleto y `/rs-historial` mostrará datos incorrectos.
