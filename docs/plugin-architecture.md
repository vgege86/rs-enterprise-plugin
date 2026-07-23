# Arquitectura del plugin `rs-enterprise-agent`

Fuente canónica de la **anatomía interna** del plugin y del **patrón para extenderlo**.
Va dirigido a quien mantiene o modifica el propio plugin (no a quien lo usa sobre soluciones
uCollect/RS — eso es el `README.md`). La skill `rs-plugin-dev` lee este documento antes de
tocar nada.

- Documentación de **uso**: `README.md`.
- Historial de cambios: `CHANGELOG.md`.
- Conocimiento de dominio (C#/BD/convenciones uCollect): `references/*.md`.
- Diseño del pipeline de subagentes: `docs/superpowers/specs/2026-07-08-rs-pipeline-subagents-design.md`
  (⚠️ `docs/superpowers/` no se publica en el repo Git — ver `.gitignore`; vive solo en el checkout
  del mantenedor).

---

## 1. Anatomía del plugin

Fuente canónica: repo Git privado `https://github.com/vgege86/rs-enterprise-plugin.git`. El árbol
local del mantenedor es un checkout más — ningún artefacto del plugin puede depender de su ruta
(ver §1.1).

```
.claude-plugin/
  plugin.json            manifiesto: name, version, author, hooks SessionStart + Stop + UserPromptSubmit
  marketplace.json       marketplace de un solo plugin (source: "./")
.mcp.json                registro del MCP server rs-workspace (stdio, python)
skills/
  rs-enterprise-agent/SKILL.md   skill orquestadora (pipeline + modos directos)
  rs-plugin-dev/SKILL.md         meta-skill: modifica el propio plugin
  rs-jira/SKILL.md               orquestador de tareas de Jira (/rs-tarea) — envuelve el pipeline
agents/                  subagentes .md — pipeline (rs-editor-*) y modos directos (rs-*)
commands/                slash commands .md — wrappers finos que despachan a un subagente/skill
mcp/
  rs-workspace-server.py FastMCP server; cada @mcp.tool hace shell-out a un hook
hooks/                   scripts PowerShell: worker (fallback 1:1 de tools MCP) + infra
  README.md              catálogo de hooks con parámetros
runner/
  runner.ps1             ejecutor de builds encolados (target del hook Stop)
references/              conocimiento de dominio, cargado bajo demanda
docs/                    esta doc + design specs
scripts/                 utilidades Python/PowerShell (analyze-dalc, export-dmd, install, etc.)
assets/                  widget ERD inline
executions/
  history.json           historial de ejecuciones del pipeline (lo escribe log_execution)
```

Nota: `README.md` menciona una carpeta `BD/<proyecto>-model.json`; ese modelo vive en el
workspace de cada solución cliente, **no** en el repo del plugin (ver §11).

### 1.1 Dónde se ejecuta realmente el plugin (`${CLAUDE_PLUGIN_ROOT}`)

`${CLAUDE_PLUGIN_ROOT}` no es "la carpeta del repo": es la raíz **efectiva** desde la que Claude Code
carga el plugin, y depende del tipo de marketplace:

| Origen del marketplace | Raíz efectiva | Consecuencia |
|---|---|---|
| `git` / `github` | `~/.claude/plugins/cache/<marketplace>/<plugin>/<versión>/` | Copia local por usuario. Portable. **Es el modo soportado.** |
| `directory` (ruta local o de red) | la **propia carpeta origen** | El plugin se ejecuta *in situ*: hooks, runner y MCP salen de esa ruta. Todos los usuarios necesitan acceso a ella. El `installPath` que aparece en `installed_plugins.json` es un snapshot muerto que **no** se usa en runtime. |

Cómo comprobarlo en una máquina concreta (el MCP server es el testigo más directo):

```powershell
Get-CimInstance Win32_Process -Filter "Name like '%python%'" | Select-Object CommandLine
```

La línea debe apuntar a `~/.claude/plugins/cache/...`. Si apunta a una unidad de red o a un árbol de
desarrollo, el marketplace registrado es de tipo `directory` — revisar
`~/.claude/plugins/known_marketplaces.json` y volver a instalar desde el origen Git.

⛔ En markdown (skills, agents, commands) `${CLAUDE_PLUGIN_ROOT}` **no se expande**: solo se sustituye
en `.claude-plugin/plugin.json` y `.mcp.json`. Por eso el contrato de invocación pasa `plugin_root`
resuelto y verificado (§11.4).

---

## 2. Manifests y registro

**Qué se declara explícitamente:**

| Fichero | Declara |
|---------|---------|
| `.claude-plugin/plugin.json` | `name`, `description`, `version`, `author` y los **hooks** `SessionStart` (→ `scripts/cleanup-preplugin.ps1`, timeout 60), `Stop` (→ `runner/runner.ps1`, timeout 120) y `UserPromptSubmit` (→ `hooks/skill-trigger.ps1`, timeout 15), inline con `${CLAUDE_PLUGIN_ROOT}`. Los 3 commands se lanzan con `powershell -NoProfile` (evita cargar el perfil de usuario en cada arranque → timeouts; ver CHANGELOG 2.15.9) |
| `.claude-plugin/marketplace.json` | Entrada de marketplace: un plugin `rs-enterprise-agent`, `source: "./"`, `category: productivity`. Puede llevar su propia `version` |
| `.mcp.json` | El MCP server `rs-workspace` (type `stdio`, `command: python`, arg `${CLAUDE_PLUGIN_ROOT}/mcp/rs-workspace-server.py`, env `PYTHONUTF8=1`) |

**Qué se auto-descubre por convención** (no se lista en ningún manifiesto):

- **Skills** — cada `skills/<nombre>/SKILL.md`.
- **Agentes** — cada `agents/*.md`.
- **Comandos** — cada `commands/*.md`.

⛔ Consecuencia clave: crear el fichero en la carpeta correcta **registra** el artefacto, pero
Claude Code solo lo detecta tras **subir la versión** en `plugin.json` (§9) + `/plugin
marketplace update` + reinicio. Sin bump de versión el cambio no se propaga.

---

## 3. La skill orquestadora (`rs-enterprise-agent`)

`skills/rs-enterprise-agent/SKILL.md`. El main thread actúa como **orquestador**: resuelve
solución y scope, y despacha cada etapa como subagente Task-tool aislado.

**PIPELINE OBLIGATORIO** (resumen — detalle en `SKILL.md`, gates en `references/gates.md`):

```
1 resolver .sln → 1b scope → 2 planner (cerebro) → 2b ⛔aprobación humana →
3 ejecutar STAGES en orden → 4 ⛔checklist → 5 log
   STAGES ⊆ { core, validator⇄[fixer], tester⇄[crear-tests], build, db-modeler, documentar }
```

El **planner** analiza con acceso al modelo BD y al código, y emite `PLAN` (para el humano) + `STAGES`
(lista ordenada, autoritativa). El orquestador **ejecuta `STAGES` sin re-decidir** qué etapas corren —
el resto de agentes solo aplican el plan. `validator` absorbe el antiguo `analyzer`; la validación BD
(antiguo `bd`) la hace el planner. Ya no hay flags `CREATE_TESTS`/`UPDATE_DOCS`: todo se lee de `STAGES`.

**Documentación:** el planner también clasifica la tarea contra el índice maestro técnico (tabla
tarea→docs) y emite `READ_DOCS` — los docs del **manual de convenciones** que core debe leer + el
CHECKLIST — para generar código que cumple. La etapa `documentar` cubre 3 objetivos con distinto gate:
doc **funcional** (auto), **resumen por-solución** (`soluciones/<Sln>.md`, auto), y **manual técnico**
(`tecnica/`) solo por **propuesta+confirmación humana** cuando core reporta `NEW_PATTERN`.
`find_doc_section` cubre `funcional/` + `tecnica/`.

Gates bloqueantes ⛔ (`references/gates.md`): 2b (aprobación explícita del plan), 4 (checklist de
evidencia), 5 (log siempre).

**Contrato de invocación** (header común a toda etapa): `sln_path`, `plugin_root`, `workspace`,
`scope_dirs`, `tipo`. `plugin_root` = raíz del plugin (contiene `agents\`, `hooks\`, `runner\`,
`references\`, `skills\`), resuelta y **verificada** según SKILL.md § "Raíz del plugin" — ⛔ nunca
escrita como `${CLAUDE_PLUGIN_ROOT}` en markdown (ver §11.4). Renombrado desde `skill_dir` en 2.12.0.

**Contrato de salida** (lo único que el orquestador reenvía entre etapas):
`FILES_CHANGED` / `SUMMARY` / `STATUS` (+ campos extra documentados en cada `rs-editor-*.md`).
Nunca se reenvía código completo ni diffs completos — es lo que mantiene el contexto acotado.

Modelo por etapa: se elige por lo que exige la tarea, no por el modelo activo del chat
(⚡ Haiku lectura/mecánico · 🔷 Sonnet juicio autocontenido/advisory · 🟣 Opus escribe
código/SQL de producción o gate de seguridad/cumplimiento). Racional completo en el design spec.

---

## 4. Agentes

Dos familias en `agents/`, ambas con frontmatter `name`, `description`, `model`
(`haiku|sonnet|opus`), `tools` (allowlist con prefijo `mcp__plugin_rs-enterprise-agent_rs-workspace__` + herramientas nativas).
Cuerpo en español, arranca con `# Rol`.

**Pipeline (`rs-editor-*`)** — invocados por el orquestador, nunca por el usuario. Su
`description` indica el nº de paso y "nunca directamente por el usuario". Emiten el contrato
`FILES_CHANGED`/`SUMMARY`/`STATUS`.

| Agente | Modelo | Etapa (token STAGES) |
|--------|--------|----------------------|
| `rs-editor-planner` | **opus** | 2 — cerebro: analiza (modelo BD + `db_query` + símbolos) y decide `STAGES` |
| `rs-editor-core` | opus | `core` |
| `rs-editor-validator` | sonnet | `validator` (absorbe el antiguo analyzer) |
| `rs-editor-fixer` | opus | ciclo de `validator`/`tester` |
| `rs-editor-tester` | sonnet | `tester` |
| `rs-editor-build` | haiku | `build` |
| `rs-editor-db-modeler` | opus | `db-modeler` (y modo directo `/rs-erd`) |

Eliminados en v2.7.0: `rs-editor-bd` (validación BD absorbida por el planner) y `rs-editor-analyzer`
(análisis estático absorbido por el validator).

**Modos directos (`rs-*`)** — despachados por un comando `/rs-*`. Autocontenidos, reciben
`sln_path`+`skill_dir` en el prompt y devuelven su resultado para relay verbatim.
Ejemplos: `rs-auditoria`, `rs-analisis`, `rs-impacto`, `rs-validacion-bd`, `rs-esquema`,
`rs-seguridad`, `rs-documentar`, `rs-crear-tests`, `rs-diff`, `rs-commit` (ambos autodetectan
SVN/Git vía `detect_vcs`), `rs-migracion-motor`, `rs-idiomas-standalone`, `rs-comparar-modelo`,
`rs-generar-dalc`, `rs-estructura`, `rs-dependencias`, `rs-validar-entorno`, `rs-historial`,
`rs-stats`, `rs-validar-req`, `rs-instalador`.

`rs-instalador` (`/rs-instalador`, opus) genera el instalador completo de cliente en
`C:\AIS\<Proyecto>\Instalador` (EXES batch + AgendaWeb + ServiceManager+Modulos + Scripts SQL).
Orquesta 4 hooks `installer-*.ps1` vía `runner/runner.ps1` (patrón `batch-build`/`online-publish`,
sin tool MCP) y 2 scripts Python (`installer-ddl.py`, `installer-inserts.py`). Config por cliente en
`docs\<Proyecto>-instalador.json`; tablas paramétricas desde `subviews["Parametricas"]` del model.json.
Los inserts por tabla se generan en paralelo (`ThreadPoolExecutor`), con cap configurable
`parametricas.max_paralelo` (default 8 = conexiones BD simultáneas).

`rs-analisis` (análisis estático de un diff) y `rs-validacion-bd` (validación código↔BD) son las
versiones **standalone** de lo que en el pipeline hacen el validator y el planner respectivamente —
comparten reglas vía reference (`references/bd.md`), no duplican lógica. `rs-esquema` es consulta
pura de esquema (no genera DDL/ERD; eso es `/rs-erd`).

---

## 5. Comandos

`commands/*.md`, wrappers finos. Patrón (plantilla: `commands/rs-audit.md`):

```markdown
---
description: <qué hace>. Uso: /rs-<x> <args>
---

Invoke the `rs-enterprise-agent` skill in <mode> mode.

Usage: /rs-<x> <args>
Example: /rs-<x> RSProcIN.sln

Dispatch to the `rs-<agente>` subagent (runs on <Haiku|Sonnet|Opus> — <por qué ese tier>)
via the Agent tool. Pass in the prompt: `sln_path` ... and `skill_dir`.
Relay the subagent's output verbatim — do not reformat or summarize it.
```

Frontmatter solo `description` (+ `Uso:`). Cuerpo en inglés. Los comandos de VCS
(`rs-diff`, `rs-commit`) llaman `detect_vcs` y despachan al subagente unificado (`rs-diff`/`rs-commit`),
que ramifica internamente según el motor (SVN/Git) — ya no hay subagentes `-svn`/`-git` separados.

---

## 6. MCP server `rs-workspace`

`mcp/rs-workspace-server.py` (FastMCP, `mcp = FastMCP("rs-workspace")`, transport stdio).
**40 tools**, cada una decorada `@mcp.tool(description=...)`. La mayoría hace **shell-out a un
`hooks/*.ps1` vía el helper `_run_ps`** (subprocess) → relación tool↔hook casi 1:1. Los nombres
se exponen a Claude como `mcp__plugin_rs-enterprise-agent_rs-workspace__<func>` (y `mcp__plugin_rs-enterprise-agent_rs-workspace__<func>`
bajo el namespace de plugin). Catálogo completo: `references/mcp.md`.

Protección de contexto (por qué es preferente sobre leer ficheros a pelo):
- Truncado configurable: `max_errors` (compile_check, 20), `max_failures` (run_tests, 10),
  `max_results` (find_symbol, 50), `max_rows` (db_query, 200).
- `render_erd`/`generate_sql`/`export_dmd` **generan ficheros**, nunca cargan contenido en contexto.
- El modelo BD **nunca se carga entero** (~180K tokens): `search_model` → `get_model_index`
  → `get_table_schema`.

Helpers no-tool: `_get_config`, `_get_scope`, `_load_model`, `_run_ps`, `_proyecto`,
`_get_db_password`, `_check_workspace`, `_check_svn_cli`, `_check_git_cli`.

---

## 7. Hooks

`hooks/*.ps1` — dos roles distintos:

**Infraestructura** (registrados en `plugin.json`, los ejecuta Claude Code, no los agentes):
- `scripts/cleanup-preplugin.ps1` — evento `SessionStart`: retira restos de la instalación manual
  pre-plugin que sombrean al plugin (mueve a backup, no borra). Ver CHANGELOG 2.11.0/2.14.0.
- `hooks/skill-trigger.ps1` — evento `UserPromptSubmit`: inyecta un recordatorio determinista
  para disparar la skill cuando se menciona una `.sln` en un workspace uCollect/RS. Fail-fast si
  `cwd` es inaccesible (unidad de red caída) para no bloquear el evento.

⚠️ Los 3 hooks de infra se invocan con `powershell -NoProfile` — sin él, `-File` carga el perfil
de usuario en cada arranque y sobre `cwd` en red supera el timeout (`output discarded`). Ver
CHANGELOG 2.15.9.
- `runner/runner.ps1` — evento `Stop`: ejecuta los builds encolados (batch-build / online-publish / copy-ais).

**Worker** (`hooks/*.ps1`) — **fallback 1:1 de las tools MCP** (convención Preferente/Fallback:
usar siempre la tool MCP; si no responde, ejecutar el hook equivalente). Catálogo con parámetros
en `hooks/README.md` y `references/hooks.md`. Categorías: build/deploy, análisis/scope, BD/modelo,
VCS (SVN + Git), entorno/logging, Jira (`jira-attach.ps1`, fallback 1:1 de `jira_attach`).

---

## 8. References

| Fichero | Contenido |
|---------|-----------|
| `references/arquitectura.md` | Stack de capas uCollect/RS (RSModel→RSDalc→RSBus→RSFac→Web), convenciones web Online |
| `references/conventions.md` | Naming (PascalCase/camelCase) y estructura de carpetas |
| `references/bd.md` | Convenciones de base de datos |
| `references/dalc-patterns.md` | Patrones de código DALC, extracción de relaciones |
| `references/dmd-format.md` | Formato Oracle Data Modeler `.dmd` |
| `references/json-schema.md` | Esquema del `model.json` de BD |
| `references/mcp.md` | Catálogo completo de las 40 tools MCP |
| `references/hooks.md` | Catálogo completo de hooks con parámetros (tabla de equivalencia MCP↔hook) |
| `references/gates.md` | Procedimiento completo de los gates del pipeline (aprobación del plan, checklist final, log) |
| `references/testing.md` | Patrones de test RS/uCollect |
| `references/troubleshooting.md` | Fallos comunes (p.ej. MSB4019) |
| `references/jira.md` | Setup de la integración Jira (skill `rs-jira`): `.jira-dev-config.json`, credenciales, herramientas |

---

## 9. Cómo extender el plugin

### 9.1 Nuevo modo directo (patrón de 3 ficheros)

1. **Agente** `agents/rs-<modo>.md` — frontmatter (`name`, `description`, `model`, `tools`) +
   `# Rol` español. Plantilla: `agents/rs-auditoria.md`.
2. **Comando** `commands/rs-<modo>.md` — patrón §5. Plantilla: `commands/rs-audit.md`.
3. **Fila** en la tabla `# Modos directos` de `skills/rs-enterprise-agent/SKILL.md`
   (frase/comando → agente + tier de modelo ⚡/🔷/🟣).

### 9.2 Nueva etapa de pipeline

Igual que un agente pipeline (`agents/rs-editor-<etapa>.md`, emite el contrato de salida) **más**
cablearla en el `# PIPELINE OBLIGATORIO` de `SKILL.md` con su handoff, y reflejarla en el design
spec y en la tabla de pasos del `README.md`.

### 9.3 Nueva tool MCP

1. Función `@mcp.tool(description=...)` en `mcp/rs-workspace-server.py` que hace `_run_ps` sobre
   un hook nuevo.
2. Hook equivalente `hooks/<x>.ps1` (respeta la convención Preferente/Fallback 1:1).
3. Documentar en `references/mcp.md` **y** `references/hooks.md`.
4. Si algún agente la usa, añadirla a su `tools:` (prefijo `mcp__plugin_rs-enterprise-agent_rs-workspace__`).

### 9.4 Nueva skill

Carpeta `skills/<nombre>/SKILL.md` (frontmatter `name` + `description` con triggers). Se
auto-descubre. Añadir un comando wrapper si se quiere invocación por slash.

---

## 10. Puntos de sincronización de documentación

Checklist de coherencia — qué tocar según el artefacto añadido/modificado:

| Cambio | Ficheros a sincronizar (además del artefacto) |
|--------|-----------------------------------------------|
| Nuevo modo directo | tabla `# Modos directos` SKILL.md · README (comandos) · CHANGELOG · §4 este doc |
| Nueva etapa pipeline | `# PIPELINE OBLIGATORIO` SKILL.md · tabla pasos README · design spec · §3/§4 este doc |
| Nueva tool MCP | `references/mcp.md` · `references/hooks.md` · README (nº de tools) · CHANGELOG · §6 este doc |
| Nuevo hook | `references/hooks.md` · `hooks/README.md` · CHANGELOG |
| Nueva skill | README · CHANGELOG · §2/§3 este doc |
| Cambio de convención de dominio | reference correspondiente · CHANGELOG |
| **Cualquier cambio** | ⛔ **bump de versión** en `plugin.json` **y** `marketplace.json` (idénticas) + entrada `CHANGELOG.md` |

---

## 11. Inconsistencias conocidas

Desajustes reales detectados (documentados, no corregidos aquí salvo petición explícita):

1. **`settings.json` (raíz)** — bloque `hookScripts` legacy/informativo; **no** es formato de hooks
   de Claude Code (los hooks reales están en `plugin.json`). Lleva un `_note` que lo aclara.
2. **`${CLAUDE_PLUGIN_ROOT}` NO se expande en markdown** — Claude Code solo la sustituye en
   `.claude-plugin/plugin.json` y `.mcp.json`. En `skills/*/SKILL.md`, `agents/*.md` y
   `commands/*.md` llega literal, o el modelo la resuelve a la carpeta de la *skill*
   (`...\skills\rs-enterprise-agent`), que no contiene `hooks\` ni `runner\` → el runner del
   instalador y de build fallaban al resolver la ruta (issues upstream anthropics/claude-code
   #9354, #9427). Corregido en 2.12.0: contrato `plugin_root` + regla de normalización verificada
   con Glob (SKILL.md § "Raíz del plugin"), y comprobación defensiva en los tres agentes que
   ejecutan `runner\`/`hooks\` por ruta (`rs-instalador`, `rs-editor-build`, `rs-editor-db-modeler`).

**Resueltas** (histórico):
- **`subagents/` vs `agents/`** (2.15.2) — las referencias en ficheros versionados (`references/`,
  `commands/`, `scripts/install-hooks.ps1`) se actualizaron a `agents/` (carpeta real desde v2.0.0).
  El design spec vive en `docs/superpowers/` (no publicado, ver `.gitignore`) y queda fuera de este barrido.
- **Carpeta `BD/`** (2.15.2) — se retiró del árbol de estructura del `README.md`: el `model.json`
  vive en el workspace de cada solución cliente, no en el repo del plugin.
