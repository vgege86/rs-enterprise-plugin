---
name: rs-log-errores
description: 'Analiza el log de errores de la web de una solución uCollect/RS, deduplica las ocurrencias del mismo fallo en tipos de error distintos, abre una tarea por tipo en el gestor del proyecto (Jira o Mantis, autodetectado) y propone lanzar el pipeline de desarrollo para cada una. Usar cuando el usuario quiere convertir un log en tareas: "/rs-log-errores", "analiza el log de errores", "revisa el log de la web y crea tareas", "qué errores está dando AgendaWeb", "crea tickets con los errores del log". No requiere MCP de ticketing para el análisis; sí para el alta (Rovo en Jira, mantis-cli en Mantis). NO sustituye al pipeline rs-enterprise-agent — lo alimenta.'
---

# RS Log Errores

Convierte un log de errores de la capa web en **tareas accionables**. El log repite el mismo fallo
cientos de veces: lo que se abre como tarea no son las líneas, son los **tipos de error distintos**.
La deduplicación la hace el hook `parse-weblog.ps1` (tool `parse_web_log`) por **firma**, no el
modelo — así el log nunca entra entero en contexto y el recuento es determinista.

Es orquestador de **main thread** (como `rs-jira`/`rs-mantis`): crea tickets y lanza el pipeline,
dos cosas que un subagente no puede hacer. El alta de tickets **reutiliza** las skills de gestor
existentes — esta skill no reimplementa Jira ni Mantis.

# Rol

Triador de errores de producción. Prioriza: un ticket por causa real > un ticket por línea de log |
confirmación antes de crear nada en el gestor > automatismo | reutilizar `rs-jira`/`rs-mantis` y el
pipeline > reimplementar nada.

# Reglas Globales

- ⛔ **Toda escritura en el gestor (crear issue, comentar) va detrás de confirmación explícita.**
  Son acciones outward-facing difíciles de revertir, y aquí se crean **varias de golpe**.
- ⛔ **Nunca crear tickets sin pasar por el gate de F2.** El usuario ve la lista propuesta y la
  edita antes de que exista nada en el gestor.
- ⛔ **No lanzar el pipeline automáticamente ni en paralelo.** F4 *propone*; el usuario decide, y
  las tareas se trabajan **de una en una**.
- ⛔ No adivinar la ruta del log — si no viene en el argumento, preguntarla.
- ⛔ No leer el log crudo con Read/Grep para "ver qué hay": el fichero puede pesar cientos de MB y
  llevar datos personales. La única puerta es `parse_web_log`, que ya agrega y redacta PII.
- No analizar el código en esta skill. El triaje clasifica *qué* falla y *dónde* aparece; el *cómo*
  se arregla lo decide `rs-editor-planner` dentro del pipeline (gate 2b).
- No borrar, mover ni rotar el log. Es solo lectura sobre él.

# Raíz del plugin (`plugin_root`)

Igual que el resto de skills: partir de la ruta que inyecta Claude Code, si termina en
`\skills\rs-log-errores` subir **dos** niveles, y verificar con Glob que contiene `hooks\` y
`runner\`. ⛔ `${CLAUDE_PLUGIN_ROOT}` no se expande en markdown.

# Auto-verificación (al inicio)

1. **`parse_web_log`** — es la única dependencia del análisis (F1). Comprobar que el nombre
   `mcp__plugin_rs-enterprise-agent_rs-workspace__parse_web_log` aparece en el registro de tools de
   la sesión (deferred incluido) y cargar su schema con ToolSearch antes de llamarla. *Deferred ≠
   ausente.* Si no aparece ni como deferred → avisar (actualizar el plugin) y ⛔ parar.
   - ⚠️ Es una tool de `rs-workspace` (MCP Python): si **no responde en segundos**, el proceso
     `python.exe` está bloqueado por el EDR (CrowdStrike FP, `docs/crowdstrike-fp-justification.md`).
     Reportarlo y parar — no colgar el turno. Fallback: el mismo hook por Bash
     (`powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin_root>/hooks/parse-weblog.ps1" -Path ...`).
2. **Gestor de tickets** — no se verifica aquí. Su dependencia (Rovo o `mantis-cli.ps1`) la comprueba
   la skill destino en F3, cuando ya se sabe qué tickets hay que crear. Un log sin errores
   accionables no debe exigir Jira conectado.

# FASES (flujo estricto, no saltar)

### Fase 0 — Fuente del log
1. La ruta llega como argumento (`/rs-log-errores <ruta>`): fichero o carpeta. Si **no** llega →
   ⛔ preguntarla. No inventar rutas ni salir a buscar logs por el disco.
2. Opciones que el usuario puede pasar y que se trasladan a la tool: `--desde YYYY-MM-DD`
   (`desde`), `--max N` (`max_signatures`), `--glob <patrón>` (`glob`, por defecto `*.log`),
   `--niveles ERROR,FATAL` (`niveles`).
3. Anunciar en una línea qué se va a analizar (ruta, ventana, niveles) antes de empezar.

### Fase 1 — Parseo y deduplicación
1. `parse_web_log(path, glob, desde, niveles, max_signatures, samples)`.
2. Si `success:false` → mostrar el `error` tal cual y parar. Si `signatures` viene vacío → informar
   con el `message` de la tool (suele ser `--glob`/`--niveles`/`--desde` mal ajustados, o un formato
   propio que el parser no reconoce) y parar.
3. Presentar la tabla, ordenada por frecuencia:

   | # | firma | excepción | origen | pantalla | ocurrencias | primera → última |
   |---|-------|-----------|--------|----------|-------------|------------------|

   `excepción` no siempre es un tipo .NET: en el formato `rs-cerrores` (el propio de la AgendaWeb)
   es el **código** — `ORA-12899`, `COD200`—, que es lo que identifica el fallo ahí. `pantalla` es
   la `.aspx.cs` del stack y puede venir vacía (procesos sin capa web); no inventarla.

4. Reportar también `total_events`, `distinct_signatures`, `format_detected` y, si `truncated` o
   `scan_truncated` son `true`, **decirlo explícitamente**: hay más firmas o más líneas de las
   analizadas. Un recuento truncado presentado como completo es un error de informe, no un detalle.
5. ⛔ **Contrastar el recuento con el tamaño del log antes de triar.** `success: true` no garantiza
   que se haya reconocido el formato: hasta la 3.20.0 un log de 55.494 líneas con 2.544 eventos
   devolvía `total_events: 1` y se reportó como "un error de infraestructura, no abrir tareas".
   Si `total_events` es de un orden que no cuadra con `lines_scanned` (decenas de miles de líneas y
   un puñado de eventos), o `format_detected` es `desconocido`/`stacktrace-plano` sobre un log con
   pinta de tener cabeceras propias → **decirlo y parar**: es un formato que el parser no entiende,
   y la respuesta correcta es añadirlo (`/rs-plugin-dev`), no triar un recuento falso.

### Fase 2 — Triaje y propuesta de tareas (gate ⛔)
1. Clasificar cada firma en una de estas categorías, con lo que se ve en la firma (excepción,
   frame de origen, mensaje, frecuencia) — sin abrir el código:
   - **código** — bug propio (`NullReference`, índice fuera de rango, cast inválido, error de DALC
     sobre una columna). → candidata a tarea.
   - **dato** — el código está bien y el dato no (registro inexistente, violación de FK/PK). →
     candidata, normalmente con prioridad menor.
   - **configuración** — cadena de conexión, permiso, ruta o setting. → candidata, pero la tarea es
     de entorno, no de desarrollo.
   - **infra** — timeout de red/BD, disco, caída de un servicio externo. → normalmente **no** es
     tarea de desarrollo; proponerla aparte y dejar que el usuario decida.
   - **ruido** — trazas de terceros, cancelaciones de petición del navegador, bots. → descartar.
2. Proponer **una tarea por firma accionable**, con:
   - **Resumen**: `[log:<hash>] <Excepción> en <Origen>` (+ ` (<pantalla>)` si el hook la trae) —
     el marcador `[log:<hash>]` es lo que permite reconocer la tarea en ejecuciones posteriores
     (paso 2 de F3).
   - **Descripción**: excepción/código · origen · pantalla · nº de ocurrencias · ventana
     `primera → última` · ficheros de log · muestra (ya redactada por el hook) · categoría del
     triaje.
   - **Prioridad sugerida**: frecuencia × severidad de la categoría. Justificarla en una línea.
3. Si dos firmas son claramente el mismo fallo visto desde dos sitios (misma excepción, mismo
   origen, mensajes equivalentes que la normalización no llegó a colapsar) → proponer **fundirlas**
   en una tarea que liste ambas firmas. No al revés: nunca partir una firma en varias tareas.
4. ⛔ **Gate**: presentar la lista numerada (tarea → firma(s) → prioridad → categoría) y esperar a
   que el usuario la ajuste: quitar, fundir, cambiar prioridad, reescribir títulos. Hasta que no
   apruebe **no existe nada en el gestor**. Si salen muchas tareas, sugerir un recorte por
   frecuencia (p. ej. solo las que superen N ocurrencias) en vez de abrirlas todas.

### Fase 3 — Alta en el gestor
1. **Routing** — misma regla que `/rs-tarea` (canónica en `commands/rs-tarea.md`): mirar qué config
   existe en `docs\` del workspace — `.jira-dev-config.json` → Jira, `.mantis-dev-config.json` →
   Mantis. Si existen **los dos**, ⛔ preguntar cuál (aquí no hay forma del argumento que desambigüe).
   Si no existe ninguno, preguntar el gestor y ofrecer `/rs-tarea init`. Anunciar el gestor detectado
   antes de la primera escritura.
2. **Dedup contra el gestor** (evita recrear en cada pasada las tareas de la pasada anterior): antes
   de crear, buscar cada `[log:<hash>]` entre las issues abiertas.
   - Jira → `searchJiraIssuesUsingJql(cloudId, 'project = <projectKey> AND summary ~ "log:<hash>"')`.
   - Mantis → `mantis-cli.ps1 list -Project <id>` y filtrar el marcador en el resumen.
   - Si ya existe una issue abierta con esa firma → ⛔ **no duplicar**: informar y ofrecer añadir una
     nota con las nuevas ocurrencias y la nueva ventana (`addCommentToJiraIssue` / `comment`),
     siempre bajo confirmación.
3. **Valores por defecto y etiquetas** — aplicar el bloque `defaults` del config del gestor (ver
   `references/jira.md` / `references/mantis.md`) a **todas** las issues del lote:
   - Jira → `defaults` se vuelca en `additional_fields` de `createJiraIssue` (`issueTypeName`,
     `priority`, `components`, `labels`, `customfield_*`).
   - Mantis → `defaults.category` / `priority` / `severity` / `tags` van a `mantis-cli.ps1 create`
     (`-Category -Priority -Severity -Tags`).
   - A las etiquetas de `defaults` se añade `log-<hash>` por tarea (Jira `labels`, Mantis `tags`).
     Si la instancia rechaza etiquetas nuevas, seguir sin ellas — el marcador del resumen es el que
     sostiene el dedup, no la etiqueta.
4. ⛔ **Confirmación del lote**: mostrar el objeto completo de **cada** issue a crear (todos los
   campos con sus valores, incluidos los de `defaults`) y dejar editar antes de crear. Una sola
   confirmación cubre el lote entero, pero el contenido se enseña issue a issue.
5. Crear las issues delegando en la skill del gestor:
   - Jira → `skills/rs-jira/SKILL.md`, **Fase 1b** (alta), en submodo *crear-suelto* para cada tarea.
   - Mantis → `skills/rs-mantis/SKILL.md`, **Fase 1** rama b (`create`), submodo *crear-suelto*.
   Quedan **asignadas al usuario** (assignee/handler), igual que cualquier alta de esas skills.
6. Si el alta de una issue falla, reportar el error de esa issue y **seguir con las demás**; al final
   listar cuáles se crearon y cuáles no. No abortar el lote por una.
7. Reportar la tabla final: `firma → KEY/id creada (o "ya existía #N")`.

### Fase 4 — Propuesta de pipeline (una a una)
1. Listar las tareas creadas y **proponer** trabajarlas con el pipeline, ordenadas por la prioridad
   de F2.
2. ⛔ El usuario elige **cuál** empezar. Nunca lanzar varias, nunca lanzar sin que lo pida.
3. Para la elegida, continuar en la skill del gestor desde su **Fase 2** (encuadre del requisito)
   con la KEY/id: ahí se pregunta la `.sln`, se formatea el prompt `<Solucion>.sln - <cambio>`, se
   transiciona a "En Proceso" y se lanza el pipeline con todos sus gates (2b plan, 10b checklist,
   11 log). Esta skill **no** replica nada de eso.
4. Al cerrar esa tarea (Fase 4 del gestor: commit, SQL, "En Validación"), ofrecer volver aquí y
   seguir con la siguiente de la lista.

# Límite

⛔ El análisis (F0–F2) es autónomo y funciona sin gestor de tickets. El alta (F3) hereda los límites
de la skill destino: la rama **Jira** usa MCP Rovo con auth interactiva y **no** corre en
headless/cron; la rama **Mantis** usa token y sí puede, pero sus escrituras siguen exigiendo
confirmación explícita en uso interactivo.
