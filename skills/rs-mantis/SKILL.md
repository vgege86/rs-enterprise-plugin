---
name: rs-mantis
description: 'Orquestador del ciclo de vida de una tarea de MantisBT sobre una solución uCollect/RS: seleccionar/crear issue → formatear el requisito → transicionar estado → lanzar el pipeline de desarrollo → commit → adjuntar scripts SQL → transicionar a validación. Usar cuando el usuario quiere trabajar una tarea de Mantis: "/rs-mantis", "trabaja la tarea Mantis 1234", "crea una tarea en Mantis", "mis tareas de Mantis", "issue de Mantis". No requiere MCP: usa el cliente REST autónomo `hooks/mantis-cli.ps1` con token de API. NO sustituye al pipeline rs-enterprise-agent — lo envuelve.'
---

# RS Mantis

Orquestador (main thread) del ciclo de vida de una tarea de MantisBT sobre una solución uCollect/RS.
Envuelve el pipeline `rs-enterprise-agent` — **no lo modifica**. A diferencia de `rs-jira`, MantisBT
**no tiene MCP** (no hay Atlassian Rovo equivalente): toda la interacción — leer, listar, crear,
transicionar, comentar, adjuntar — pasa por el cliente REST autónomo `hooks/mantis-cli.ps1`
(PowerShell, invocado vía Bash), con autenticación por **API token**. Esta skill además puede
**crear** tareas nuevas, algo que `rs-jira` no hace.

# Rol

Coordinador entre Mantis y el desarrollo. Prioriza: no perder el hilo del estado en Mantis > rapidez |
confirmación antes de toda escritura en Mantis > automatismo | reutilizar el pipeline y `/rs-commit`
existentes > reimplementar nada.

# Reglas Globales

- ⛔ **Toda escritura en Mantis (crear issue, transicionar estado, comentar, adjuntar) va detrás de
  una confirmación explícita del usuario.** Son acciones outward-facing difíciles de revertir.
- ⛔ No pasar de fase sin la aprobación del usuario de esa fase.
- ⛔ **Nunca imprimir ni loguear el token de Mantis** ni el contenido de
  `~/.claude/rs-mantis-credentials.json`. `mantis-cli.ps1` ya redacta el token en sus mensajes de
  error (`Protect-MantisToken`), pero no reproducir el fichero de credenciales por ningún motivo.
- No hardcodear nombres de estado ("assigned"/"confirmed" pueden variar por instalación) — resolver
  siempre las transiciones con el `statusMap` y el `statusChain` de `docs\.mantis-dev-config.json`.
- Esta instancia usa un workflow **encadenado, sin saltos** (`statusChain`:
  `new → acknowledged → assigned → confirmed`, ver Fases 3 y 4): mover una issue varios estados va
  siempre por `advance` (recorre la cadena paso a paso), nunca por `transition` suelto salvo que el
  salto sea de un solo paso.
- No adivinar la `.sln` — **siempre preguntarla** al usuario (Fase 2).
- ⛔ La **Fase 2 no analiza código** — encuadra el requisito desde la issue de Mantis (resumen,
  descripción, notas) y aclaraciones del usuario. El análisis técnico (columnas, catálogo,
  pantallas, "el cómo") es del `rs-editor-planner` en el gate 2b del pipeline, no de esta skill.
- No modificar el pipeline: la Fase 3 lo **lanza** con el prompt formateado; el pipeline aplica sus
  propios gates (2b aprobación del plan, 10b checklist, 11 log).
- MantisBT no tiene endpoint de "transiciones" como Jira: el estado es un **campo** que se cambia
  con `transition -Id -Status <nombre>` (`PATCH /issues/{id}`). Un nombre de estado desconocido
  devuelve el error tal cual lo reporta Mantis — revisar `statusMap` o usar `get` para ver el estado
  actual.

# Raíz del plugin (`plugin_root`)

Todas las llamadas a `mantis-cli.ps1` usan la ruta **absoluta** del hook, no `${CLAUDE_PLUGIN_ROOT}`
(no fiable en markdown — ver `skills/rs-enterprise-agent/SKILL.md` § Raíz del plugin). Resolución:
1. Partir de la ruta de esta skill (la que Claude Code inyecta). Si termina en `\skills\rs-mantis`,
   subir **dos** niveles.
2. Verificar con Glob que la ruta resultante contiene `hooks\` (donde vive `mantis-cli.ps1`).
3. Si no la contiene, subir un nivel más y repetir (máx. 3 saltos).
4. Si tras los 3 saltos no aparece → ⛔ detener y pedir la ruta al usuario. Nunca inventarla.

# Auto-verificación (al inicio)

A diferencia de `rs-jira`, aquí **no hay MCP que verificar** (ni Atlassian Rovo ni equivalente):
toda la integración es el hook `mantis-cli.ps1`.

1. **Credenciales** → comprobar con Bash que `~/.claude/rs-mantis-credentials.json` existe, p. ej.
   `powershell -NoProfile -Command "Test-Path (Join-Path $env:USERPROFILE '.claude\rs-mantis-credentials.json')"`.
   - **no existe** → explicar cómo crearlo (JSON `{ "baseUrl", "token" }`; token desde *Mantis → My
     Account → API Tokens → Create* — ver `<plugin_root>/references/mantis.md`) y ⛔ parar. No
     intentar adivinar valores ni crear el fichero por el usuario (son credenciales suyas).
   - **existe** → seguir; el contenido no se lee/imprime aquí — `mantis-cli.ps1` lo valida en cada
     llamada.
2. **Config del workspace** → leer `docs\.mantis-dev-config.json` (ver más abajo). Si falta →
   ofrecer `/rs-mantis init` (subrutina) y ⛔ parar hasta que exista (la Fase 0 la necesita).
3. ⛔ **NUNCA llamar a `mcp__plugin_rs-enterprise-agent_rs-workspace__ping`** (ni a ninguna tool
   `rs-workspace`) en el arranque — mismo motivo que en `rs-jira`: bajo CrowdStrike el proceso
   `python.exe` del MCP queda bloqueado y la llamada **no responde hasta el timeout de 1800s** (FP
   conocido, `docs/crowdstrike-fp-justification.md`). `rs-workspace` solo se usa en la **Fase 4**
   (`log_execution`); su verificación viva se difiere allí. Basta comprobar que el nombre
   `mcp__plugin_rs-enterprise-agent_rs-workspace__log_execution` **aparece en el registro de tools**
   de la sesión (deferred incluido) — si no aparece ni como deferred, avisar (reinstalar/actualizar
   el plugin) pero seguir igualmente: Fase 4 solo perdería la trazabilidad de `/rs-historial`, no
   bloquea el cierre.

# Cómo se llama al hook (`mantis-cli.ps1`)

Toda operación Mantis de esta skill es una llamada Bash al hook, nunca una tool MCP:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin_root>/hooks/mantis-cli.ps1" -Command <cmd> [-Id <n>] [-Project <n>] [...]
```

- La salida es una única línea JSON. Parsearla y comprobar `success`:
  - `true` → usar los campos de datos (`projects`, `issues`, `issue`, `id`, `attached`, ...).
  - `false` → mostrar `error` al usuario tal cual (ya viene con el token redactado) y **parar la
    fase** — no reintentar automáticamente, no inventar datos.
- ⛔ **Nunca imprimir el token** ni el contenido crudo de `~/.claude/rs-mantis-credentials.json` —
  ni siquiera al depurar un fallo. El hook ya se encarga de redactarlo en sus errores.
- Subcomandos reales del hook (detalle completo en `<plugin_root>/references/mantis.md`):
  `projects`, `list -Project <id> [-PageSize <n>]`, `get -Id <n>`,
  `create -Project <id> -Category <s> -Summary <s> -Description <s> [-Handler <id>]`,
  `transition -Id <n> -Status <nombre>` (salto directo de un paso — no usar para avanzar varios
  estados, ver `advance`), `advance -Id <n> -To <nombre> -Chain <csv> [-Handler <id>]
  [-HandlerStatus <nombre>]` (recorre `statusChain` paso a paso desde el estado actual hasta `-To`,
  sin saltarse ninguno; devuelve `applied` con los estados por los que pasó), `me` (→
  `{id,name,real_name}`, usuario del token — sin argumentos), `comment -Id <n> -Text <s>`,
  `attach -Id <n> -Files <a,b>`, `download -Id <n> -FileId <f> -Out <ruta>`.

# Config del workspace

Leer `docs\.mantis-dev-config.json` del workspace (carpeta `docs\`, junto a `.rs-databases.json`; el
workspace es el cwd de la sesión). Campos:
- `projects` — lista curada `[{ id, name }, ...]` de proyectos Mantis del cliente (gestionada con
  `/rs-mantis proyectos`).
- `defaultCategory` — categoría por defecto al crear una issue (p. ej. `"General"`).
- `statusChain` — array **ordenado** de nombres de estado del workflow de la instancia, tal como los
  recorre `advance` sin saltarse ninguno (p. ej. `["new", "acknowledged", "assigned", "confirmed"]`
  — verificado en vivo en la instancia objetivo, ver `references/mantis.md`).
- `statusMap` — `{ "inProgress": "<nombre estado>", "inValidation": "<nombre estado>" }`, atajos
  dentro de `statusChain` que usan las Fases 3 y 4: `inProgress` = estado de "En Proceso" (en la
  instancia objetivo, `assigned` = Asignada) e `inValidation` = estado de "En Validación" (en la
  instancia objetivo, `confirmed` = Confirmada — nombres reales del workflow, confirmar con `get` o
  `/rs-mantis proyectos` si no se conocen).

Si el fichero **no existe** → ofrecer `/rs-mantis init` (subrutina más abajo). Las **credenciales**
(`baseUrl`, `token`) viven aparte en `~/.claude/rs-mantis-credentials.json` (fuera del repo) — ver
`references/mantis.md`.

# FASES (flujo estricto, no saltar)

### Fase 0 — Proyecto
Leer `projects[]` de la config → listar `id — nombre` numerado → el usuario elige el proyecto de la
tarea. Si la lista está vacía o la config no existe → derivar a `/rs-mantis proyectos` (subrutina)
antes de continuar.

### Fase 1 — Tarea
Dos ramas:
- **a) Existente** →
  - `mantis-cli.ps1 list -Project <id>` → el hook trae **todas** las issues del proyecto (sin
    filtro de estado — Mantis no lo ofrece en este endpoint); filtrar en la respuesta las que NO
    estén cerradas/resueltas y listar `id — resumen (estado)` numeradas para elegir, o
  - el usuario da directamente el **id global** de la issue → `mantis-cli.ps1 get -Id <n>`.
- **b) Crear** (`create`) → pedir categoría (por defecto `defaultCategory` de la config), resumen y
  descripción → ⛔ confirmar → `mantis-cli.ps1 create -Project <id> -Category <s> -Summary <s>
  -Description <s>`. Con el `id` devuelto, dos submodos (aclarar con el usuario cuál si no se
  desprende ya de su petición inicial):
  - **crear-y-trabajar** → continuar a la Fase 2 con la issue recién creada.
  - **crear-suelto** → alta y fin: confirmar el `id` creado y parar aquí (registro de tarea/bug sin
    arrancar desarrollo).

### Fase 2 — Encuadre del requisito (NO análisis técnico)
⛔ **Esta fase traduce la issue a un requisito accionable — NO analiza el código.** Trabaja **solo**
con el contenido de Mantis (resumen, descripción, notas de la issue) y lo que aclare el usuario. NO
leer el código de la solución, NO llamar a `get_scope`/`find_symbol`/`search_code` ni abrir ficheros
fuente, NO decidir el "cómo" (qué columnas, qué nº de catálogo, qué pantalla). Ese análisis técnico
lo hace `rs-editor-planner` **dentro** del pipeline (gate 2b); aquí solo se define el **qué**. Si la
issue es ambigua → **preguntar al usuario**, no explorar el repositorio.

1. Partir del `issue` obtenido en Fase 1 (`get`/`create`): resumen, descripción y notas relevantes.
2. ⛔ **Preguntar al usuario qué `.sln`** corresponde (nunca inferir).
3. Construir la propuesta de prompt en Markdown con el formato del pipeline:
   `<Solucion>.sln - <desarrollo a realizar>` (resumen accionable derivado **solo** de la issue y
   las aclaraciones del usuario, sin diseño técnico).
4. Presentarla y preguntar si ajustar/complementar. Iterar hasta **aprobación explícita**. Esta
   aprobación es del **requisito** (el qué); el plan técnico (el cómo) lo aprueba el usuario en el
   gate 2b del pipeline (Fase 3).

### Fase 3 — En Proceso + lanzamiento
1. **Resolver el desarrollador** → `mantis-cli.ps1 me` → tomar `id` de la respuesta (usuario del
   token). No requiere confirmación (es una lectura); se necesita antes del paso 3 para fijar el
   handler.
2. ⛔ Confirmar con el usuario antes de tocar Mantis. Esta confirmación cubre **tres escrituras**:
   avanzar el estado a "En Proceso" (paso 3), comentar el prompt (paso 4) y lanzar el pipeline
   (paso 5). Enumerarlas al pedir la confirmación.
3. **Avance de estado** → `mantis-cli.ps1 advance -Id <n> -To <statusMap.inProgress> -Chain
   "<statusChain joined by ','>" -Handler <me.id> -HandlerStatus <statusMap.inProgress>`. Esto
   recorre la cadena (p. ej. Nueva→Aceptada→Asignada) paso a paso sin saltar ninguno, y en el paso
   que llega a `statusMap.inProgress` fija además el `handler` al desarrollador resuelto en el
   paso 1. `advance` es **idempotente hacia delante**: si la issue ya está en `statusMap.inProgress`
   (o después, dentro de la cadena) no hace ningún cambio y devuelve `applied: []`. Si `success` es
   `false`, mostrar el `error` tal cual (puede incluir qué pasos sí se aplicaron antes de fallar,
   `Aplicados: ...`) y **parar la fase** — no reintentar automáticamente ni asumir que se alcanzó el
   estado destino.
4. **Nota del prompt** → `mantis-cli.ps1 comment -Id <n> -Text "<prompt aprobado>"`: dejar como nota
   el prompt exacto `<Solucion>.sln - <cambio>` que se pasará al orquestador, para trazar en Mantis
   qué se lanzó.
5. **Lanzar el pipeline**: continuar como orquestador de `skills/rs-enterprise-agent/SKILL.md`
   (PIPELINE OBLIGATORIO) con el prompt aprobado `<Solucion>.sln - <cambio>`. El pipeline aplica su
   propio gate 2b (aprobación del plan técnico) — es una aprobación **distinta** de la Fase 2
   (encuadre del requisito); ambas se mantienen.

### Fase 4 — Commit + cierre ("En Validación")
1. Esperar a que el usuario pida el commit.
2. Ejecutar `/rs-commit` (flujo `detect_vcs` → subagente `rs-commit`, que ramifica SVN/Git). Anotar
   la revisión resultante.
3. Tras confirmar el commit OK — **orden estricto: primero confirmar el estado, después adjuntar**
   (protocolo del cliente: "cuando el orquestador termina se pasa a Confirmada y es cuando se suben
   los scripts"):
   - **Avance de estado** → ⛔ confirmar → `mantis-cli.ps1 advance -Id <n> -To
     <statusMap.inValidation> -Chain "<statusChain joined by ','>"` (recorre Asignada→Confirmada sin
     saltar pasos; idempotente hacia delante igual que en Fase 3). Si `success` es `false`, mostrar
     el `error` (incluye `applied` con los pasos que sí se llegaron a aplicar antes del fallo) y
     **parar aquí** — no adjuntar scripts sobre una issue que no llegó a "En Validación".
   - **SQL** → solo **una vez confirmado** el paso anterior: comprobar si hay `.sql` en
     `C:\AIS\<proyecto-lowercase>\scripts\` generados en la tarea (`proyecto` = carpeta anterior a
     `trunk\`). Si hay → ⛔ confirmar → `mantis-cli.ps1 attach -Id <n> -Files <a,b>` (adjunto real;
     requiere `~/.claude/rs-mantis-credentials.json`). Si el hook falla por credenciales, avisar
     cómo crearlas (`references/mantis.md`) y seguir sin adjuntar.
   - ⚠️ **Primer uso vivo de `rs-workspace` en toda la skill** (mismo hueco que en `rs-jira`) →
     **Trazabilidad** → `mcp__plugin_rs-enterprise-agent_rs-workspace__log_execution(workspace,
     solution, task="Mantis #<id>: <resumen>", status, agents)` incluyendo el id de Mantis, para
     enlazar issue↔ejecución en `/rs-historial`. Si la llamada **no responde en segundos** → proceso
     MCP `python.exe` bloqueado por el EDR (CrowdStrike FP,
     `docs/crowdstrike-fp-justification.md`). El commit y las transiciones de Mantis **ya están
     hechos**; reportar cierre **parcial** (sin log, con la causa EDR) en vez de colgar el turno.
   - **Nota del resultado** → ⛔ confirmar → `mantis-cli.ps1 comment -Id <n> -Text "<resumen
     final>"`: dejar como nota el mismo resumen final de la tarea (el "Informe final" del paso 4: qué
     se hizo, ficheros SQL adjuntados, revisión de commit, estado). Si falla, el cierre (commit +
     transición) ya está hecho → reportar cierre parcial (sin nota), no colgar.
4. **Informe final** escaneable: id de Mantis procesado · estado actual en Mantis · ficheros SQL
   adjuntados (si aplica) · revisión de commit. Es el mismo texto que se publicó como nota del
   resultado.

# Subrutina `/rs-mantis proyectos`

Gestiona la lista curada `projects[]` de `docs\.mantis-dev-config.json`:
1. `mantis-cli.ps1 projects` → listar **todos** los proyectos que ve el token, numerados
   `id — nombre (estado)`.
2. El usuario selecciona uno o varios → elegir modo:
   - **Añadir** → `projects` existente + los seleccionados, sin duplicar por `id`.
   - **Crear** → reemplaza `projects` con los seleccionados.
3. ⛔ Confirmar el contenido final antes de escribir `docs\.mantis-dev-config.json`.

# Subrutina `/rs-mantis init`

Scaffolding de `docs\.mantis-dev-config.json`:
1. Proponer el JSON con `projects: []`, `defaultCategory: "General"`, un `statusChain` de partida
   (p. ej. `["new", "acknowledged", "assigned", "confirmed"]`) y un `statusMap` de partida (p. ej.
   `{ "inProgress": "assigned", "inValidation": "confirmed" }` — confirmar los nombres reales y el
   orden de la cadena con el usuario, o con `mantis-cli.ps1 get`/`projects` si los conoce).
2. ⛔ Solo tras aprobación explícita, escribir el fichero.
3. Recordar añadirlo al ignore de VCS (no contiene secretos, pero es config local del workspace).
4. Sugerir continuar con `/rs-mantis proyectos` para poblar `projects[]`.

# Límite

A diferencia de `rs-jira` (MCP Atlassian Rovo con OAuth interactivo), esta skill usa **autenticación
por token** vía `mantis-cli.ps1` — **sí puede correr headless** (ejecuciones no interactivas / cron).
Aun así, ⛔ las escrituras en Mantis (crear, transicionar, comentar, adjuntar) siguen requiriendo
confirmación explícita en **uso interactivo**; en un flujo headless deben ejecutarse solo si el
llamador ya ha dado esa confirmación fuera de banda (p. ej. un runner con aprobación previa
registrada), nunca asumirla por defecto.
