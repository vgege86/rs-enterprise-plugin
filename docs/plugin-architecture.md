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
  marketplace.json       marketplace de dos plugins: rs-enterprise-agent (source "./") + rs-validador
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
assets/                  widget ERD inline + plantillas de instalación en cliente (`instalacion/`)
executions/
  history.json           historial de ejecuciones del pipeline (lo escribe log_execution)
plugins/                 plugins adicionales publicados por el mismo marketplace (§9.5)
  rs-validador/          mantenimiento de RSValidador (validador de ficheros) — árbol propio y
                         completo: .claude-plugin/, skills/, agents/, commands/, references/,
                         README y CHANGELOG. Versión independiente de la del plugin raíz
```

Nota: `README.md` menciona una carpeta `BD/<proyecto>-model.json`; ese modelo vive en el
workspace de cada solución cliente, **no** en el repo del plugin (ver §11).

### 1.1 Dónde se ejecuta realmente el plugin (`${CLAUDE_PLUGIN_ROOT}`)

`${CLAUDE_PLUGIN_ROOT}` no es "la carpeta del repo": es la raíz **efectiva** desde la que Claude Code
carga el plugin. El marketplace es de origen `git`, así que esa raíz es siempre
`~/.claude/plugins/cache/<marketplace>/<plugin>/<versión>/`: una copia por usuario, portable, que
Claude Code renueva en cada `/plugin marketplace update`. El `installPath` que aparece en
`installed_plugins.json` es un snapshot muerto y **no** se usa en runtime.

⛔ Por eso el checkout local del repo es solo un checkout: nada del plugin puede depender de su ruta,
y editarlo no cambia lo que se ejecuta hasta publicar y actualizar. La copia cacheada tampoco se
edita a mano — se pisa en el siguiente update.

⛔ En markdown (skills, agents, commands) `${CLAUDE_PLUGIN_ROOT}` **no se expande**: solo se sustituye
en `.claude-plugin/plugin.json` y `.mcp.json`. Por eso el contrato de invocación pasa `plugin_root`
resuelto y verificado (§11.4).

---

## 2. Manifests y registro

**Qué se declara explícitamente:**

| Fichero | Declara |
|---------|---------|
| `.claude-plugin/plugin.json` | `name`, `description`, `version`, `author` y los **hooks** `SessionStart` (→ `scripts/cleanup-preplugin.ps1`, timeout 60), `Stop` (→ `runner/runner.ps1`, timeout 120) y `UserPromptSubmit` (→ `hooks/skill-trigger.ps1`, timeout 15), inline con `${CLAUDE_PLUGIN_ROOT}`. Los 3 commands se lanzan con `powershell -NoProfile` (evita cargar el perfil de usuario en cada arranque → timeouts; ver CHANGELOG 2.15.9) |
| `.claude-plugin/marketplace.json` | El marketplace y **la lista de plugins que publica** (desde 3.11.0 son dos): `rs-enterprise-agent` con `source: "./"` y `rs-validador` con `source: "./plugins/rs-validador"`, ambos `category: productivity` y con su propia `version` |
| `.mcp.json` | El MCP server `rs-workspace` (type `stdio`, `command: python`, arg `${CLAUDE_PLUGIN_ROOT}/mcp/rs-workspace-server.py`, env `PYTHONUTF8=1`) |

**Qué se auto-descubre por convención** (no se lista en ningún manifiesto):

- **Skills** — cada `skills/<nombre>/SKILL.md`.
- **Agentes** — cada `agents/*.md`.
- **Comandos** — cada `commands/*.md`.

⛔ Consecuencia clave: crear el fichero en la carpeta correcta **registra** el artefacto, pero
Claude Code solo lo detecta tras **subir la versión** en `plugin.json` (§9) + `/plugin
marketplace update` + reinicio. Sin bump de versión el cambio no se propaga.

⚠️ El auto-descubrimiento es **relativo a la raíz de cada plugin**, no del repo: `skills/`,
`agents/` y `commands/` de un plugin de `plugins/<x>/` solo se cargan cuando se instala *ese*
plugin. Por eso los dos árboles no colisionan aunque compartan repo — y por eso el plugin raíz,
cuyo `source` es `"./"`, arrastra en su copia los ficheros de `plugins/` como peso muerto sin
efecto funcional.

---

## 3. La skill orquestadora (`rs-enterprise-agent`)

`skills/rs-enterprise-agent/SKILL.md`. El main thread actúa como **orquestador**: resuelve
solución y scope, y despacha cada etapa como subagente Task-tool aislado.

**PIPELINE OBLIGATORIO** (resumen — detalle en `SKILL.md`, gates en `references/gates.md`):

```
1 resolver .sln → 1b scope → 2 planner (cerebro) → 2b ⛔aprobación humana →
3 ejecutar STAGES en orden → 4 ⛔checklist → 5 log
   STAGES ⊆ { core⇄[plan-check], validator⇄[fixer], tester⇄[crear-tests], build, db-modeler, documentar }
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
| `rs-editor-plan-check` | sonnet | `plan-check` — verifica cobertura del PLAN tras core (INCOMPLETE ⇄ core, máx 1 ciclo) |
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
`rs-stats`, `rs-validar-req`, `rs-instalador`, `rs-review`, `rs-perf`, `rs-deshacer` (los tres
autodetectan SVN/Git vía `detect_vcs`), `rs-init`, `rs-release-notes`, `rs-cobertura`, `rs-dead-code`,
`rs-rename`, `rs-seed`, `rs-comparar-entornos`, `rs-hotspots`, `rs-dashboard`, `rs-explicar`,
`rs-doc-drift`, `rs-test`, `rs-format`, `rs-runbook`, `rs-actualizador`, `rs-word`.

`rs-word` (v3.2.0, haiku) cierra el ciclo documental: convierte `.md` del `agentic_manual` a un
`.docx` sobre la plantilla corporativa `.dotx` **del workspace del cliente** (nunca versionada en el
plugin — es material de marca). Cuarto miembro de la familia `render_*` (`render_erd`,
`render_dashboard`, `render_help`): hook + tool, genera fichero y **no** carga el contenido en
contexto. Depende de **Microsoft Word por COM** y no tiene fallback (el plugin no lleva pandoc ni
python-docx), por lo que `check-env.ps1` lo reporta como check informativo. Los estilos se resuelven
por **ID built-in** (`wdStyleHeading1 = -2`...), no por nombre local, para no romper con Word en otro
idioma. `rs-runbook` lo ofrece como paso final opcional tras persistir el runbook (`strip_marks`
retira las marcas `✅`/`👤`, que solo tienen sentido en el `.md`).

`rs-runbook` (v2.27.0, sonnet) es el único modo directo que **entrevista al usuario** como parte de
su proceso: documenta procedimientos de operación, cuyo conocimiento (reglas de la operación,
incidencias vividas en entorno de cliente) no es derivable del código. Marca cada bloque del
documento como `✅ verificado en código` o `👤 aportado por operación`, y no rellena huecos —
un paso inventado en un runbook se ejecuta contra datos reales. Persiste en
`docs\agentic_manual\funcional\OPERACION\` (dentro de `funcional\`, que `find_doc_section` escanea
en recursivo) y deriva los errores de **entorno** a `tecnica\` como `TECNICA_PROPUESTA`, nunca por
escritura directa.

Tercera tanda (v2.21.0): `rs-dashboard` (haiku) genera un dashboard HTML de `history.json` (patrón
`render_erd`: script + plantilla + hook + tool `render_dashboard`); `rs-explicar` (sonnet) explica un
elemento en lenguaje natural; `rs-doc-drift` (sonnet) doc funcional vs delta de código; `rs-test`
(haiku) ejecuta `run_tests` como modo suelto; `rs-format` (opus) auto-fix de convenciones con **gate**
(solo formato/naming, deriva renombrados públicos a `rs-rename`). Esta versión añade además la primera
**suite de tests del plugin** (`tests/`: pytest de funciones puras del MCP + Pester de las guardas de
`db-query.ps1` y `mantis-cli.ps1`, cableados en CI). Desde la 3.6.1 el pytest cubre además el
generador de inserts paramétricos del instalador (`tests/test_installer_inserts.py`: reparto de
tablas en sesiones SQL, **aislamiento de error por tabla dentro de una sesión compartida**, decisión
`VARCHAR2`/`TO_CLOB` y formateo del `.sql`; sin BD ni cliente instalado —`subprocess.run` se
sustituye—, así que corre igual en el CI). ⚠️ Los `*.Tests.ps1` tienen que pasar con **los dos
intérpretes**: `pwsh` 7, que es el del CI (`shell: pwsh` sobre `ubuntu-latest`, donde 5.1 no existe),
y `powershell` 5.1, que es el que ejecuta los hooks de verdad (`plugin.json` los lanza con
`powershell -NoProfile ... -File`). Hasta la 3.5.1 solo pasaban con 7 —usaban `Join-Path` con varios
`ChildPath` (`-AdditionalChildPath`), que no existe en 5.1—, y una suite que solo pasa en el
intérprete que no ejecuta nada en producción no prueba lo que hace falta probar.

Segunda tanda de modos directos (v2.20.0), todos **agente-solo** (sin hooks/tools nuevos): `rs-cobertura`
(sonnet) mapa de cobertura de tests; `rs-dead-code` (sonnet) inverso de `rs-impacto`, símbolos sin
referencias; `rs-rename` (opus) renombrado de símbolo + referencias con **gate de confirmación** (único
que escribe código en esta tanda); `rs-seed` (sonnet) INSERTs sintéticos respetando el esquema del
modelo; `rs-comparar-entornos` (sonnet) diff de esquema entre dos conexiones vía
`db_query(..., conexion=<id>)`; `rs-hotspots` (sonnet) churn VCS × complejidad.

`rs-review` (`/rs-review`, opus) revisa un diff/PR con veredicto `APRUEBA|CAMBIOS|BLOQUEA` combinando
riesgo técnico + seguridad + BD sobre el delta (reutiliza las reglas de `rs-analisis`/`rs-validacion-bd`
y `security_scan`); con `--pr` publica en GitHub vía el MCP `github`. `rs-perf` (`/rs-perf`, opus)
cruza el SQL de los DALC contra los índices del modelo — capacidad nueva, agente-solo. `rs-deshacer`
(`/rs-deshacer`, sonnet) revierte los cambios pendientes del último pipeline con gate de confirmación,
vía el hook/tool nuevos `vcs-revert.ps1`/`vcs_revert`. `rs-init` (`/rs-init`, sonnet) hace bootstrap de
un workspace nuevo (config BD + andamiaje docs + primer modelo), sin sobrescribir nada. `rs-release-notes`
(`/rs-release-notes`, sonnet) agrupa el log VCS en notas funcionales.

`rs-instalador` (`/rs-instalador`, opus) genera el instalador completo de cliente en
`C:\AIS\<Proyecto>\Instalador` (EXES batch + AgendaWeb + ServiceManager+Modulos + Scripts SQL).
Orquesta 4 hooks `installer-*.ps1` vía `runner/runner.ps1` (patrón `batch-build`/`online-publish`,
sin tool MCP) y 3 scripts Python (`installer-ddl.py`, `installer-objects.py`, `installer-inserts.py`),
sobre el módulo compartido `_dbmodel.py` (orden real de la PK y valor DEFAULT, la misma lectura del
modelo que usa `generate-sql.py`). La extracción de objetos cubre **los dos motores**: Oracle por el
diccionario `ALL_*` y SQL Server por el catálogo `sys.*`.
Config por cliente en `docs\<Proyecto>-instalador.json`; tablas paramétricas desde
`subviews["Parametricas"]` del model.json. La etapa de scripts está optimizada alrededor de que el
coste real es el **login del cliente SQL**, no la consulta: los inserts se piden agrupando tablas por
sesión (una sesión por chunk, marcador `@@TBL:<TABLA>@@` para trocear la salida sin perder el
aislamiento de error por tabla), los 6 tipos de objeto se extraen en paralelo, el SELECT evita
`TO_CLOB` cuando la fila cabe en `VARCHAR2` (con reintento automático si sale `ORA-01489`) y la
config de BD se resuelve una vez en el hook y viaja por `RS_DB_CONFIG_JSON` (sin password). Cap
común de sesiones simultáneas: `parametricas.max_paralelo` (default 8), que gobierna inserts y
objetos. Desde la 3.10.0 esos mismos extractores alimentan también el **inventario de objetos del
`model.json`** (`scripts/model-objects.py` + `scripts/_dbobjetos.py`, vía
`hooks/sync-model-objects.ps1`): del objeto se guarda su ficha y una **firma** del cuerpo, no el
cuerpo. El instalador sigue extrayendo de la BD viva —la garantía de que un paquete no puede
entregar código viejo— y contrasta lo extraído contra el inventario para reportar deriva. La
firma se calcula sobre el mismo texto que emitiría el instalador, que es lo que hace que "la
firma cambió" signifique "lo que se entregaría ha cambiado".

`installer-scripts.ps1` acepta `-Solo`/`-Tablas` para regenerar solo una parte, y su inventario
final nombra los seis ficheros de objetos uno a uno (`AUSENTE` + exit 2 al que falte): con un
comodín, cero ficheros generados salían como un resumen en verde. El paquete se cierra con
`Scripts\scripts.json`, que fija el orden de ejecución en el cliente — sin él se ordena por nombre y
los triggers se lanzan antes que las tablas.

`rs-actualizador` (`/rs-actualizador`, opus, v2.28.0) es su hermano **incremental**: genera la entrega
delta de un entorno (`DESA`/`TEST`/`PROD`) en `C:\AIS\<Proyecto>\Actualizador\<ENTORNO>_<AAAAMMDD>`.
Lee de la tabla **`RVERSIONES`** (BD de control) la `FECHA_CORTE` de la última entrega de cada
solución en ese entorno, calcula el delta con la tool nueva `vcs_delta` (hook `vcs-delta.ps1`,
autodetecta SVN/Git) y empaqueta con `actualizador-build.ps1`: batch afectados con Rebuild completo
de su solución (mismo gate de coherencia que `installer-batch` — DLLs sin strong-name), AgendaWeb
completa (delega en `installer-agendaweb.ps1`) y las DLL recién compiladas de los módulos afectados.
⛔ Excluye la configuración **funcional** del cliente (`web.config`, el `<proceso>.xml` de cada batch
—detectado por coincidencia de nombre con un `.exe` entregado—, `appsettings*.json` y los wildcards de
`excluirEntrega`), pero **mantiene los `*.config` del binario** (`RSProcIN.exe.config`): llevan los
binding redirects y separarlos de sus DLL reproduce el `FileLoadException`.

Ambos modos comparten el **paquete de instalación en cliente** (`hooks/instalacion-paquete.ps1` +
plantillas versionadas en `assets/instalacion/`: `Instalar.ps1` con backup ZIP previo,
`Ejecutar-Scripts.ps1` fail-fast, `rutas.json` por entorno, `readme.txt`, DDL de `RVERSIONES`). La
lógica de backup/instalación vive en plantillas, no la reescribe el modelo en cada entrega; lo mismo
vale para el SQL que depende del entorno: la **fila base de `RVERSIONES`** de una instalación limpia
la genera el hook (`Scripts/PorEntorno/99-RVERSIONES-<E>.sql`, una por entorno), no el modelo.
Convenciones de entrega: `references/actualizador.md`.

⛔ `Ejecutar-Scripts.ps1` es **un único lanzador para los dos modos** y **no es código generado**: el
hook lo copia literal. Lo que varía entre entregas es la lista de scripts, y viaja aparte — en
`scripts.json` si el paquete lo trae (lo escribe `/rs-actualizador`), y si no por convención de
carpetas. Esa es la razón de que no haya sustitución de placeholders: el `.ps1` se testea una vez
(`tests/EjecutarScripts.Tests.ps1`, vía `-DotSourceOnly`) y no cambia por cliente. Cualquier arreglo
en la capa de conexión —wallet, pre-vuelo, `NLS_LANG`, diagnóstico `SP2-xxxx` vs `ORA-*`— se hace
aquí y llega a los dos flujos; un segundo lanzador volvería a partir eso en dos.

`rs-analisis` (análisis estático de un diff) y `rs-validacion-bd` (validación código↔BD) son las
versiones **standalone** de lo que en el pipeline hacen el validator y el planner respectivamente —
comparten reglas vía reference (`references/bd.md`), no duplican lógica. `rs-esquema` es consulta
pura de esquema (no genera DDL/ERD; eso es `/rs-erd`).

`rs-pii` (`/rs-pii`, sonnet, v3.0.0) gestiona la protección de datos personales en las consultas a
BD: `status` informa del modo actual y de si las guardas `PreToolUse` están registradas; `bootstrap`
genera el inventario de columnas afectadas muestreando datos reales vía `db_query` (⛔ nunca
reproduce un valor muestreado, ni en la respuesta ni en el fichero); `audit`/`enforce`/`off`
escriben `pii_policy.mode` en el modelo BD. `enforce` no conmuta el modo sin antes registrar las
dos guardas `PreToolUse` (`hooks/pii-guard-bash.ps1`, `hooks/pii-guard-write.ps1`) en
`~/.claude/settings.json` y confirmar el registro con `check_env` — un workspace que crea estar
protegido sin estarlo es peor que uno que sabe que está en `off`. **Desde 3.4.0 las dos guardas las
declara `plugin.json`** con `${CLAUDE_PLUGIN_ROOT}`, como los otros tres hooks: `/rs-pii enforce` ya
no escribe en `~/.claude/settings.json`. Antes sí, y eso obligaba a cablear la ruta en absoluto —ahí
esa variable no se expande (§5)— mientras el caché de plugins lleva la **versión** en la ruta: cada
actualización dejaba las dos entradas apuntando a un directorio inexistente, y como el código de
error de un `.ps1` que no se encuentra no es 2, **fallaban abiertas sin avisar**. Los restos manuales
salen en `pii.guards_legacy` y los retira `cleanup-preplugin.ps1` al arrancar, con copia previa.
La verificación de `check_env` (`Test-RsPiiGuards`, `hooks/lib-pii.ps1`) es estructural **y de
existencia**: el `.ps1` declarado tiene que estar ahí; si no, sale en `pii.guards_stale` y cuenta
como ausente. `pii.guards_foreign` marca las que protegen desde otra copia del plugin (v2.11.0).
Comprueba la **instalación, no la sesión**: Claude Code resuelve los hooks al arrancar.

**Registradas ≠ actuando** (3.3.0). Las guardas siguen al modo del workspace de cada operación
(`Get-RsPiiEstadoGuarda`, `hooks/lib-pii.ps1`): en `off` no bloquean, en `audit`/`enforce` sí, fuera
de un workspace RS tampoco — y con el modo **indeterminado** bloquean, para que un workspace roto no
degrade en silencio a uno sin protección. La guarda de escritura resuelve el workspace desde el
`file_path` del evento (manda el destino, no la sesión); la de Bash, desde el `cwd`, que es su única
señal. `check_env` publica las dos caras: `guards_registered` (puesto de trabajo) y `guards_active`
(este workspace). El modo se lee con una regex sobre el modelo, no con `ConvertFrom-Json` — esto
corre en cada `Bash` y cada `Write`, y el modelo pesa cientos de KB; `check_env` contrasta esa
lectura rápida con el parseo completo que ya hace y publica `mode_mismatch` si divergen. La clasificación de columnas la hace
`scripts/pii_cli.py --clasificar`, no un clasificador reescrito en el prompt. ⛔ Gate de
confirmación explícita en cualquier dirección, incluida la vuelta a `off`. Ver `docs/proteccion-pii-consultas-bd.md` y §12
de este documento (los módulos `scripts/pii_*.py` que aplica la política).

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
**48 tools**, cada una decorada `@mcp.tool(description=...)`. La mayoría hace **shell-out a un
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
- `runner/runner.ps1` — evento `Stop`: ejecuta los builds encolados (batch-build / online-publish / service-build / copy-ais).

⛔ **Todo `.ps1` del repo va en UTF-8 con BOM.** No es estilo: sin BOM, Windows PowerShell 5.1
decodifica con la codepage ANSI y cualquier no-ASCII (un `—` basta) impide que el fichero **parsee**.
Si el roto es un `lib-*.ps1`, el fallo se manifiesta en quien lo dot-sourcea, no en él. Lo verifica
`tests/Encoding.Tests.ps1` (BOM + UTF-8 estricto + parseo, todos los `.ps1` menos `.venv`); el porqué
está en `hooks/README.md` § Convención de codificación y en CHANGELOG 3.4.6. Cuidado al crear o
reescribir un `.ps1` entero: editores y herramientas de escritura automática guardan sin BOM por
defecto.

⛔ **El intérprete de referencia es Windows PowerShell 5.1**, el que usa `plugin.json` con
`powershell -File`. Todo lo que se escriba aquí —hooks y también los tests que los ejercitan— tiene
que funcionar en 5.1, no solo en `pwsh`. Dos trampas ya pagadas, ambas verificadas hoy por
`tests/Encoding.Tests.ps1` y detalladas en `hooks/README.md`:

- `Join-Path` admite **dos** argumentos posicionales; el tercero (`-AdditionalChildPath`) es de
  PowerShell 6+. Usar `Join-Path $base "a/b/c"`, que vale en Windows y en Linux.
- `$IsWindows` **no existe en 5.1** (vale `$null`), así que `-not $IsWindows` se cumple en Windows.
  Comparar contra `$false` explícito.

Los dos fallan en **ejecución, no al parsear**, así que el parser no los caza y hacen falta
comprobaciones aparte. La suite se ejecuta con los dos intérpretes: `powershell` porque es el de
producción, `pwsh` porque es el del CI.

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
| `references/json-schema.md` | Esquema del `model.json` de BD, incluida la sección `objetos` (inventario: ficha + firma, no el cuerpo) |
| `references/mcp.md` | Catálogo completo de las 48 tools MCP |
| `references/hooks.md` | Catálogo completo de hooks con parámetros (tabla de equivalencia MCP↔hook) |
| `references/gates.md` | Procedimiento completo de los gates del pipeline (aprobación del plan, checklist final, log) |
| `references/testing.md` | Patrones de test RS/uCollect |
| `references/troubleshooting.md` | Fallos comunes (p.ej. MSB4019) |
| `references/jira.md` | Setup de la integración Jira (skill `rs-jira`): `.jira-dev-config.json`, credenciales, herramientas |
| `references/actualizador.md` | Entregas a cliente: tabla `RVERSIONES`, cálculo del delta, qué se empaqueta en instalador vs actualizador, exclusión de configuración, `rutas.json`, orden de instalación |
| `references/batch-config.md` | Configuración centralizada de los batch .NET Framework (`Batch\App.Batch.config` + `Batch\Directory.Build.targets`): qué es fuente y qué artefacto, excepciones por proyecto, dependencias de ODP.NET, adopción en un workspace |

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

### 9.5 Nuevo plugin en el mismo marketplace

Para una herramienta que **no es** una solución uCollect/RS (otro stack, sin `.sln`, sin las tools
MCP de este plugin): plugin aparte, no skills más aquí. Se instala y versiona por separado, y sus
triggers no contaminan al agente C#.

1. Árbol propio bajo `plugins/<nombre>/` con su `.claude-plugin/plugin.json` (`name`, `description`
   con triggers explícitos, `version` **independiente**, `author`) y las carpetas que necesite:
   `skills/`, `agents/`, `commands/`, `references/`.
2. Entrada nueva en el array `plugins` de `.claude-plugin/marketplace.json`, con
   `source: "./plugins/<nombre>"` y su `version`. La `version` de esa entrada y la de su
   `plugin.json` deben quedar **idénticas** (misma regla que el plugin raíz).
3. `README.md` y `CHANGELOG.md` propios dentro de su carpeta. El CHANGELOG del repo raíz solo
   registra el alta del plugin, no su evolución posterior.
4. La descripción del **marketplace** deja de describir a un solo plugin: revisarla.

⛔ El plugin nuevo **no hereda** nada del raíz: ni hooks, ni MCP server, ni references. Si necesita
un `plugin_root`, define su propia regla de resolución y verifícala con Glob contra carpetas que
existan en *su* árbol (`${CLAUDE_PLUGIN_ROOT}` sigue sin expandirse en markdown — §11.2).

⚠️ El plugin raíz mantiene `source: "./"`, así que su copia instalada incluye también `plugins/`.
Es peso muerto sin efecto funcional (§2): no se auto-descubre nada desde ahí.

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
| **Nuevo plugin en el marketplace** | `marketplace.json` (entrada + descripción del marketplace) · README raíz (sección de instalación) · CHANGELOG raíz (alta) · §1/§2/§9.5 este doc · README y CHANGELOG **propios** del plugin nuevo |
| Cambio de convención de dominio | reference correspondiente · CHANGELOG |
| **Cualquier cambio** | ⛔ **bump de versión** en `plugin.json` **y** `marketplace.json` (idénticas) + entrada `CHANGELOG.md` |

⛔ **Sin nombres de clientes, en ningún fichero del repo.** Ni en documentación, ni en el
CHANGELOG, ni en comentarios de código, ni en ejemplos o tests. Tampoco sus derivados
identificables: esquemas, usuarios de BD, nombres de solución que incluyan la marca, rutas de
instalación. Un caso real se cita como "una instalación de cliente" o "el proyecto donde se
detectó"; si hace falta la referencia concreta (una revisión, un ticket), va sin el nombre. Y
en un documento dirigido a terceros, los valores reales viajan en un anexo aparte —el
inventario de columnas del §6 de `docs/proteccion-pii-consultas-bd.md` es exactamente ese
caso—. Esto **no** aplica a lo que los agentes escriben en el workspace del cliente: ahí los
nombres propios son legítimos.

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

---

## 12. Módulos `scripts/pii_*.py`

Cuatro módulos Python sin dependencias externas (solo `re`, `json`, `fnmatch`, `hmac`, `hashlib` de
la librería estándar) que implementan la política de protección de datos personales de `db_query`.
Se cargan por `importlib.util.spec_from_file_location` — mismo patrón que usa
`mcp/rs-workspace-server.py` para el resto de módulos internos (`_load_model`, etc.) — nunca por
`import` de paquete: no hay `__init__.py` ni intención de instalarlos como paquete. Un quinto
módulo, `scripts/pii_patterns.json`, no es código sino la lista base de patrones de nombre.

| Módulo | Responsabilidad |
|---|---|
| `scripts/pii_detect.py` | Reconoce formas de dato personal (DNI, NIE, IBAN, correo, teléfono, tarjeta) en un VALOR suelto o en una columna completa. Puro, sin estado, no registra lo que inspecciona. Formas fuertes (DNI/NIE/IBAN/correo) bastan con un acierto; formas débiles y puramente numéricas (teléfono, tarjeta, DNI sin letra) exigen mayoría del 50% sobre los valores no vacíos, para no disparar por un importe suelto. |
| `scripts/pii_sqlscope.py` | Extrae tablas (`FROM`/`JOIN`) y columnas de predicado (`WHERE`) de un SQL de texto. No es un parser SQL: reconoce las formas habituales de las consultas que generan los agentes. Elimina antes los comentarios (`--`, `/* */`) con un escáner que respeta los literales de cadena; un literal sin cerrar (SQL malformado) hace que no se resuelva ninguna tabla — el alcance indeterminable degrada hacia el lado seguro (todo sin resolver, todo enmascarado), nunca al revés. |
| `scripts/pii_policy.py` | Clasifica cada columna del resultset como en claro, enmascarada o no resuelta, con la precedencia documentada en `docs/proteccion-pii-consultas-bd.md` §4.2: marca explícita del modelo → patrón de nombre → tabla paramétrica → tipo → resto de texto → no resuelta. Para las no resueltas, decide por la forma de los valores con una prueba numérica estricta (rechaza signo `+`, `inf`/`nan`, separadores de miles, y cualquier entero de 9+ dígitos sin parte decimal — forma de identificador, no de cantidad). Si `pii_patterns.json` no se puede leer, la lista de patrones falla **cerrada** a `["*"]` en vez de abrirse en silencio. |
| `scripts/pii_mask.py` | Punto único de transformación (`mask_resultset`): combina `pii_policy` + `pii_detect` sobre un resultset y sustituye los valores marcados por un seudónimo HMAC-SHA256 (clave de 32 bytes en el perfil local del usuario, `%LOCALAPPDATA%\rs-enterprise-agent\pii.key`, nunca en el repositorio) o por `[PII]` si `transform=suppress`. Es el módulo que importa directamente la tool MCP `db_query` (`mcp/rs-workspace-server.py`, vía `importlib`). |
| `scripts/pii_cli.py` | Envoltorio CLI de `pii_mask` (stdin JSON `{columns,rows,sql}` → stdout JSON `{columns,rows,pii}`) para que `hooks/db-query.ps1` pueda invocarlo como proceso — PowerShell no puede importar un módulo Python. El `model_path` se lo pasa el llamante (`Get-RsModelPath`), no lo busca él, y con él la marca `--convenio` (`Test-RsModelDeclarado`): sin ella una ruta cuyo fichero no existe se trata como **política declarada que no se aplica**, es decir error. Todo código de salida != 0 significa "corrí y no pude aplicar la política" → el hook falla cerrado. Modo `--clasificar` para `/rs-pii`. Nunca escribe un valor de dato personal en stderr, solo el nombre del problema (fichero, tipo de error). `stdin` se lee como `utf-8-sig` (PowerShell 5.1 antepone BOM al canalizar hacia un comando nativo) y `stdout`/`stderr` se reconfiguran a UTF-8: su salida es un pipe, no una consola, así que el encoding por defecto del proceso sería la página del sistema mientras el hook la descodifica como UTF-8. |

**`model_path` no dice si hay política.** `Get-RsModelPath` (`hooks/lib-dbconfig.ps1`) devuelve
siempre una ruta: sin campo `"model"` en la conexión cae al convenio `BD\<proyecto>-model.json`.
Por eso la declaración se publica aparte, `Test-RsModelDeclarado` → `get-config.ps1` →
`config["model_declarado"]` (por conexión y en los campos planos), y la consumen los dos caminos:
`_cargar_modelo` en la tool MCP y `--convenio` en el hook. La regla es la misma en ambos —
declarado y ausente = error sin filas; convenio y ausente = workspace sin política (`mode=off`);
presente y no parseable = error venga de donde venga la ruta. Sin esa información se asume
**declarado**: la imprecisión degrada hacia más enmascarado, nunca hacia menos.

**Por qué Python y no una segunda implementación en PowerShell.** El resto del plugin sigue la
convención "tool MCP ↔ hook fallback 1:1" con dos implementaciones independientes — una en Python
dentro de `rs-workspace-server.py`, otra en PowerShell en `hooks/*.ps1` (§7). La política PII rompe
esa convención a propósito para la parte de **clasificación**: la guarda de solo lectura (SELECT/CTE,
sin multi-statement) sí sigue duplicada entre la tool y el hook, como el resto, pero decidir si una
columna es dato personal es la lógica con más superficie de desacuerdo de todo el plugin, y una
divergencia ahí no sería un bug visible — sería una fuga silenciosa: la misma consulta enmascarada
por un camino y en claro por el otro. Por eso solo existe una implementación, en Python, y el hook la
invoca como subproceso (`pii_cli.py`) en vez de reescribirla; el coste es un `python.exe` adicional
por consulta cuando se usa el hook, pagado solo por quien cae al fallback (convención
Preferente/Fallback: la tool MCP se prefiere siempre).

`hooks/lib-pii.ps1` (§7) es la excepción deliberada a "una sola implementación": los guardas
`PreToolUse` (`pii-guard-bash.ps1`, `pii-guard-write.ps1`) y el saneado de `log-execution.ps1` no
procesan resultsets de BD — inspeccionan texto de comandos y de ficheros en el camino crítico de
cada `Write`/`Edit`/`Bash`, antes de que `db_query` entre en juego siquiera — así que invocar Python
ahí tendría un coste distinto (latencia por evento, no por consulta) y un subconjunto de formas
distinto es correcto a propósito (sin teléfono ni tarjeta, con validación de letra de control
DNI/NIE — ver `references/hooks.md` y el header de `hooks/pii-guard-write.ps1`). Que sea una única
librería (`lib-pii.ps1`) compartida entre esos dos consumidores PowerShell evita que esa segunda
regla de detección diverja en dos sitios.

---

## 13. Inconsistencias conocidas — histórico

**Resueltas** (histórico):
- **`subagents/` vs `agents/`** (2.15.2) — las referencias en ficheros versionados (`references/`,
  `commands/`, `scripts/install-hooks.ps1`) se actualizaron a `agents/` (carpeta real desde v2.0.0).
  El design spec vive en `docs/superpowers/` (no publicado, ver `.gitignore`) y queda fuera de este barrido.
- **Carpeta `BD/`** (2.15.2) — se retiró del árbol de estructura del `README.md`: el `model.json`
  vive en el workspace de cada solución cliente, no en el repo del plugin.
