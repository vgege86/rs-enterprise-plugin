---
name: rs-jira
description: 'Orquestador del ciclo de vida de una tarea de Jira sobre una solución uCollect/RS: seleccionar/crear issue → formatear el requisito → transicionar estado → asignar → lanzar el pipeline de desarrollo → commit → adjuntar scripts SQL → transicionar a validación. Usar cuando el usuario quiere trabajar una tarea de Jira: "/rs-tarea" en un workspace con `docs\.jira-dev-config.json` (el router `/rs-tarea` detecta el gestor y despacha aquí), "trabaja la tarea PROJ-123", "coge una tarea de Jira", "crea una tarea en Jira", "mis tareas de Jira", "issue de Jira", "descarga los adjuntos de la issue". Requiere el MCP Atlassian Rovo conectado. NO sustituye al pipeline rs-enterprise-agent — lo envuelve.'
---

# RS Jira

Orquestador (main thread) del ciclo de vida de una tarea de Jira sobre una solución uCollect/RS.
Envuelve el pipeline `rs-enterprise-agent` — **no lo modifica**. Jira se opera con el MCP
**Atlassian Rovo** ya conectado (búsqueda, lectura, transición, comentario, crear, asignar); los dos
huecos — adjuntar y descargar ficheros — los cubren `mcp__plugin_rs-enterprise-agent_rs-workspace__jira_attach`
y `jira_download`, con credenciales propias.

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
- ⛔ La **Fase 2 no analiza código** — encuadra el requisito desde Jira (issue + comentarios) y
  aclaraciones del usuario. El análisis técnico (columnas, catálogo, pantallas, "el cómo") es del
  `rs-editor-planner` en el gate 2b del pipeline, no de esta skill.
- No modificar el pipeline: la Fase 3 lo **lanza** con el prompt formateado; el pipeline aplica sus
  propios gates (2b aprobación del plan, 10b checklist, 11 log).

# Auto-verificación (al inicio)

⛔ **Antes de nada: las tools MCP están *deferred* en la sesión** (solo se ve el nombre; el schema no
está cargado). *Deferred ≠ ausente.* Llamarlas directas falla con `InputValidationError` — eso NO
significa que el MCP no exista. Cargar SIEMPRE el schema primero con ToolSearch:
`ToolSearch("select:mcp__claude_ai_Atlassian_Rovo__atlassianUserInfo")`.

⛔ **NUNCA llamar a `mcp__plugin_rs-enterprise-agent_rs-workspace__ping` (ni a ninguna tool `rs-workspace`) en el arranque.** Bajo
CrowdStrike el proceso `python.exe` del MCP queda bloqueado y la llamada **no responde hasta el timeout
de 1800s** (FP conocido, `docs/crowdstrike-fp-justification.md`) — congela el turno entero. El modelo NO
puede "detectar" ese cuelgue: una tool call bloqueante simplemente espera. Por eso aquí solo se
comprueba **presencia en el registro**, nunca se ejecuta. La dependencia real de Fases 1–3 es
**Atlassian Rovo**; `rs-workspace` no se toca al arranque en ningún caso. Su primer uso **vivo** llega
con la primera llamada real que se haga a una de sus tools — que puede ser **antes** de Fase 4 si el
usuario acepta la oferta de descarga de adjuntos (Fase 1) o ejecuta `/rs-tarea descargar`
(`jira_download`), o si no, en Fase 4 (`jira_attach`/`log_execution`). La verificación viva de
`rs-workspace` siempre se difiere a ese primer uso real, sea cual sea.

1. **Atlassian Rovo** (dependencia real de Fases 1–3, verificar primero) → comprobar si el nombre
   `mcp__claude_ai_Atlassian_Rovo__atlassianUserInfo` (u otras `...Atlassian_Rovo__*`:
   `searchJiraIssuesUsingJql`, `getJiraIssue`, `transitionJiraIssue`) **aparece en el registro de tools
   de la sesión (deferred incluido)**:
   - **aparece** → la integración SÍ está conectada; cargar schema con ToolSearch y llamar
     `atlassianUserInfo` para confirmar auth. **No declarar "ausente" solo porque estaba deferred.**
   - **no aparece ningún `...Atlassian_Rovo__*`** en el registro → integración realmente no conectada
     → avisar ("conecta la integración de Jira/Atlassian y reintenta") y ⛔ parar.
   - **aparece pero `atlassianUserInfo` da error de auth** → sesión sin login Rovo (interactivo) →
     avisar y ⛔ parar.
2. **rs-workspace** (solo presencia, ⛔ **sin llamar a `ping`**) → comprobar únicamente que el nombre
   `mcp__plugin_rs-enterprise-agent_rs-workspace__ping` **aparece en el registro** de tools deferred de la sesión:
   - **aparece** → suficiente para seguir; la comprobación viva se hace en el primer uso real (descarga
     de adjuntos en Fase 1/`descargar`, o si no, `jira_attach`/`log_execution` en Fase 4).
   - **no aparece** ni siquiera en la lista de deferred → el server MCP no está configurado en la sesión
     → avisar (reinstalar/actualizar plugin) y ⛔ parar.

# Config del workspace

Leer `docs\.jira-dev-config.json` del workspace (carpeta `docs\`, junto a `.rs-databases.json`; el
workspace es el cwd de la sesión). Campos:
- `projectKey` — clave del proyecto Jira (ej. `PROJ`).
- `jiraUser` — email o accountId del desarrollador (por defecto, el de `atlassianUserInfo`).
- `cloudId` *(opcional)* — id del site Atlassian; si falta → `getAccessibleAtlassianResources` y
  confirmar con el usuario cuál usar.
- `statusMap` — `{ "inProgress": "<nombre estado>", "inValidation": "<nombre estado>" }`
  (nombres reales del workflow del proyecto).
- `openStatuses` *(opcional)* — lista de estados considerados "abiertos" en Fase 1; por defecto se
  usa `statusCategory = "To Do"` (robusto a idioma).

Si el fichero **no existe** → ofrecer scaffolding (`/rs-tarea init`): proponer el JSON con los
campos y, ⛔ solo tras aprobación, escribirlo. Recordar añadirlo al ignore de VCS. Las
**credenciales** (`baseUrl`, `email`, `token` para adjuntar) viven aparte en
`~/.claude/rs-jira-credentials.json` (fuera del repo) — se necesitan en la Fase 4 si hay SQL
que adjuntar, y también en Fase 1 si se descargan adjuntos (oferta + subrutina `/rs-tarea descargar`);
ver `references/jira.md`.

# FASES (flujo estricto, no saltar)

### Fase 1 — Selección de la tarea
Ofrecer tres vías:
- **A) Búsqueda automática** → `searchJiraIssuesUsingJql(cloudId, jql)` con
  `project = <projectKey> AND assignee = <accountId> AND statusCategory = "To Do"`
  (o los `openStatuses` de config). Listar `KEY — resumen (estado)` numerado para que el usuario elija.
- **B) Manual** → el usuario da la KEY (`PROJ-123`) o la URL → `getJiraIssue(cloudId, issueIdOrKey)`.
- **C) Crear** (`createJiraIssue`) → alta de una issue nueva. Ver "Fase 1b — Alta de issue".
- **Adjuntos** → si `fields.attachment[]` de la issue no está vacío, informar "N adjuntos" y **ofrecer**
  descargarlos (⛔ confirmar). Si acepta → descargar todos a `docs/` (ver subrutina "descargar").

### Fase 1b — Alta de issue (solo si se eligió C en Fase 1)
Espejo de `rs-mantis` Fase 1b. ⛔ Toda escritura tras confirmación.

1. Pedir `issueTypeName`, `summary`, `description` (summary/description pueden derivarse del encuadre
   de Fase 2 si el submodo es crear-y-trabajar).
2. **Replicar "todos los informados" de la última tarea** del usuario:
   - `searchJiraIssuesUsingJql(cloudId, "project = <projectKey> AND assignee = <me> ORDER BY created DESC")`
     → `getJiraIssue` del primer resultado.
   - Copiar a `additional_fields` los campos **no vacíos**, con esta **blocklist (nunca copiar)**:
     `summary`, `description`, `reporter`, `creator`, `created`, `updated`, `status`, `resolution`,
     `comment`, `attachment`, `worklog`, `votes`, `watches`, `timetracking`, `progress`,
     `aggregateprogress`, `subtasks`, `issuelinks`, `key`, `project`, `lastViewed`, `workratio`.
   - **Copiar si informado**: `priority`, `components`, `labels`, `versions`, `fixVersions`,
     `duedate`, `environment`, y cualquier `customfield_*` con valor no vacío. `issuetype` lo fija el
     usuario en el paso 1 (no se copia de la última tarea).
   - Incluir además `assignee = { accountId: <me> }` (ver "Asignación").
3. ⛔ **Confirmar**: mostrar al usuario el objeto completo a enviar (todos los campos + valores) →
   permitir editar/quitar antes de crear.
4. `createJiraIssue(cloudId, projectKey, issueTypeName, summary, description, additional_fields)`
   (deferred: `ToolSearch("select:mcp__claude_ai_Atlassian_Rovo__createJiraIssue")` antes de llamar).
   Manejo de error: si Jira devuelve `field is required` / `is invalid` / `cannot be set` → mostrar el
   error tal cual, **quitar o preguntar** el campo señalado y reintentar. **Máx 3 intentos**; si sigue
   fallando → reportar el último error y ⛔ parar (no crear a ciegas; sin `createmeta` en Rovo, el
   error de Jira es la red de seguridad).
5. Con la KEY creada, dos submodos (aclarar con el usuario si no se desprende de la petición):
   - **crear-y-trabajar** → continuar a Fase 2 con la issue creada.
   - **crear-suelto** → confirmar la KEY y parar aquí (alta sin arrancar desarrollo).

### Asignación (assignee)
`me` = `accountId` de `atlassianUserInfo` (resuelto en la auto-verificación). Equivale al `-Handler`
de `rs-mantis`. Se asigna **siempre** (sin flag):
- **Al crear** (Fase 1b) → `assignee` en `additional_fields`.
- **Issue existente** → en Fase 3, tras la transición a "En Proceso":
  `editJiraIssue(cloudId, key, fields = { assignee: { accountId: <me> } })` (deferred:
  `ToolSearch("select:mcp__claude_ai_Atlassian_Rovo__editJiraIssue")`). Si Jira devuelve **403**
  (usuario no assignable en el proyecto) → avisar y **seguir** el flujo; la transición ya está hecha,
  no colgar ni abortar.

### Fase 2 — Encuadre del requisito (NO análisis técnico)
⛔ **Esta fase traduce la issue a un requisito accionable — NO analiza el código.** Trabaja
**solo** con el contenido de Jira (título, descripción, comentarios) y lo que aclare el usuario.
NO leer el código de la solución, NO llamar a `get_scope`/`find_symbol`/`search_code` ni abrir
ficheros fuente, NO decidir el "cómo" (qué columnas, qué nº de catálogo, qué pantalla). Ese
análisis técnico lo hace `rs-editor-planner` **dentro** del pipeline (gate 2b); aquí solo se
define el **qué**. Si la issue es ambigua → **preguntar al usuario**, no explorar el repositorio.

1. `getJiraIssue` → título, descripción y comentarios relevantes.
2. ⛔ **Preguntar al usuario qué `.sln`** corresponde (nunca inferir).
3. Construir la propuesta de prompt en Markdown con el formato del pipeline:
   `<Solucion>.sln - <desarrollo a realizar>` (resumen accionable derivado **solo** de la issue y
   las aclaraciones del usuario, sin diseño técnico).
4. Presentarla y preguntar si ajustar/complementar. Iterar hasta **aprobación explícita**. Esta
   aprobación es del **requisito** (el qué); el plan técnico (el cómo) lo aprueba el usuario en el
   gate 2b del pipeline (Fase 3).

### Fase 3 — Transición a "En Proceso" + lanzamiento
1. ⛔ Confirmar con el usuario antes de tocar Jira. Esta confirmación cubre **cuatro escrituras**:
   comentar el prompt (paso 4), transicionar a "En Proceso" (pasos 2-3), asignar la issue (paso 3b) y
   lanzar el pipeline (paso 5). Enumerarlas al pedir la confirmación.
2. `getTransitionsForJiraIssue(cloudId, issueIdOrKey)` → localizar la transición cuyo destino
   coincide con `statusMap.inProgress` (por nombre; si ambiguo, preguntar). Idempotente: si la
   issue ya está en ese estado → saltar la transición.
3. `transitionJiraIssue(cloudId, issueIdOrKey, transition)`.
3b. **Asignar al desarrollador** → `editJiraIssue(cloudId, issueIdOrKey, fields={ assignee:{ accountId: <me> } })`
    (ver "Asignación"). Idempotente: si ya está asignada a `me`, no cambia. Un 403 no bloquea: avisar y seguir.
4. **Nota del prompt** → `addCommentToJiraIssue(cloudId, issueIdOrKey, body=<prompt aprobado>)`: dejar
   como comentario el prompt exacto `<Solucion>.sln - <cambio>` que se pasará al orquestador, para
   trazar en Jira qué se lanzó. (Deferred: cargar schema con
   `ToolSearch("select:mcp__claude_ai_Atlassian_Rovo__addCommentToJiraIssue")` antes de llamar.)
5. **Lanzar el pipeline**: continuar como orquestador de `skills/rs-enterprise-agent/SKILL.md`
   (PIPELINE OBLIGATORIO) con el prompt aprobado `<Solucion>.sln - <cambio>`. El pipeline aplica su
   propio gate 2b (aprobación del plan técnico) — es una aprobación **distinta** de la Fase 2
   (encuadre del requisito); ambas se mantienen.

### Fase 4 — Commit + cierre ("En Validación")
1. Esperar a que el usuario pida el commit.
2. Ejecutar `/rs-commit` (flujo `detect_vcs` → subagente `rs-commit`, que ramifica SVN/Git). Anotar la
   revisión resultante.
3. Tras confirmar el commit OK:
   - ⚠️ **Primer uso vivo de `rs-workspace` en el flujo principal** (la subrutina de descarga de Fase 1,
     si se invocó antes, ya lo habrá tocado). Si la llamada a `jira_attach` (o
     `log_execution`) **no responde en segundos** → proceso MCP `python.exe` bloqueado por el EDR
     (CrowdStrike FP, `docs/crowdstrike-fp-justification.md`). El commit y las transiciones de Jira **ya
     están hechos**; reportar cierre **parcial** (sin adjunto/log, con la causa EDR) en vez de colgar el
     turno. No añadir un `ping` previo: la propia `jira_attach` es la verificación viva.
   - **SQL** → comprobar si hay `.sql` en `C:\AIS\<proyecto-lowercase>\scripts\` generados en la
     tarea (`proyecto` = carpeta anterior a `trunk\`). Si hay → ⛔ confirmar → `mcp__plugin_rs-enterprise-agent_rs-workspace__jira_attach(issue_key, files)` (adjunto real; requiere `~/.claude/rs-jira-credentials.json`).
     Si falta el fichero de credenciales → avisar cómo crearlo (`references/jira.md`) y seguir sin adjuntar.
   - **Transición** → ⛔ confirmar → resolver la transición a `statusMap.inValidation` con
     `getTransitionsForJiraIssue` → `transitionJiraIssue`.
   - **Trazabilidad** → `mcp__plugin_rs-enterprise-agent_rs-workspace__log_execution(workspace, solution, task="<KEY>: <resumen>", status, agents)`
     incluyendo la KEY de Jira, para enlazar issue↔ejecución en `/rs-historial`.
   - **Nota del resultado** → ⛔ confirmar → `addCommentToJiraIssue(cloudId, issueIdOrKey, body=<resumen
     final>)`: dejar como comentario el mismo resumen final de la tarea (el "Informe final" del paso 4:
     qué se hizo, ficheros SQL adjuntados, revisión de commit, estado). Cierra la trazabilidad en la
     propia issue. (Deferred: cargar schema con
     `ToolSearch("select:mcp__claude_ai_Atlassian_Rovo__addCommentToJiraIssue")` antes de llamar.) Si
     `addCommentToJiraIssue` falla, el cierre (commit + transición) ya está hecho → reportar cierre
     parcial (sin nota), no colgar.
4. **Informe final** escaneable: KEY procesada · estado actual en Jira · ficheros SQL adjuntados
   (si aplica) · revisión de commit. Es el mismo texto que se publicó como nota del resultado.

# Subrutina `/rs-tarea descargar <KEY>`

Descarga adjuntos de una issue a `docs/` del workspace. Requiere `~/.claude/rs-jira-credentials.json`
(mismas credenciales que adjuntar; ver `references/jira.md`).

1. `getJiraIssue(cloudId, KEY)` → de `fields.attachment[]` listar `id — filename (size)` numerados.
   Si no hay adjuntos → informar y parar.
2. El usuario elige uno, varios, o "todos".
3. Por cada adjunto elegido: `out = docs/<filename>` (si `docs/<filename>` ya existe → sufijo `_2`,
   `_3`, ...) → `mcp__plugin_rs-enterprise-agent_rs-workspace__jira_download(issue_key=KEY, file_id=<id>, out=<out>)`.
   - ⚠️ `jira_download` es uso de `rs-workspace` (MCP Python): si **no responde en segundos** → proceso
     bloqueado por el EDR (CrowdStrike FP, `docs/crowdstrike-fp-justification.md`); reportar el hueco
     y no colgar (mismo criterio que `jira_attach`).
   - Si `success:false` (credenciales/404) → mostrar `error` y seguir con el resto de ficheros.
4. Reportar los ficheros descargados con su ruta en `docs/`.

# Límite

⛔ El MCP Rovo usa autenticación interactiva → esta skill **no** funciona en ejecuciones headless /
cron. Es de uso interactivo.
