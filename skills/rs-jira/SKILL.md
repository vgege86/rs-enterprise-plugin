---
name: rs-jira
description: 'Ciclo de vida completo de una tarea de Jira sobre una solución uCollect/RS: seleccionar/crear issue → formatear el requisito → transicionar → asignar → lanzar el pipeline → commit → adjuntar SQL → pasar a validación. Triggers: "/rs-tarea" en un workspace con `docs\.jira-dev-config.json` (el router detecta el gestor y despacha aquí), "trabaja la tarea PROJ-123", "coge/crea una tarea de Jira", "mis tareas de Jira", "descarga los adjuntos de la issue". Requiere el MCP Atlassian Rovo conectado. Envuelve al pipeline rs-enterprise-agent, no lo sustituye.'
---

# RS Jira

Orquestador (main thread) del ciclo de vida de una tarea de Jira sobre una solución uCollect/RS.
Envuelve el pipeline `rs-enterprise-agent` — **no lo modifica**. Jira se opera con el MCP
**Atlassian Rovo** ya conectado; los dos huecos que Rovo no cubre —adjuntar y descargar ficheros—
los dan `mcp__plugin_rs-enterprise-agent_rs-workspace__jira_attach` y `jira_download`, con
credenciales propias.

📎 El detalle de config, credenciales, `defaults`, réplica de la última tarea, subrutina de descarga
y FP de CrowdStrike vive en `references/jira.md`. **Leerla cuando la fase lo pida, no al arrancar.**

# Rol

Coordinador entre Jira y el desarrollo. Prioriza: no perder el hilo del estado en Jira > rapidez |
confirmación antes de toda escritura en Jira > automatismo | reutilizar el pipeline y `/rs-commit`
existentes > reimplementar nada.

# Reglas Globales

- ⛔ **Toda escritura en Jira (crear, transición de estado, asignar, comentario, adjunto) va detrás
  de una confirmación explícita del usuario.** Son acciones outward-facing difíciles de revertir.
- ⛔ No pasar de fase sin la aprobación del usuario de esa fase.
- ⛔ **Nunca imprimir ni loguear el token de Jira** ni el contenido de `~/.claude/rs-jira-credentials.json`.
- No hardcodear nombres de estado ("En Proceso"/"En Validación" cambian por workflow/idioma) —
  resolver siempre las transiciones con `getTransitionsForJiraIssue` + `statusMap` de config.
- No adivinar la `.sln` — **siempre preguntarla** al usuario (Fase 2).
- ⛔ La **Fase 2 no analiza código** — encuadra el requisito desde Jira. El análisis técnico
  (columnas, catálogo, pantallas, "el cómo") es del `rs-editor-planner` en el gate 2b del pipeline.
- No modificar el pipeline: la Fase 3 lo **lanza** con el prompt formateado; el pipeline aplica sus
  propios gates (2b aprobación del plan, 10b checklist, 11 log).

# Auto-verificación (al inicio)

⛔ **Las tools MCP están *deferred* en la sesión** (solo se ve el nombre; el schema no está cargado).
*Deferred ≠ ausente.* Llamarlas directas falla con `InputValidationError` — eso NO significa que el
MCP no exista. Cargar SIEMPRE el schema primero con `ToolSearch("select:<nombre>")`.

1. **Atlassian Rovo** (dependencia real de Fases 1–3, verificar primero) → comprobar si algún
   `mcp__claude_ai_Atlassian_Rovo__*` (`atlassianUserInfo`, `searchJiraIssuesUsingJql`,
   `getJiraIssue`, `transitionJiraIssue`) **aparece en el registro de tools de la sesión, deferred
   incluido**:
   - **aparece** → la integración SÍ está conectada; cargar schema con ToolSearch y llamar
     `atlassianUserInfo` para confirmar auth. ⛔ **No declarar "ausente" solo porque estaba deferred.**
   - **no aparece ninguno** → integración realmente no conectada → avisar ("conecta la integración de
     Jira/Atlassian y reintenta") y ⛔ parar.
   - **aparece pero `atlassianUserInfo` da error de auth** → sesión sin login Rovo → avisar y ⛔ parar.
2. **rs-workspace** → comprobar **solo presencia** del nombre
   `mcp__plugin_rs-enterprise-agent_rs-workspace__ping` en el registro de deferred.
   ⛔ **Nunca ejecutarlo al arranque** — cuelga el turno hasta el timeout de 1800s por el FP de
   CrowdStrike (`references/jira.md` § "MCP `rs-workspace` y el FP de CrowdStrike"). La presencia
   basta; la verificación viva se difiere al primer uso real. Si no aparece ni siquiera entre las
   deferred → el server MCP no está configurado → avisar (reinstalar/actualizar plugin) y ⛔ parar.

# Config del workspace

`docs\.jira-dev-config.json` (carpeta `docs\`, junto a `.rs-databases.json`; el workspace es el cwd
de la sesión). Campos: `projectKey`, `jiraUser`, `cloudId` *(opcional)*, `statusMap`
(`inProgress`/`inValidation`, nombres reales del workflow), `openStatuses` *(opcional; por defecto
`statusCategory = "To Do"`, robusto a idioma)* y `defaults` *(opcional)*. Esquema completo y
semántica de `defaults` → `references/jira.md`.

Si el fichero **no existe** → ofrecer scaffolding (`/rs-tarea init`): proponer el JSON y, ⛔ solo
tras aprobación, escribirlo; recordar añadirlo al ignore de VCS. Las **credenciales** (`baseUrl`,
`email`, `token`) viven aparte en `~/.claude/rs-jira-credentials.json`, fuera del repo — se necesitan
para adjuntar (Fase 4) y para descargar adjuntos (Fase 1 / subrutina `descargar`).

# FASES (flujo estricto, no saltar)

### Fase 1 — Selección de la tarea
- **A) Búsqueda automática** → `searchJiraIssuesUsingJql(cloudId, jql)` con
  `project = <projectKey> AND assignee = <accountId> AND statusCategory = "To Do"` (o los
  `openStatuses` de config). Listar `KEY — resumen (estado)` numerado para que el usuario elija.
- **B) Manual** → el usuario da la KEY (`PROJ-123`) o la URL → `getJiraIssue(cloudId, issueIdOrKey)`.
- **C) Crear** → Fase 1b.
- **Adjuntos** → si `fields.attachment[]` de la issue no está vacío, informar "N adjuntos" y
  **ofrecer** descargarlos (⛔ confirmar) → subrutina `descargar`.

### Fase 1b — Alta de issue (solo si se eligió C)
Espejo de `rs-mantis` Fase 1b. ⛔ Toda escritura tras confirmación.

1. Pedir `issueTypeName`, `summary`, `description` (summary/description pueden derivarse del encuadre
   de Fase 2 si el submodo es crear-y-trabajar). Si `defaults.issueTypeName` existe, proponerlo como
   valor por defecto en vez de preguntar en seco.
2. **Precedencia de campos** (⛔ el primero que informa un campo gana):
   **usuario** > **`defaults` del config** > **réplica de la última tarea** (esta última solo si
   `defaults.replicarUltimaTarea` no es `false`). Excepción: las `labels` **se acumulan** (defaults +
   usuario + las que aporte quien llame a esta fase, sin duplicados) — una etiqueta no pisa a otra.
3. Réplica de la última tarea (qué se copia, blocklist de campos prohibidos) y manejo de error de
   `createJiraIssue` (máx 3 intentos, no crear a ciegas) → `references/jira.md`
   § "Réplica de la última tarea — qué se copia y qué no".
4. ⛔ **Confirmar**: mostrar el objeto completo a enviar (todos los campos + valores, indicando de
   dónde sale cada uno: usuario / `defaults` / última tarea) → permitir editar o quitar antes de crear.
5. `createJiraIssue(cloudId, projectKey, issueTypeName, summary, description, additional_fields)`.
6. Con la KEY creada, dos submodos (aclarar si no se desprende de la petición):
   **crear-y-trabajar** → continuar a Fase 2 | **crear-suelto** → confirmar la KEY y parar aquí.

### Asignación (assignee)
`me` = `accountId` de `atlassianUserInfo` (resuelto en la auto-verificación). Equivale al `-Handler`
de `rs-mantis`. Se asigna **siempre**, sin flag:
- **Al crear** (Fase 1b) → `assignee` en `additional_fields`.
- **Issue existente** → Fase 3 paso 3b →
  `editJiraIssue(cloudId, key, fields = { assignee: { accountId: <me> } })`.

Un **403** (usuario no assignable en el proyecto) **no bloquea**: avisar y seguir el flujo; la
transición ya está hecha, no colgar ni abortar.

### Fase 2 — Encuadre del requisito (NO análisis técnico)
⛔ **Traduce la issue a un requisito accionable — NO analiza el código.** Trabaja **solo** con el
contenido de Jira (título, descripción, comentarios) y lo que aclare el usuario. NO leer el código,
NO llamar a `get_scope`/`find_symbol`/`search_code` ni abrir ficheros fuente, NO decidir el "cómo".
Si la issue es ambigua → **preguntar al usuario**, no explorar el repositorio.

1. `getJiraIssue` → título, descripción y comentarios relevantes.
2. ⛔ **Preguntar al usuario qué `.sln`** corresponde (nunca inferir).
3. Construir el prompt con el formato del pipeline: `<Solucion>.sln - <desarrollo a realizar>`,
   derivado **solo** de la issue y las aclaraciones, sin diseño técnico.
4. Presentarlo y preguntar si ajustar. Iterar hasta **aprobación explícita**. Es la aprobación del
   **requisito** (el qué); el plan técnico (el cómo) se aprueba en el gate 2b del pipeline.

### Fase 3 — Transición a "En Proceso" + lanzamiento
1. ⛔ Confirmar con el usuario antes de tocar Jira. Esta confirmación cubre **cuatro escrituras** —
   enumerarlas al pedirla: comentar el prompt (paso 4), transicionar (pasos 2-3), asignar (paso 3b) y
   lanzar el pipeline (paso 5).
2. `getTransitionsForJiraIssue(cloudId, issueIdOrKey)` → localizar la transición cuyo destino coincide
   con `statusMap.inProgress` (por nombre; si ambiguo, preguntar). Idempotente: si la issue ya está en
   ese estado → saltar la transición.
3. `transitionJiraIssue(cloudId, issueIdOrKey, transition)`.
3b. **Asignar** → `editJiraIssue` (ver "Asignación"). Idempotente; un 403 no bloquea.
4. **Nota del prompt** → `addCommentToJiraIssue(cloudId, issueIdOrKey, body=<prompt aprobado>)`: deja
   en Jira el prompt exacto `<Solucion>.sln - <cambio>` que se pasa al orquestador, para trazar qué
   se lanzó.
5. **Lanzar el pipeline**: continuar como orquestador de `skills/rs-enterprise-agent/SKILL.md`
   (PIPELINE OBLIGATORIO) con el prompt aprobado. Su gate 2b es una aprobación **distinta** de la de
   Fase 2; ambas se mantienen.

### Fase 4 — Commit + cierre ("En Validación")
1. Esperar a que el usuario pida el commit.
2. Ejecutar `/rs-commit` (flujo `detect_vcs` → subagente `rs-commit`, que ramifica SVN/Git). Anotar la
   revisión resultante.
3. Tras confirmar el commit OK. ⚠️ Aquí llega el **primer uso vivo de `rs-workspace`** si la
   subrutina de descarga no se invocó antes: si una llamada **no responde en segundos**, aplicar el
   criterio EDR de `references/jira.md` (reportar cierre **parcial** con la causa, no colgar el turno;
   el commit y las transiciones ya hechos siguen siendo válidos). ⛔ No añadir un `ping` previo.
   - **SQL** → comprobar si hay `.sql` generados en la tarea en
     `C:\AIS\<proyecto-lowercase>\scripts\` (`proyecto` = carpeta anterior a `trunk\`). Si hay →
     ⛔ confirmar → `mcp__plugin_rs-enterprise-agent_rs-workspace__jira_attach(issue_key, files)`.
     Si falta el fichero de credenciales → avisar cómo crearlo (`references/jira.md`) y seguir sin adjuntar.
   - **Transición** → ⛔ confirmar → resolver la transición a `statusMap.inValidation` con
     `getTransitionsForJiraIssue` → `transitionJiraIssue`.
   - **Trazabilidad** → `mcp__plugin_rs-enterprise-agent_rs-workspace__log_execution(workspace,
     solution, task="<KEY>: <resumen>", status, agents)` incluyendo la KEY, para enlazar
     issue↔ejecución en `/rs-historial`.
   - **Nota del resultado** → ⛔ confirmar → `addCommentToJiraIssue(cloudId, issueIdOrKey,
     body=<resumen final>)` con el "Informe final" del paso 4. Si falla, el cierre (commit +
     transición) ya está hecho → reportar cierre parcial, no colgar.
4. **Informe final** escaneable: KEY procesada · estado actual en Jira · ficheros SQL adjuntados (si
   aplica) · revisión de commit. Es el mismo texto que se publicó como nota del resultado.

# Subrutina `/rs-tarea descargar <KEY>`

Descarga adjuntos de una issue a `docs/` del workspace. Requiere `~/.claude/rs-jira-credentials.json`
(mismas credenciales que adjuntar). Procedimiento paso a paso —listado numerado, elección, colisión
de nombres, manejo de error— en `references/jira.md` § "Procedimiento de la subrutina
`/rs-tarea descargar <KEY>`". `jira_download` es uso de `rs-workspace`: mismo criterio EDR que
`jira_attach`.

# Límite

⛔ El MCP Rovo usa autenticación interactiva → esta skill **no** funciona en ejecuciones headless /
cron. Es de uso interactivo.
