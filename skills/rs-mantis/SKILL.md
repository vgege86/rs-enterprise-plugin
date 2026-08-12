---
name: rs-mantis
description: 'Ciclo de vida completo de una tarea de MantisBT sobre una solución uCollect/RS: seleccionar/crear issue → formatear el requisito → transicionar → lanzar el pipeline → commit → adjuntar SQL → pasar a validación. Triggers: "/rs-mantis", "/rs-tarea" en un workspace con `docs\.mantis-dev-config.json` (el router detecta el gestor y despacha aquí), "trabaja la tarea Mantis 1234", "crea una tarea en Mantis", "mis tareas de Mantis". No requiere MCP: cliente REST autónomo `hooks/mantis-cli.ps1` con API token. Envuelve al pipeline rs-enterprise-agent, no lo sustituye.'
---

# RS Mantis

Orquestador (main thread) del ciclo de vida de una tarea de MantisBT sobre una solución uCollect/RS.
Envuelve el pipeline `rs-enterprise-agent` — **no lo modifica**. A diferencia de `rs-jira`, MantisBT
**no tiene MCP**: toda la interacción —leer, listar, crear, transicionar, comentar, adjuntar— pasa
por el cliente REST autónomo `hooks/mantis-cli.ps1` (PowerShell vía Bash), con **API token**.

📎 Catálogo completo de subcomandos ↔ endpoints, esquema de config, credenciales, protocolo
`advance` y sensibilidad de rate en PATCH: `references/mantis.md`. **Leerla cuando la fase lo pida,
no al arrancar.**

# Rol

Coordinador entre Mantis y el desarrollo. Prioriza: no perder el hilo del estado en Mantis > rapidez |
confirmación antes de toda escritura en Mantis > automatismo | reutilizar el pipeline y `/rs-commit`
existentes > reimplementar nada.

# Reglas Globales

- ⛔ **Toda escritura en Mantis (crear issue, transicionar estado, comentar, adjuntar) va detrás de
  una confirmación explícita del usuario.** Son acciones outward-facing difíciles de revertir.
- ⛔ No pasar de fase sin la aprobación del usuario de esa fase.
- ⛔ **Nunca imprimir ni loguear el token de Mantis** ni el contenido de
  `~/.claude/rs-mantis-credentials.json`. `mantis-cli.ps1` ya redacta el token en sus errores
  (`Protect-MantisToken`), pero no reproducir el fichero por ningún motivo.
- **Workflow encadenado y sin saltos.** MantisBT no tiene endpoint de transiciones: el estado es un
  campo que se cambia con `transition -Id -Status <nombre>` (`PATCH /issues/{id}`), y esta instancia
  solo admite pasos adyacentes de `statusChain` (p. ej. `new → acknowledged → assigned → confirmed`).
  ⛔ Para llegar a un estado no adyacente usar **siempre `advance`** (recorre la cadena paso a paso),
  nunca `transition` suelto. No hardcodear nombres de estado — salen de `statusMap`/`statusChain` del
  config. Un estado desconocido devuelve el error tal cual lo reporta Mantis: revisar `statusMap` o
  mirar el estado actual con `get`.
- No adivinar la `.sln` — **siempre preguntarla** al usuario (Fase 2).
- ⛔ La **Fase 2 no analiza código** — encuadra el requisito desde la issue. El análisis técnico
  (columnas, catálogo, pantallas, "el cómo") es del `rs-editor-planner` en el gate 2b del pipeline.
- No modificar el pipeline: la Fase 3 lo **lanza** con el prompt formateado; el pipeline aplica sus
  propios gates (2b aprobación del plan, 10b checklist, 11 log).

# Raíz del plugin (`plugin_root`)

Las llamadas a `mantis-cli.ps1` usan la ruta **absoluta** del hook, no `${CLAUDE_PLUGIN_ROOT}` (no
se expande en markdown — ver `skills/rs-enterprise-agent/SKILL.md` § Raíz del plugin). Resolución:
partir de la ruta de esta skill; si termina en `\skills\rs-mantis`, subir **dos** niveles; verificar
con Glob que contiene `hooks\`; si no, subir un nivel más y repetir (**máx. 3 saltos**). Si tras los
3 saltos no aparece → ⛔ detener y pedir la ruta al usuario. Nunca inventarla.

# Auto-verificación (al inicio)

Aquí **no hay MCP que verificar** para el flujo principal: toda la integración es `mantis-cli.ps1`.

1. **Credenciales** → comprobar con Bash que `~/.claude/rs-mantis-credentials.json` existe:
   `powershell -NoProfile -Command "Test-Path (Join-Path $env:USERPROFILE '.claude\rs-mantis-credentials.json')"`.
   - **no existe** → explicar cómo crearlo (JSON `{ "baseUrl", "token" }`; token desde *Mantis → My
     Account → API Tokens*, ver `references/mantis.md`) y ⛔ parar. No adivinar valores ni crear el
     fichero por el usuario: son credenciales suyas.
   - **existe** → seguir; no se lee ni se imprime aquí — `mantis-cli.ps1` lo valida en cada llamada.
2. **Config del workspace** → leer `docs\.mantis-dev-config.json`. Si falta → ofrecer
   `/rs-mantis init` y ⛔ parar hasta que exista (la Fase 0 la necesita).
3. ⛔ **NUNCA llamar a `mcp__plugin_rs-enterprise-agent_rs-workspace__ping`** (ni a ninguna tool
   `rs-workspace`) en el arranque: bajo CrowdStrike el proceso `python.exe` del MCP queda bloqueado y
   la llamada **no responde hasta el timeout de 1800s** (FP conocido,
   `docs/crowdstrike-fp-justification.md`). `rs-workspace` solo se usa en la **Fase 4**
   (`log_execution`) y su verificación viva se difiere allí. Basta comprobar que el nombre
   `...rs-workspace__log_execution` **aparece en el registro de tools** (deferred incluido); si no
   aparece, avisar (reinstalar/actualizar el plugin) pero **seguir igualmente** — Fase 4 solo
   perdería la trazabilidad de `/rs-historial`, no bloquea el cierre.

# Cómo se llama al hook (`mantis-cli.ps1`)

Toda operación Mantis es una llamada Bash al hook, nunca una tool MCP:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin_root>/hooks/mantis-cli.ps1" -Command <cmd> [-Id <n>] [-Project <n>] [...]
```

- La salida es una única línea JSON. Parsearla y comprobar `success`:
  - `true` → usar los campos de datos (`projects`, `issues`, `issue`, `id`, `attached`, `applied`, …).
  - `false` → mostrar `error` al usuario tal cual (ya viene con el token redactado) y **parar la
    fase** — no reintentar automáticamente, no inventar datos.
- ⛔ **Nunca imprimir el token** ni el contenido crudo del fichero de credenciales, ni al depurar.
- Subcomandos: `projects`, `list`, `get`, `create`, `transition`, `advance`, `assign`, `me`,
  `comment`, `attach`, `download`. **Firma exacta, flags y semántica de cada uno →
  `references/mantis.md` § "subcomandos ↔ endpoint REST"** — consultarla antes de construir la
  llamada, no improvisar flags.

# Config del workspace

`docs\.mantis-dev-config.json` (carpeta `docs\`, junto a `.rs-databases.json`; el workspace es el cwd).
Campos: `projects[]` (lista curada `{id,name}`, gestionada con `/rs-mantis proyectos`),
`defaultCategory` *(legacy, solo si no hay `defaults.category`)*, `defaults` *(opcional: `category`,
`priority`, `severity`, `tags` — espejo del `defaults` de `rs-jira`)*, `statusChain` (array
**ordenado** de estados del workflow) y `statusMap` (`inProgress`/`inValidation`, atajos dentro de
`statusChain` que usan las Fases 3 y 4). Esquema completo y ejemplos → `references/mantis.md`.

Si el fichero **no existe** → ofrecer `/rs-mantis init`. Las **credenciales** (`baseUrl`, `token`)
viven aparte en `~/.claude/rs-mantis-credentials.json`, fuera del repo.

# FASES (flujo estricto, no saltar)

### Fase 0 — Proyecto
Leer `projects[]` de la config. ⛔ **Nunca asumir/inferir el proyecto**:
- **1 solo proyecto curado** → usarlo (es el único, no es asumir).
- **más de uno** → listar `id — nombre` numerado y ⛔ **preguntar cuál**.
- **ninguno** → `mantis-cli.ps1 projects` → listar candidatos `id — nombre (estado)` y ⛔ **preguntar
  cuál/cuáles añadir** (deriva a `/rs-mantis proyectos` / `init`). No continuar con un proyecto supuesto.

### Fase 1 — Tarea
- **a) Existente** → `mantis-cli.ps1 list -Project <id>` (el hook trae **todas** las issues; Mantis no
  filtra por estado en este endpoint → filtrar en la respuesta las no cerradas/resueltas y listar
  `id — resumen (estado)` numeradas), o el usuario da el **id global** → `get -Id <n>`.
- **b) Crear** → pedir categoría (por defecto `defaults.category`, o `defaultCategory`), resumen y
  descripción → resolver el usuario del token (`mantis-cli.ps1 me` → `id`; lectura, sin confirmación)
  → ⛔ confirmar → `create -Project <id> -Category <s> -Summary <s> -Description <s> [-Priority <s>]
  [-Severity <s>] [-Tags <a,b>] -Handler <me.id>`.

  **Precedencia de campos al crear** (⛔ el primero que informa un campo gana): **usuario** >
  **`defaults`** del config > `defaultCategory` (solo categoría) > lo que aplique Mantis. Los `tags`
  son la excepción: se **acumulan** (defaults + usuario + los que aporte quien llame a esta fase, sin
  duplicados). Mostrar en la confirmación de dónde sale cada valor. Si la instancia rechaza una
  etiqueta nueva, informar y crear la issue sin ella en vez de abortar el alta.

  ⛔ **Toda issue creada queda asignada al usuario del token** (`-Handler <me.id>`), también en
  *crear-suelto*. Con el `id` devuelto, dos submodos (aclarar si no se desprende de la petición):
  **crear-y-trabajar** → seguir a Fase 2 | **crear-suelto** → confirmar el `id` (ya asignado) y parar.

### Fase 2 — Encuadre del requisito (NO análisis técnico)
⛔ **Traduce la issue a un requisito accionable — NO analiza el código.** Trabaja **solo** con el
contenido de Mantis (resumen, descripción, notas) y lo que aclare el usuario. NO leer el código, NO
llamar a `get_scope`/`find_symbol`/`search_code` ni abrir ficheros fuente, NO decidir el "cómo". Si
la issue es ambigua → **preguntar al usuario**, no explorar el repositorio.

1. Partir del `issue` obtenido en Fase 1 (`get`/`create`): resumen, descripción y notas relevantes.
2. ⛔ **Preguntar al usuario qué `.sln`** corresponde (nunca inferir).
3. Construir el prompt con el formato del pipeline: `<Solucion>.sln - <desarrollo a realizar>`,
   derivado **solo** de la issue y las aclaraciones, sin diseño técnico.
4. Presentarlo y preguntar si ajustar. Iterar hasta **aprobación explícita**. Es la aprobación del
   **requisito** (el qué); el plan técnico (el cómo) se aprueba en el gate 2b del pipeline.

### Fase 3 — En Proceso + lanzamiento
1. **Resolver el desarrollador** → `mantis-cli.ps1 me` → `id`. Lectura, sin confirmación; hace falta
   antes del paso 3 para fijar el handler.
2. ⛔ Confirmar antes de tocar Mantis. Esta confirmación cubre **tres escrituras** — enumerarlas:
   avanzar el estado (paso 3), comentar el prompt (paso 4), lanzar el pipeline (paso 5).
3. **Avance de estado** → `advance -Id <n> -To <statusMap.inProgress> -Chain "<statusChain unido por
   ','>" -Handler <me.id> -HandlerStatus <statusMap.inProgress>`. Recorre la cadena paso a paso sin
   saltar ninguno y, en el paso que llega a `inProgress`, fija el `handler`. **Idempotente hacia
   delante**: si la issue ya está en `inProgress` (o más adelante en la cadena) no cambia nada y
   devuelve `applied: []`. Si `success` es `false` → mostrar el `error` tal cual (puede incluir
   `Aplicados: ...` con los pasos que sí se ejecutaron) y **parar la fase**; no reintentar
   automáticamente ni asumir que se alcanzó el destino.
4. **Nota del prompt** → `comment -Id <n> -Text "<prompt aprobado>"`: deja en Mantis el prompt exacto
   `<Solucion>.sln - <cambio>` que se pasa al orquestador.
5. **Lanzar el pipeline**: continuar como orquestador de `skills/rs-enterprise-agent/SKILL.md`
   (PIPELINE OBLIGATORIO) con el prompt aprobado. Su gate 2b es una aprobación **distinta** de la de
   Fase 2; ambas se mantienen.

### Fase 4 — Commit + cierre ("En Validación")
1. Esperar a que el usuario pida el commit.
2. Ejecutar `/rs-commit` (flujo `detect_vcs` → subagente `rs-commit`). Anotar la revisión.
3. Tras confirmar el commit OK — ⛔ **orden estricto: primero confirmar el estado, después adjuntar**
   (protocolo del cliente: los scripts se suben una vez la issue está en Confirmada):
   - **Avance de estado** → ⛔ confirmar → `advance -Id <n> -To <statusMap.inValidation> -Chain
     "<statusChain unido por ','>"` (idempotente hacia delante, igual que en Fase 3). Si `success` es
     `false` → mostrar el `error` (incluye `applied`) y **parar aquí**; no adjuntar scripts sobre una
     issue que no llegó a "En Validación".
   - **SQL** → solo **una vez confirmado** el paso anterior: buscar `.sql` generados en la tarea en
     `C:\AIS\<proyecto-lowercase>\scripts\` (`proyecto` = carpeta anterior a `trunk\`). Si hay →
     ⛔ confirmar → `attach -Id <n> -Files <a,b>`. Si el hook falla por credenciales, avisar cómo
     crearlas (`references/mantis.md`) y seguir sin adjuntar.
   - **Trazabilidad** → ⚠️ **primer uso vivo de `rs-workspace` en toda la skill** →
     `mcp__plugin_rs-enterprise-agent_rs-workspace__log_execution(workspace, solution,
     task="Mantis #<id>: <resumen>", status, agents)`, con el id de Mantis, para enlazar
     issue↔ejecución en `/rs-historial`. Si **no responde en segundos** → proceso MCP bloqueado por el
     EDR (CrowdStrike FP, `docs/crowdstrike-fp-justification.md`): el commit y las transiciones **ya
     están hechos** → reportar cierre **parcial** (sin log, con la causa) en vez de colgar el turno.
   - **Nota del resultado** → ⛔ confirmar → `comment -Id <n> -Text "<resumen final>"` con el "Informe
     final" del paso 4. Si falla, el cierre ya está hecho → reportar cierre parcial, no colgar.
4. **Informe final** escaneable: id de Mantis · estado actual · ficheros SQL adjuntados (si aplica) ·
   revisión de commit. Es el mismo texto que se publicó como nota del resultado.

# Subrutina `/rs-mantis proyectos`

Gestiona la lista curada `projects[]` de `docs\.mantis-dev-config.json`:
1. `mantis-cli.ps1 projects` → listar **todos** los proyectos que ve el token, numerados
   `id — nombre (estado)`.
2. El usuario selecciona uno o varios → **Añadir** (los suma a `projects`, sin duplicar por `id`) o
   **Crear** (reemplaza `projects` con los seleccionados).
3. ⛔ Confirmar el contenido final antes de escribir el fichero.

# Subrutina `/rs-mantis init`

Scaffolding de `docs\.mantis-dev-config.json`:
1. Proponer el JSON con `projects: []`, `defaults` (categoría, prioridad, severidad y etiquetas —
   preguntar los valores o dejar `{ "category": "General" }`), un `statusChain` de partida y un
   `statusMap` de partida. ⛔ Confirmar con el usuario los **nombres reales** de los estados y el
   orden de la cadena (o mirarlos con `mantis-cli.ps1 get`/`projects`) — plantilla en
   `references/mantis.md`.
2. ⛔ Solo tras aprobación explícita, escribir el fichero.
3. Recordar añadirlo al ignore de VCS (no tiene secretos, pero es config local del workspace).
4. Sugerir continuar con `/rs-mantis proyectos` para poblar `projects[]`.

# Límite

A diferencia de `rs-jira` (OAuth interactivo), esta skill usa **autenticación por token** vía
`mantis-cli.ps1` → **sí puede correr headless**. Aun así, ⛔ las escrituras en Mantis siguen
requiriendo confirmación explícita en **uso interactivo**; en un flujo headless solo deben ejecutarse
si el llamador ya dio esa confirmación fuera de banda (p. ej. un runner con aprobación previa
registrada), nunca asumirla por defecto.
