# RS Enterprise Agent

Skill de Claude Code para desarrollo C# en soluciones uCollect/RS. Pipeline automatizado de desarrollo (planificación → análisis → validación → testing → build) más 22 modos directos: auditoría, análisis de un diff, impacto, validación código↔BD, esquema BD, modelo BD/ERD, scripts de idiomas, commits SVN o Git, documentación, seguridad y estadísticas.

Versión actual: ver `CHANGELOG.md`.

---

## Instalación

Plugin de Claude Code, publicado como marketplace Git:

```
/plugin marketplace add https://github.com/vgege86/rs-enterprise-plugin.git
/plugin install rs-enterprise-agent@rs-enterprise-agent
```

El repo es **privado**: hace falta credencial de GitHub en la máquina (`gh auth login` o Git Credential Manager) para que Claude Code pueda clonarlo.

Claude Code descubre automáticamente `commands/`, `agents/`, `skills/rs-enterprise-agent/SKILL.md`, los hooks SessionStart/Stop/UserPromptSubmit (`.claude-plugin/plugin.json`) y el MCP server `rs-workspace` (`.mcp.json`) — no hay que copiar nada a mano ni editar `~/.claude/settings.json`/`~/.claude.json`.

Con origen Git, Claude Code clona el marketplace en `~/.claude/plugins/marketplaces/` y ejecuta el plugin desde su copia en `~/.claude/plugins/cache/<marketplace>/<plugin>/<versión>/`: **ninguna sesión depende de una unidad de red**.

⚠️ Si tenías el marketplace anterior de tipo `directory` (apuntando a una ruta local o de red), quítalo antes con `/plugin marketplace remove rs-enterprise-agent`; si no, conviven dos orígenes y el plugin se ejecuta desde la carpeta origen, no desde el cache.

Tras instalar: **reiniciar Claude Code**.

Para actualizar tras un cambio publicado: `/plugin marketplace update rs-enterprise-agent` (o reinstalar) y reiniciar.

**Requisitos**: Python 3.11+ (MCP server), .NET SDK (`dotnet build`/`test`), PowerShell 7+, Visual Studio con MSBuild (builds Online vía vswhere). Para los comandos de control de versiones: Subversion CLI (misma versión que TortoiseSVN) en proyectos SVN, o Git CLI (2.x+) en proyectos Git — basta con tener el que corresponda al proyecto, `detect_vcs` decide cuál usar.

---

## Activación

Tres vías:

1. **Pipeline completo** — mensaje con el patrón solución + cambio:
   ```
   RSProcIN.sln - añadir validación de entrada
   AgendaWeb.sln - modificar lógica de pedidos
   ```
2. **Slash commands** — `/rs-*` (lista abajo).
3. **Lenguaje natural** — "audita AgendaWeb.sln", "muestra el ERD", "qué usa RCLIENTES"... Cualquier mención de una `.sln` o solución RS dispara la skill (reforzado por el hook `skill-trigger.ps1`, que inyecta un recordatorio determinista en workspaces `\SVN\RS\`).

---

## Pipeline

El **planner es el cerebro**: analiza el cambio con acceso al modelo BD y al código, y emite el bloque `PLAN` (que un humano debe aprobar) y la lista autoritativa de etapas `STAGES`. El orquestador **ejecuta `STAGES` en orden sin re-decidir** — el resto de agentes solo aplican el plan.

```
resolver .sln → scope → planner → [aprobación humana] → STAGES → checklist → log
   STAGES ⊆ { core, plan-check, validator, tester, build, db-modeler, documentar }  (en ese orden)
```

| Etapa | Agente | Cuándo la incluye el planner en STAGES |
|-------|--------|----------------------------------------|
| (1) | Validación .sln (validate-solution) | Siempre (orquestador) |
| (1b) | Scope (get_scope) | Siempre — una sola vez, reenviado a todas las etapas |
| (2) | planner 🟣 | Siempre — analiza y decide STAGES |
| (2b) | **Aprobación humana** | Siempre — gate bloqueante (`references/gates.md`) |
| `core` | core 🟣 | Siempre — implementa el cambio (lee docs si el plan lo marca) |
| `plan-check` | plan-check 🔷 | Siempre tras core — verifica que el código cubre todos los ítems del PLAN aprobado (red de seguridad: también si el planner lo omite) |
| — | core (reintento) 🟣 | Si plan-check devuelve INCOMPLETE (máx 1 ciclo; agotado → escala al usuario) |
| `validator` | validator 🔷 | Siempre — compila + análisis estático + lógica (absorbe el antiguo analyzer) |
| — | fixer 🟣 | Si validator falla (máx 2 ciclos, compartidos con tester) |
| `tester` | tester 🔷 | Si hay lógica testeable o es Online y toca controles/idiomas |
| — | crear-tests 🔷 | Auto si tester devuelve NEEDS_TESTS (sin proyecto, o código nuevo sin cobertura; advisory) |
| — | scripts idiomas | Solo Online — gate interno del tester (controles/Idm.Texto/rebinds nuevos) |
| `build` | build ⚡ | Tras modificar código (Batch y Online), con verificación de evidencia |
| `db-modeler` | db-modeler 🟣 | Si añade/modifica tablas o DALCs (red de seguridad: también si core devuelve TABLES_TOUCHED) |
| `documentar` | documentar (UpdateDocs) 🔷 | Si el cambio cumple los criterios de DocumentarCambio |
| (checklist + log) | Orquestador | Siempre — verificación de evidencia + registro en history.json |

> La validación de tipos/longitudes/motor BD (antes etapa `bd`) la hace ahora el **planner** en la fase de análisis. Ya no existen los agentes `rs-editor-bd` ni `rs-editor-analyzer`.

---

## Comandos slash

### Pipeline principal

```
/rs-enterprise-agent <Solution>.sln - <cambio a realizar>
```
Ejemplo: `/rs-enterprise-agent RSProcIN.sln - añadir validación de fecha en cabecera`

### Análisis de código

```
/rs-audit <Solution>.sln
```
Auditoría estática de calidad (naming, estructura, lógica, seguridad) de **toda** la solución, sin modificar código.

```
/rs-analizar <Solution>.sln [revisión|ficheros]
```
Análisis estático de calidad/riesgo de **un diff o cambio concreto** (el delta, no toda la solución). Reconstruye el cambio vía `detect_vcs`; por defecto analiza los cambios pendientes. Versión standalone de lo que el pipeline hace en el validator.

```
/rs-impacto <clase|método|tabla> en <Solution>.sln
```
Mapa de referencias a un símbolo dentro del scope, con clasificación de riesgo. Ejemplo: `/rs-impacto RCLIENTES en RSProcIN.sln`

```
/rs-validar-bd <Solution>.sln <DALC|clase|tabla>
```
Valida código C# contra la BD real: tipos, longitudes (truncamiento silencioso), nullabilidad y compatibilidad de motor (SQL Server/Oracle). Versión standalone de la validación BD que el pipeline hace en el planner. Ejemplo: `/rs-validar-bd RSProcIN.sln CobrosDalc.cs`

```
/rs-review <Solution>.sln [--rev <revisiones>] [--pr <n> [owner/repo]]
```
Revisión de un cambio (diff/PR) con **veredicto** `APRUEBA | CAMBIOS | BLOQUEA`. Unifica sobre el delta riesgo técnico + seguridad + compatibilidad BD. Por defecto revisa los cambios pendientes; con `--rev` una revisión/hash concreto; con `--pr` publica el veredicto en el pull request de GitHub. Ejemplo: `/rs-review RSProcIN.sln --rev 1234`

```
/rs-perf <Solution>.sln [DALC|tabla]
```
Análisis de rendimiento de acceso a BD: cruza el SQL de los DALC contra los índices del modelo para detectar índices que faltan, full-scans, filtros no-sargables y `SELECT *` en tablas anchas. Complementa `/rs-validar-bd` con el eje de rendimiento. Ejemplo: `/rs-perf RSProcIN.sln CobrosDalc.cs`

```
/rs-schema <tabla|keyword>
```
Esquema real de una o varias tablas: columnas, tipos, longitudes, nullabilidad, índices. Consulta pura (no genera DDL/ERD — para eso `/rs-erd`). Ejemplo: `/rs-schema RCLIENTES`

```
/rs-estructura <Solution>.sln
```
Mapa de capas, grafo de dependencias, detección de referencias circulares.

```
/rs-security <Solution>.sln
```
Scan de seguridad: SQL injection, credenciales hardcodeadas, XSS, input sin validar. Findings con severidad y `archivo:línea`.

```
/rs-deps [proyecto]
```
Mapa de dependencias entre soluciones: proyectos compartidos, conflictos de versión NuGet.
Ejemplo: `/rs-deps RSDalc` → qué soluciones usan RSDalc y cuántas se verían afectadas por un cambio.

### Control de versiones (SVN o Git — autodetectado)

> **Requisito:** `/rs-diff`, `/rs-commit`, `/rs-historial` y `/rs-validar-req` necesitan `svn.exe` (proyectos SVN) o `git.exe` (proyectos Git) — `detect_vcs` decide cuál usar según lo que encuentre bajo el workspace, nunca hay que indicarlo a mano.
> Subversion: instalar CLI con la **misma versión que TortoiseSVN** para evitar conflictos de working copy. Sin CLI, degrada a instrucciones manuales vía TortoiseSVN.
> Git: cualquier `git.exe` 2.x reciente. Sin CLI, degrada a instrucciones manuales vía TortoiseGit.

```
/rs-diff [Solution.sln]
```
Cambios pendientes de commit, agrupados por solución/proyecto (SVN: modificado/añadido/eliminado/sin versionar; Git: modificado/staged/sin trackear/conflicto).

```
/rs-commit <Solution>.sln
```
Filtro de scope + diff + mensaje de commit sugerido. Requiere confirmación explícita antes de ejecutar. En Git, `commit` y `push` se confirman por separado — `git commit` es solo local, el `push` es lo que llega al repo compartido.

```
/rs-historial [Solution.sln] [N]
```
Historial de ejecuciones del pipeline y commits (SVN o Git). Ejemplo: `/rs-historial RSProcIN.sln 5`

```
/rs-deshacer <Solution>.sln
```
Deshace los cambios **pendientes de commit** del último cambio del pipeline, revirtiéndolos a su estado versionado (SVN o Git). No toca commits ya hechos ni la BD. ⛔ Pide confirmación explícita antes de revertir (previsualiza qué se revierte/elimina).

```
/rs-release-notes [Solution] [N] [--desde YYYY-MM-DD]
```
Convierte el historial de commits (SVN/Git) en notas de versión funcionales agrupadas (nuevo / correcciones / BD / interno), en lenguaje de negocio/QA. Ejemplo: `/rs-release-notes RSProcIN 30`

```
/rs-validar-req "<requerimiento>" --rev <revisiones> [--sln <Solution.sln>] [--session]
```
Valida si los commits (SVN o Git) implementan lo requerido. Detecta tests faltantes.
- `--rev` revisión/es SVN o hash(es) de commit Git, separados por coma (obligatorio)
- `--sln` inferida del diff si se omite
- `--session` incluye transcript de sesión Claude para análisis más completo

Ejemplo: `/rs-validar-req "validar importe positivo y menor al límite" --rev 1234` (SVN) o `--rev a1b2c3d` (Git)

### Base de datos

```
/rs-erd [workspace]
```
Gestión del modelo BD: actualizar desde BD real, visualizar ERD interactivo (drag/zoom, edición de descripciones, export SQL/CSV/SVG/PNG), generar DDL, exportar a Oracle Data Modeler.

La toolbar del ERD deja visible lo diario (subvista, buscador, filtro, `Fit view`, `PKs`, `Guardar`)
y agrupa el resto en cuatro menús: **Vista · Modelo · Exportar · Importar**.

El HTML del ERD no caduca: si solo cambió `BD\<proyecto>-model.json`, basta usar
**`Importar ▾` → "Abrir modelo…"** para recargarlo en caliente — regenerar solo hace falta si cambió
la plantilla del plugin. Al guardar, el widget escribe sobre ese mismo fichero (navegadores con
File System Access API).

```
/rs-comparar-modelo [workspace]
```
Drift entre `BD/<proyecto>-model.json` y el esquema real. Ofrece generar scripts de migración y sincronizar el modelo post-migración.

```
/rs-sync-indexes [workspace]
```
Sincroniza índices desde la BD real al modelo (solo Oracle). Preserva índices `source=manual`.

```
/rs-generar-dalc <NombreTabla> en <Solution>.sln
```
Genera clases DALC completas desde el modelo BD. Ejemplo: `/rs-generar-dalc RCLIENTES en RSProcIN.sln`

```
/rs-migrar <Solution>.sln a <ORACLE|SQLSERVER>
```
Adapta DALCs y SQL entre SQL Server ↔ Oracle.

### Instalación

```
/rs-instalador [<Proyecto>|<workspace>]
```
Genera el **instalador completo de cliente** (instalación limpia) en `C:\AIS\<Proyecto>\Instalador\`:
`EXES\` (procesos batch activos en Release), `AgendaWeb\` (publicación web), `ServiceManager\` +
`Modulos\` (host net8 + módulos activos) y `Scripts\` (DDL de tablas sin schema + un fichero de
inserts por tabla paramétrica). Los procesos batch y módulos activos por cliente se guardan en
`docs\<Proyecto>-instalador.json`: si no existe, el comando lo crea preguntando; si existe, lo muestra
y pregunta si añadir alguno más. Las tablas paramétricas salen de `subviews["Parametricas"]` del
`model.json`.

### Testing

```
/rs-crear-tests <Solution>.sln
```
Crea proyecto de test (xUnit/MSTest/NUnit) si no existe + genera tests unitarios para las clases públicas.

### Documentación e idiomas

```
/rs-doc <Solution>.sln
```
Genera y **persiste** el resumen por-solución (propósito, estructura, tablas, flujo, configuración) en `docs/agentic_manual/soluciones/<Solution>.md`. El pipeline lo refresca cuando cambia la estructura.

> **Documentación en el pipeline.** El manual técnico de convenciones (`docs/agentic_manual/tecnica/`) es INPUT: el planner clasifica la tarea con su índice maestro y core lee los docs que aplican + el CHECKLIST antes de emitir código. La doc **funcional** y el **resumen por-solución** se actualizan automáticamente tras un cambio; el **manual técnico** solo se toca por **propuesta que un humano confirma** (cuando el cambio introduce un patrón reutilizable nuevo) — es la referencia compartida por todas las soluciones.

```
/rs-idiomas <Solution>.sln
```
Escanea `.aspx` en busca de controles AIS y genera INSERTs para `RIDIOMA`/`RCONTROLES`. Solo Online.
Reglas clave: mensajes de error (`Idm.Texto`) solo llevan RIDIOMA; IDTEXTO libre siempre consultado contra RIDIOMA real (nunca por huecos de `coerr.cs`); salida a `C:\AIS\<proyecto>\scripts\`.

### Entorno y estadísticas

```
/rs-env [workspace]
```
Valida .rs-databases.json, ruta AIS, dotnet, SVN, modelo BD y docs agentic.

```
/rs-init
```
Prepara un workspace **nuevo** para el plugin: crea `docs/.rs-databases.json` (o migra `XMLConfig.xml`), el andamiaje `docs/agentic_manual/` y el primer `model.json`, y valida con `/rs-env`. ⛔ Nunca sobrescribe ficheros existentes. Complementa `/rs-env` (que solo valida).

```
/rs-stats [solution]
```
Estadísticas desde `executions/history.json`: total ejecuciones, tasa de éxito, top soluciones, agentes más usados, tendencia 7 días.

### Jira

```
/rs-tarea [PROJ-123 | URL]
```
Orquesta el ciclo de vida de una tarea de Jira sobre una solución RS: selecciona la issue (búsqueda de tus tareas abiertas o KEY/URL manual) → formatea el requisito al prompt `<Sln>.sln - <cambio>` → transiciona a "En Proceso" → **lanza el pipeline `rs-enterprise-agent`** → tras `/rs-commit`, adjunta los `.sql` generados y transiciona a "En Validación". Es una capa **opcional y aditiva**: no cambia el pipeline; si no la usas, todo funciona igual que antes. `/rs-tarea init` crea el `.jira-dev-config.json`.

- **Requisitos**: MCP **Atlassian Rovo** conectado (búsqueda/lectura/transición/comentario, sin credenciales propias). Para **adjuntar `.sql`** hace falta un Jira API token en `~/.claude/rs-jira-credentials.json` (`{ baseUrl, email, token }`, fuera del repo). Config no-secreta del workspace en `docs\.jira-dev-config.json` (junto a `.rs-databases.json`; `projectKey`, `jiraUser`, `cloudId?`, `statusMap`, `openStatuses?`). Setup completo → `references/jira.md`.
- Uso interactivo (el MCP Rovo usa auth interactiva; no corre en headless/cron).

---

## MCP Server

Servidor local `mcp/rs-workspace-server.py` (FastMCP) con **41 tools** que envuelven los hooks 1:1. Preferente sobre hooks — más eficiente en tokens, con caché en memoria (mtime) y disco (`~/.claude/cache/rs-models`).

Registrado automáticamente por el plugin vía `.mcp.json` (raíz del repo):

```json
{
  "mcpServers": {
    "rs-workspace": {
      "type": "stdio",
      "command": "python",
      "args": ["${CLAUDE_PLUGIN_ROOT}/mcp/rs-workspace-server.py"],
      "env": { "PYTHONUTF8": "1" }
    }
  }
}
```

Protección de contexto:
- `compile_check` — trunca errores a `max_errors` (default 20)
- `run_tests` — trunca failures a `max_failures` (default 10)
- `find_symbol` — trunca matches a `max_results` (default 50)
- `db_query` — trunca filas a `max_rows` (default 200)
- `render_erd`, `generate_sql`, `export_dmd` — generan ficheros, nunca cargan el contenido en contexto
- Modelo BD nunca se carga entero (~180K tokens): `search_model` → `get_model_index` → `get_table_schema`

Tools disponibles → `references/mcp.md`

---

## Hooks

Scripts PowerShell en `hooks/` — fallback cuando el MCP no está activo (convención Preferente/Fallback en SKILL.md). Lista completa con parámetros → `references/hooks.md`.

Hooks de infraestructura (registrados por el plugin en `.claude-plugin/plugin.json`, no invocados por agentes):
- `skill-trigger.ps1` — UserPromptSubmit: fuerza el disparo de la skill al mencionar `.sln` en workspaces RS
- `runner/runner.ps1` — Stop: ejecuta los builds encolados (batch-build / online-publish / copy-ais)

---

## Modelo de BD

Modelo JSON vivo en `BD/<proyecto>-model.json`:
- Tablas y columnas desde el esquema real (SQL Server / Oracle)
- Relaciones inferidas desde código DALC (JOINs, WHERE cruzados) con nivel de confianza
- Índices sincronizables desde BD; descripciones semánticas editables
- Export a DDL Oracle/SQL Server y Oracle Data Modeler (.dmd)
- Detección de drift vs BD real + generación automática de scripts de migración
- Merge seguro: preserva siempre `source="manual"` y descripciones; tablas ausentes se marcan `orphan`, nunca se borran

---

## Estructura

```
.claude-plugin/
  marketplace.json        marketplace de un solo plugin (source: "./")
  plugin.json             manifiesto del plugin: nombre, versión, hooks SessionStart/Stop/UserPromptSubmit
.mcp.json                 registro del MCP server rs-workspace
skills/
  rs-enterprise-agent/
    SKILL.md              instrucciones principales del pipeline + modos directos
  rs-plugin-dev/
    SKILL.md              meta-skill: modifica el propio plugin (/rs-plugin-dev)
  rs-jira/
    SKILL.md              orquestador de tareas de Jira (/rs-tarea) — envuelve el pipeline
agents/                   34 subagentes: pipeline y modos directos
commands/                 definiciones de slash commands
hooks/                    scripts PowerShell (build, SVN, BD, análisis, trigger, jira-attach)
mcp/                      servidor MCP con 41 tools
references/               documentación de referencia (cargada bajo demanda)
  arquitectura.md         stack de capas uCollect, convenciones web Online
  hooks.md                lista completa de hooks con parámetros
  jira.md                 setup de la integración Jira (config + credenciales)
  mcp.md                  lista completa de MCP tools
docs/
  plugin-architecture.md  anatomía interna del plugin + patrón de extensión (fuente canónica)
scripts/                  utilidades python (analyze-dalc, export-dmd, generate-sql, render-erd)
runner/                   runner.ps1 — ejecutor de builds (Stop hook)
executions/               history.json — historial de ejecuciones
assets/                   widget ERD inline
```

---

## Reglas clave

- Validator y Tester son bloqueantes — build no ejecuta si fallan
- Scope estricto: solo proyectos incluidos en la .sln activa
- Build con verificación de evidencia: nunca "build OK" sin output real del runner
- Modelo BD preserva siempre descripciones y relaciones manuales
- Scripts idiomas (RIDIOMA/RCONTROLES) obligatorios en Online según el gate de core.md (controles nuevos, Idm.Texto nuevos, rebinds de grid)
- Scripts SQL generados siempre a `C:\AIS\<proyecto>\scripts\`
- Sin svn CLI instalado: svn-add degrada a TortoiseProc → instrucciones manuales
- Sin git CLI instalado: git-add degrada a TortoiseGitProc → instrucciones manuales
- VCS nunca se asume — `detect_vcs` decide SVN/Git/ninguno antes de cualquier modo de diff/commit

---

## Desarrollo del plugin

- Fuente canónica: el repo Git `https://github.com/vgege86/rs-enterprise-plugin.git` (privado). El checkout local del mantenedor es solo eso, un checkout — nada del plugin debe depender de su ruta.
- **Anatomía interna y patrón de extensión** → `docs/plugin-architecture.md`. Léelo antes de añadir un modo, un agente, una tool MCP o un hook.
- **Modificar el plugin de forma guiada** → skill `rs-plugin-dev` (`/rs-plugin-dev <qué cambiar>`): lee el doc de arquitectura, planifica, pide aprobación antes de escribir, **sube la versión** (obligatorio, es lo que dispara la detección de actualización) y sincroniza la documentación.
- ⛔ Nunca editar la copia cacheada por Claude Code (`~/.claude/plugins/cache/...`) — es un snapshot, se pisa en cada update.
- Tras cualquier cambio (agentes, referencias, `SKILL.md`, hooks, MCP, commands, skills) → **bump de versión** en `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` (idénticas), luego `/plugin marketplace update rs-enterprise-agent` (o reinstalar) y reiniciar Claude Code.
