# RS Enterprise Agent — Changelog

## 2.15.8 — 2026-07-22

### Fix: `installer-batch.ps1` — gate de binding redirects (config viejo + DLL nueva → StackOverflow)

`hooks/installer-batch.ps1` (etapa Batch de `/rs-instalador`). Segundo vector de frankenbuild, distinto
al de 2.15.7: en una **carpeta de deploy compartida**, last-writer-wins puede dejar un `<exe>.exe.config`
viejo (con `bindingRedirect newVersion=X`) junto a una `System.*.dll`/tercero **nueva**
(`AssemblyVersion=Y`). El redirect apunta a una versión que ya no está en la carpeta →
`FileLoadException` → bucle de re-resolución → **StackOverflow** en `RSActBD`/`RSCore`. La asunción
"terceros version-pinned = OK, no hace falta verificarlos" es **falsa** en carpeta compartida.

**Fix**: gate nuevo (bloqueante, tras el gate de coherencia por timestamp de 2.15.7). Para cada
`EXES\*.exe.config` se parsea `runtime/assemblyBinding/dependentAssembly` (namespace
`urn:schemas-microsoft-com:asm.v1`); por cada `bindingRedirect` cuyo `<name>.dll` **está físicamente
desplegado** (si no lo está, se resuelve de GAC y no aplica), se compara `newVersion` del config contra
la `AssemblyName.Version` real del DLL (`[System.Reflection.AssemblyName]::GetAssemblyName`). Si no
coinciden → se listan `config · assembly · newVersion vs real` y **exit 1**, no se despliega.

## 2.15.7 — 2026-07-22

### Fix: `installer-batch.ps1` generaba frankenbuilds → StackOverflowException al arrancar

`hooks/installer-batch.ps1` (etapa Batch de `/rs-instalador`). El hook compilaba con `dotnet build`
**incremental**, por-sln y sin verificación final. En un caso real (B2Impact) dejó en `EXES` 8 exes
del build 07-20 15:33 junto a `Comun.dll`/`BusComun.dll`/`RsExtrae.exe` del 07-21 10:31.

**Causa raíz**: las DLLs compartidas (`Comun`/`BusComun`/`RSModel`) **no tienen strong-name** y su
`AssemblyVersion` es `1.0.*` → el CLR las enlaza **por nombre simple**. Un exe viejo, compilado
contra un snapshot distinto de esas DLLs, llama en runtime a un método cuya firma cambió → recursión
infinita → **StackOverflowException** al arrancar `RSActBD.exe`. Agravante: `dotnet build` de una
`.sln` con proyecto de Tests (p.ej. `RsExtrae.Tests`) fallaba y dejaba su `.exe` **sin actualizar** =
el straggler exacto observado.

**Fix** (reescritura del hook):

- **Rebuild desde snapshot único, no incremental** — `msbuild /t:Rebuild` (VS2022 via `vswhere`, mismo
  patrón que `installer-agendaweb`), precedido de un **wipe de todos los `bin`/`obj` del scope** en una
  sola pasada. Sin restos de builds anteriores.
- **Los proyectos de Tests ya no rompen ni contaminan el build** — no se compila la `.sln` entera; se
  resuelven los **csproj-exe** (`<OutputType>Exe|WinExe`, fallback = csproj homónimo de la sln) y se
  compilan **directamente** con `-t:Rebuild`, arrastrando sus `<ProjectReference>` (las DLLs
  compartidas se recompilan del mismo snapshot). El `*.Tests` queda fuera.
- **Gate de coherencia final (bloqueante)** — se sella `$buildStart` antes de compilar; tras copiar,
  todo `*.exe` + DLLs compartidas (`Comun`/`BusComun`/`RSModel`, override por JSON `sharedAssemblies`)
  en `EXES` debe tener `LastWriteTime >= $buildStart`. Cualquier fichero de otra fecha → se listan y
  **exit 1**, nunca "OK".
- **Aviso de la trampa estructural `HintPath`** — detecta `<Reference><HintPath>..\bin\Debug\X.dll`
  cuando existe `X.csproj` en el workspace (debería ser `<ProjectReference>`): se enlaza contra una DLL
  de otro build. Advisory (no falla). Ya corregida en B2Impact r14970.

## 2.15.6 — 2026-07-22

### Fix: inserts del instalador vacíos por saltos de línea (regresión de 2.15.5)

`scripts/installer-inserts.py` (`Inserts\<TABLA>.sql` de `/rs-instalador`). Tras 2.15.5, tablas con
texto multilínea (p.ej. `RACCION.ACSQL`, con sentencias SQL de varias líneas) generaban **0 inserts**
(`-- (sin filas)`), y los scripts de idiomas salían **incompletos**.

**Causa raíz** (reproducida contra Oracle real, mínima):

```
SELECT 'linea1' || CHR(10) || 'linea2' || '@@ROWEND@@' FROM DUAL   ->   linea1
```

sqlplus en modo `PAGESIZE 0` **trunca el valor en el primer `CHR(10)` interno**: se pierde el resto
del dato **y** el terminador de fila `@@ROWEND@@`. Sin terminador, las filas se fundían (`nº campos
28 != 4`) y **todas** se descartaban. El terminador de fila que introdujo 2.15.5 iba al **final**, es
decir, detrás del salto — por eso siempre se perdía. Reubicarlo no sirve: cualquier cosa tras el 1er
`\n` muere.

**Fix**: la query **codifica** `CHR(13)`/`CHR(10)` como tokens (`@@CR@@`/`@@LF@@`) vía `REPLACE`
anidado, de modo que **cada fila sale en una sola línea física** (sin truncado); Python revierte los
tokens a saltos reales tras trocear, y el literal SQL queda multilínea (válido en Oracle/SQL Server).
El troceo por `@@ROWEND@@` se mantiene como red de seguridad. Aplica a ambos motores.

Verificado contra una BD Oracle real: `RACCION` (9 filas, todas con salto interno) pasó de **0** a
**9** inserts, con el `ACSQL` completo y multilínea. Test de aislamiento del round-trip
codificar→trocear→decodificar.

## 2.15.5 — 2026-07-22

### Fix: inserts del instalador — acentos corruptos y pérdida de filas con salto de línea

Dos bugs en `scripts/installer-inserts.py` (los ficheros `Inserts\<TABLA>.sql` que genera
`/rs-instalador`).

- **Acentos como caracteres corruptos** — los `.sql` se escribían en UTF-8 **sin BOM**; las
  herramientas gráficas de Oracle (SQL Developer/TOAD/PL-SQL Developer) asumían Windows-1252 y los
  acentos salían mal. Ahora se escriben con **BOM UTF-8** (`utf-8-sig`), que esas herramientas
  detectan. Los ficheros de inserts son independientes (se ejecutan aparte), así que el BOM no afecta
  a ningún flujo de `@@include`.
- **Pérdida de filas con salto de línea** — la salida del SELECT se troceaba **por líneas**
  (`splitlines`), asumiendo "1 fila = 1 línea". Un valor de texto con un salto de línea hacía que la
  fila ocupara varias líneas de salida; cada trozo quedaba con un nº de campos distinto al esperado y
  la fila **se descartaba entera** (`-- AVISO fila omitida`). Ahora el SELECT añade un terminador de
  fila `@@ROWEND@@` y la salida se trocea por ese terminador (`_split_rows`), no por `\n`: los saltos
  internos de un valor se conservan dentro de su literal SQL (multilínea, válido en Oracle).

Verificado con tests de aislamiento: el nuevo troceo recupera las filas que el viejo perdía por el
salto de línea, y el fichero se escribe con BOM. (No se puede probar Oracle/sqlplus en el entorno de
desarrollo Linux; la lógica de parseo y de codificación sí se prueba.)

**Fuera de alcance (deliberado)**: el DDL (`installer-ddl.py`) y los objetos
(`installer-objects.py`) NO llevan BOM — su maestro `CreacionObjetos.sql` los encadena con `@@`, y un
BOM en cada sub-fichero podría romper ese `@@include`. Si aparecieran acentos corruptos en
vistas/triggers, se aborda aparte con otro enfoque.

## 2.15.4 — 2026-07-22

### Fix: los slash commands `/rs-*` no mostraban descripción al teclearlos

**Síntoma**: al escribir un `/rs-*`, Claude Code no mostraba la descripción del comando (salvo
`/rs-enterprise-agent`).

**Causa**: el `description:` del frontmatter iba **sin comillas** y contenía `: ` interno (p.ej.
`... Uso: /rs-audit ...` o `Estadísticas del pipeline: total...`). YAML interpreta ese `: ` como un
mapping anidado y **falla al parsear el frontmatter entero** → Claude Code no lee la descripción. Solo
`/rs-enterprise-agent` funcionaba porque su descripción ya iba entrecomillada.

- **Todos los `commands/*.md`**: `description` entrecomillada (comillas dobles, escapando internas) —
  el frontmatter vuelve a parsear.
- **`argument-hint` añadido** a cada comando: muestra los parámetros al teclear (`< >` fijos, `[ ]`
  opcionales), p.ej. `/rs-migrar <Solution>.sln a <ORACLE|SQLSERVER>`. La cola redundante "Uso: ..."
  se retira de la descripción, que ahora la cubre `argument-hint`.

## 2.15.3 — 2026-07-22

### Tier 3 (3/n): dedup del post-proceso de diff svn/git en el MCP server

`svn_diff_revision` y `git_diff_revision` (`mcp/rs-workspace-server.py`) duplicaban ~30 líneas
idénticas de post-proceso (construcción del resumen por fichero: `+lines`/`-lines`/`symbols`), que
solo diferían en el marcador de fichero del diff (`Index:` en SVN vs `diff --git` en Git).

- **Nuevo helper `_diff_summary(diff_text, revisions, file_header_re)`** — fuente única del resumen;
  cada tool le pasa su regex de cabecera. El regex de símbolo C# se extrae a una constante compilada
  `_DIFF_SYMBOL_RE` (antes recompilado por línea).
- Se eliminan los `import re as _re` locales redundantes (el módulo ya importa `re` arriba) y una
  variable muerta en la rama SVN (`files_changed = raw.get("files_changed", [])`, asignada y nunca
  usada).
- **Sin cambio de comportamiento**: verificado con un test de equivalencia que compara la salida JSON
  del código viejo y el nuevo sobre diffs SVN y Git representativos (incluido diff vacío) — idénticas.

Los wrappers finos `svn_status`/`git_status`, `svn_add`/`git_add`, `svn_log`/`git_log` se dejan como
están: son ~4 líneas cada uno y deben seguir siendo tools MCP separadas con su propia descripción y
sus guardas/fallbacks específicos (git exige `_check_git_cli`; svn ofrece fallback TortoiseSVN).

## 2.15.2 — 2026-07-22

### Tier 3 (2/n): corrección del drift de documentación

Resuelve dos de las inconsistencias conocidas del §11 de `docs/plugin-architecture.md` y varias
imprecisiones de la doc. Solo documentación (+ un arreglo de ruta en un script de instalación
legacy). No cambia el runtime del plugin.

- **`subagents/` → `agents/`** — se actualizan las referencias a la carpeta antigua en ficheros
  versionados: `references/hooks.md`, `references/testing.md`, `commands/rs-erd.md`,
  `commands/rs-sync-indexes.md`. Además `scripts/install-hooks.ps1` tenía la **misma** ruta rota
  (`Join-Path $SkillPath "subagents"`) que ya se corrigió en `install-to-project.ps1` en 2.14.1 —
  ahora apunta a `agents/`. (El design spec vive en `docs/superpowers/`, no publicado — queda fuera.)
- **Hook `SessionStart` documentado** — `plugin.json` declara tres hooks (SessionStart → 
  `cleanup-preplugin.ps1`, Stop, UserPromptSubmit), pero `docs/plugin-architecture.md` (§2 y §7) y el
  `README.md` (§Estructura) solo mencionaban dos. Añadido el SessionStart en los tres sitios.
- **Carpeta `BD/`** — retirada del árbol de estructura del `README.md`: el `model.json` vive en el
  workspace de cada solución cliente, no en el repo del plugin (el árbol la listaba con un
  "(no en el repo)" contradictorio).
- **Conteo de agentes** — `README.md` decía "27 subagentes"; son **28**.
- **§11** actualizado: las dos inconsistencias resueltas se mueven a un apartado "Resueltas" con su
  versión; quedan como conocidas solo `settings.json` (legacy con `_note`) y la no-expansión de
  `${CLAUDE_PLUGIN_ROOT}` en markdown (mitigada en 2.12.0).

## 2.15.1 — 2026-07-22

### Tier 3 (1/n): helper Python compartido para el mapeo de tipos entre motores

Primer paso de la deduplicación del Tier 3. El bloque de mapeo de tipos Oracle ⇄ SQL Server
(`ORACLE_TO_SS`, `SS_TO_ORACLE`, `adapt_type`, `ensure_oracle_char_semantics`) estaba copiado
literalmente en `scripts/generate-sql.py` y `scripts/installer-ddl.py`.

- **`scripts/_dbtypes.py`** (nuevo) — fuente única. Los scripts se ejecutan con `scripts/` en
  `sys.path`, así que `import _dbtypes` resuelve sin trucos (a diferencia de los otros scripts, cuyo
  nombre lleva guion y no son importables directamente).
- **Corrige un drift ya existente**: las dos copias habían divergido — `installer-ddl.py` se había
  quedado sin la entrada `RAW → VARBINARY` que sí tenía `generate-sql.py`. Al unificar sobre el
  superconjunto, `installer-ddl.py` ahora mapea correctamente las columnas `RAW` de Oracle a
  `VARBINARY` en SQL Server (antes las dejaba como `RAW`, tipo inexistente en SQL Server). Cambio de
  comportamiento intencionado en el DDL generado para columnas `RAW`.
- Sin cambios de comportamiento en el resto de conversiones (verificado: ambos scripts comparten
  ahora el mismo objeto `adapt_type`; casos representativos idénticos).

Pendiente en próximos pasos del Tier 3: colapsar las funciones `svn_*`/`git_*` casi idénticas del
MCP server y corregir el drift de documentación (§11 de `docs/plugin-architecture.md`).

## 2.15.0 — 2026-07-22

### Higiene de proyecto: manifiesto de dependencias + CI

Infraestructura de desarrollo que faltaba por completo en el repo. No cambia el runtime del plugin.

- **`requirements.txt`** — el MCP server importa `from mcp.server.fastmcp import FastMCP`
  (`mcp/rs-workspace-server.py`), una dependencia de terceros que hasta ahora no estaba declarada en
  ninguna parte (solo prosa en el README). Se fija `mcp>=1.2.0` (piso donde `mcp.server.fastmcp` es
  estable). Las CLIs externas (sqlplus, sqlcmd, svn, git, dotnet, msbuild) no son deps Python y se
  siguen comprobando en runtime.
- **CI en GitHub Actions** (`.github/workflows/ci.yml`) — primer conjunto de checks automáticos del
  repo, sobre cada PR y push a `main`:
  - `py_compile` del MCP server y de los scripts Python.
  - **Paridad de versión** `plugin.json` == `marketplace.json` + verificación de que `CHANGELOG.md`
    tiene entrada para esa versión (`.github/scripts/check_version.py`) — automatiza el invariante de
    publicación del §10 de `docs/plugin-architecture.md`, el error más fácil de cometer al publicar.
  - **PSScriptAnalyzer** sobre los `.ps1` de `hooks/`, `scripts/` y `runner/`. Falla solo con
    severidad Error/ParseError (los warnings se listan pero no rompen el build) — caza fallos de
    sintaxis PowerShell que el entorno Linux de desarrollo no puede validar en vivo.

## 2.14.1 — 2026-07-22

### Seguridad y correctitud en el fallback `db-query.ps1` + script de instalación por proyecto

Arreglos de bajo riesgo que no tocan el pipeline ni el contrato de las tools MCP. `hooks/db-query.ps1`
es el **fallback 1:1** de la tool MCP `db_query` (convención Preferente/Fallback, `references/hooks.md`);
regresaba tres protecciones que el camino MCP (`mcp/rs-workspace-server.py`) ya tenía. Ahora quedan
alineados con ese patrón:

- **Password fuera de la línea de comando** — antes `sqlplus -S "$user/$password@$dataSource"` dejaba
  la contraseña visible en la lista de procesos durante toda la consulta. Ahora usa `/nolog` +
  `CONNECT` escrito en el script SQL temporal, igual que la rama Oracle de la tool MCP. `WHENEVER
  SQLERROR EXIT SQL.SQLCODE` va antes del `CONNECT` para que un login fallido salga con el código de
  error.
- **Guarda SELECT-only** — el hook interpolaba `$Sql` directo en el script sqlplus sin validación, así
  que cualquier sentencia (`DROP`/`DELETE`/bloque PL/SQL) se ejecutaba. Se añade la misma validación
  que `db_query`: exige que empiece por `SELECT` y bloquea multi-statement (`;` fuera de literales).
- **Fuga de fichero temporal** — `GetTempFileName() + ".sql"` creaba un fichero de 0 bytes en OTRA ruta
  que nunca se limpiaba. Ahora las rutas temp se generan con `[Guid]` y ambas se borran en el `finally`.

- **`scripts/install-to-project.ps1`** — apuntaba a la estructura pre-v2: la carpeta de subagentes
  `subagents\` (real: `agents\` desde v2.0.0) y la versión leída de un `SKILL.md` en la raíz (hoy en
  `skills\rs-enterprise-agent\` y la versión en `plugin.json`). Se corrigen ambas rutas; la versión se
  lee ya de `.claude-plugin\plugin.json` (fuente canónica). Resuelve dos de las inconsistencias del §11
  de `docs/plugin-architecture.md`.

## 2.14.0 — 2026-07-21

### Portabilidad: el plugin deja de depender del árbol del mantenedor

**Síntoma**: el pipeline reportaba `Plugin root: N:\SVN\RS\Agentes\SkillsClaude\rs-skill-full` y el
proceso MCP vivo era `python N:/SVN/.../mcp/rs-workspace-server.py`, pese a existir una copia
instalada en `~/.claude/plugins/cache/.../2.13.0`.

**Diagnóstico**: el marketplace estaba registrado como `source: directory` apuntando al repo fuente.
Un marketplace `directory` no se clona — el plugin (`source: "./"`) se resuelve relativo a esa ruta y
`${CLAUDE_PLUGIN_ROOT}` expande a ella, así que hooks, runner y MCP se ejecutan *in situ*. El
`installPath` del cache es un snapshot que no se usa en runtime. Consecuencia: cualquier usuario sin
esa unidad montada no podía usar el plugin.

- **Distribución** — la fuente canónica pasa a ser el repo Git privado
  `https://github.com/vgege86/rs-enterprise-plugin.git`. Con origen Git, Claude Code clona el
  marketplace y ejecuta el plugin desde `~/.claude/plugins/cache/<mp>/<plugin>/<versión>/`.
  `README.md` §Instalación reescrito (incluye quitar el marketplace `directory` anterior con
  `/plugin marketplace remove`); se corrige la afirmación falsa de que el cache hacía innecesaria la
  unidad de red.
- **Nuevo `.gitignore`** — fuera del repo publicado: `executions/`, `settings.local.json`,
  `docs/superpowers/` y `.superpowers/` (planes y specs de sesiones de desarrollo del propio plugin,
  con hosts de BD, usuarios y nombres de proyecto de cliente).
- **Contrato de tools MCP (BREAKING para los agentes)** — `mcp__rs-workspace__*` →
  `mcp__plugin_rs-enterprise-agent_rs-workspace__*` en 142 referencias de 40 ficheros (frontmatter
  `tools:` de los 27 agentes, comandos, skills, references y docs). El nombre corto no lo aportaba el
  plugin sino un registro manual en `~/.claude.json` que apuntaba al árbol fuente de quien lo creó;
  el namespaced lo aporta `.mcp.json` del propio plugin. El plugin queda autocontenido.
- **`scripts/cleanup-preplugin.ps1`** — eliminada la lista de rutas absolutas
  (`$env:RS_SKILL_SRC` → unidad de red → árbol de desarrollo → `$pluginRoot`) y toda la rama de
  "repunte" del MCP, que era justo lo que ataba el plugin a una ruta concreta. Ahora **elimina** el
  registro global `rs-workspace` de `~/.claude.json` (ya sobra), con backup previo en
  `~/.claude/_backup-preplugin-<fecha>/`. La edición es textual y se valida con la nueva
  `Test-JsonEstructura`: `~/.claude.json` tiene claves que solo difieren en mayúsculas
  (`ConvertFrom-Json` aborta) y `Test-Json` no existe en Windows PowerShell 5.1, que es quien ejecuta
  los hooks.
- **`hooks/skill-trigger.ps1`** — el gate dejaba pasar solo rutas que contuvieran `\SVN\RS\`. Ahora
  detecta el workspace por estructura (`Batch\Soluciones`, `OnLine\Soluciones`,
  `OnLine\AISServiceManager`, `docs\.rs-databases.json`), con override `$env:RS_WORKSPACE_MATCH`.

### Anonimización de datos de cliente

El repo se reparte a todos los usuarios del plugin, así que no puede llevar nombres de proyecto de
cliente. Sustituidos por el placeholder `<Proyecto>` / `<proyecto>` / `MIPROYECTO`:

- **19 hooks** — ejemplos `.EXAMPLE` y rutas `C:\Desarrollo\SVN|Git\...` → `C:\SVN|Git\RS\<Proyecto>\trunk`.
- **Triggers de la skill** (`plugin.json`, `skills/rs-enterprise-agent/SKILL.md`,
  `commands/rs-enterprise-agent.md`, `commands/rs-instalador.md`) y ejemplos de
  `agents/rs-editor-core.md`, `agents/rs-editor-planner.md`, `agents/rs-validar-entorno.md`,
  `references/arquitectura.md`, `references/json-schema.md`, `scripts/installer-objects.py`.
- **`scripts/erd-template.html`** — además de anonimizar, **fix real**: `generateTableSQL` emitía
  `CREATE TABLE`/`CREATE INDEX` con un schema hardcodeado en lugar del schema del modelo; ahora usa
  `_sch()`.

### Documentación

- **`docs/plugin-architecture.md`** — nueva §1.1 "Dónde se ejecuta realmente el plugin": tabla
  marketplace `git` vs `directory`, qué raíz efectiva implica cada uno, y cómo verificarlo
  (`Get-CimInstance Win32_Process` sobre el proceso python del MCP).
- **`skills/rs-enterprise-agent/SKILL.md`** — la comprobación de instalación duplicada cubre ahora
  también el caso "MCP servido desde una unidad de red o un árbol de desarrollo".
- **`skills/rs-plugin-dev/SKILL.md`** y **`README.md`** — el alcance y la fuente canónica se definen
  por `plugin_root` / el repo Git, no por una ruta fija.

## 2.13.0 — 2026-07-21

### Cambio de formato de configuración de BD (BREAKING)

`docs\XMLConfig.xml` queda sustituido por `docs\.rs-databases.json`, que soporta N conexiones.
Motivación: <Proyecto> se despliega sobre Oracle y SQL Server desde el mismo modelo lógico, y
hacía falta declarar ambos motores para generar el DDL de los dos.

- **Nuevo** `hooks\lib-dbconfig.ps1` — lectura y validación del formato, y parseo de cadenas de
  conexión. Único sitio que conoce el formato.
- **Nuevo** `hooks\convert-config.ps1 <workspace> [-Force]` — convierte el XMLConfig existente.
  No borra el XML.
- `get-config.ps1` mantiene todos sus campos planos (= conexión principal, `conexiones[0]`) y
  añade `conexiones[]` y `motores[]`. Retrocompatible para workspaces de una sola conexión.
- `db-query.ps1` y `db_query` aceptan `-Conexion` / `conexion` (id). Sin él, la principal.
- `generate_sql` sin `motor` genera un fichero DDL por cada motor declarado.
- `check-env.ps1` valida el JSON (conexiones no vacías, ids únicos, motor soportado) y da FAIL
  con instrucciones si el workspace no está migrado.
- `compare-model.ps1`, `sync-from-db.ps1`, `sync-indexes.ps1`, `sync-model-tables.ps1` y
  `scripts\installer-inserts.py` también dejan de leer `XMLConfig.xml` y pasan por
  `lib-dbconfig.ps1` (el `.py`, al no poder dot-sourcear el `.ps1`, replica la lectura directa del
  JSON que ya usa `_get_db_password` en el MCP server). Los cinco operan solo sobre la conexión
  principal.
- **Sin fallback a XML.** Verificado: ningún camino de código lee ya `XMLConfig.xml` — las únicas
  referencias que quedan son la detección de legacy en `hooks\lib-dbconfig.ps1` y
  `hooks\check-env.ps1` (le dicen a un workspace sin migrar qué comando de conversión ejecutar), más
  `hooks\convert-config.ps1`, que lee el XML porque es justamente el conversor.

`generate_migration` sigue operando solo sobre la conexión principal: compara contra la BD real
y solo la principal se consulta.

### Consultas a BD: resultados estructurados y cuatro bugs de fondo

`db_query` devolvía las líneas de texto tal cual las escupía el cliente SQL. Ahora devuelve
`columns[]` (los nombres una sola vez) y `rows[]` (listas de valores en ese mismo orden) — forma
compacta, un 19% menos de contexto que el texto crudo que sustituye. Lo que se arregla por el
camino, todo verificado contra la BD de <Proyecto>:

- **Nombres de columna truncados.** Con salida tabular, sqlplus recorta la cabecera al ancho del
  campo: una columna `IDIOMA` con valores `'ES'` se anunciaba como `ID`. El agente recibía —y podía
  usar en el SQL que generaba— un nombre de columna que no existe en la BD. Ahora se usa
  `SET MARKUP CSV` (sqlplus 12.2+), que da el nombre completo.
- **Cabeceras contadas como datos.** Con `PAGESIZE 50`, sqlplus repite la cabecera cada 48 filas y
  todas ellas entraban en `rows`. `row_count` devolvía 62 para una consulta de 60 filas, y 2 para
  un escalar de 1 fila.
- **Un error SQL se reportaba como éxito.** Faltaba `WHENEVER SQLERROR EXIT SQL.SQLCODE`, así que
  sqlplus salía con código 0 ante un `ORA-` y la respuesta era `success: true` con 0 filas —
  indistinguible de "la tabla está vacía". Los `ORA-`/`SP2-` se leen ahora de stdout, que es donde
  sqlplus los escribe.
- **La rama SQL Server ignoraba la contraseña.** Construía el `sqlcmd` sin `-U`/`-P`, forzando
  autenticación integrada de Windows aunque la config declarase usuario y contraseña.

`hooks\db-query.ps1` recibe los mismos arreglos de fondo (`MARKUP CSV`, `WHENEVER SQLERROR`), y
además escribía su `.sql` temporal con BOM (rompía el primer `SET` con `SP2-0734`) y colapsaba a
escalar con una sola fila o columna, produciendo claves no-string que hacían fallar
`ConvertTo-Json`. Su forma de salida **no** es la de la tool: el hook devuelve
`rows: [{columna: valor}]` y `truncated`, mientras la tool devuelve `columns[]` + `rows[][]` y
`rows_truncated`. Solo importa a quien invoque el hook a mano — el plugin no lo llama.

⚠️ La rama SQL Server no ha podido verificarse contra un servidor real: la cuenta de la conexión
SQL Server de <Proyecto> está deshabilitada. Oracle sí está verificado extremo a extremo.

- Un `XMLConfig.xml` en formato `<Conexion>` con motor SQLSERVER cuyo connection string incluya
  `Database=` ahora produce `schema` = ese catálogo, donde el hook antiguo emitía `schema` vacío.
  Verificado con fixtures ejecutando ambas versiones. Es una corrección: el valor vacío se pasaba
  a `sqlcmd -d`. Ningún proyecto actual usa esa combinación.
- La misma corrección aplica en `sync-from-db.ps1`: con motor SQLSERVER pasaba `-d` vacío a
  `sqlcmd` (bug preexistente en el hook antiguo); ahora pasa el catálogo real (`dataBase` de la
  conexión, o `Database=` de la cadena como fallback). Decisión consciente: se documenta como
  desviación intencional para que no sorprenda a quien compare comportamiento antiguo vs nuevo.
  Ningún proyecto actual usa esa combinación.

**Migración:** ejecutar `hooks\convert-config.ps1` en cada workspace. El conversor no borra el
`XMLConfig.xml`: retirarlo debe hacerse en un commit aparte y solo después de que esta versión del
plugin esté desplegada, porque una versión anterior sigue leyendo el XML y se quedaría sin config.

**Sobre versionar el JSON:** el fichero contiene el password dentro de `cadena`, igual que hacía
`XMLConfig.xml`. Si el workspace declara varias conexiones, concentra todas sus credenciales en un
único fichero. Queda a criterio de cada proyecto versionarlo o dejarlo fuera del control de
versiones (como ya está `docs\.jira-dev-config.json`) y generarlo por desarrollador con el
conversor.

## 2.12.2 — 2026-07-21

Auditoría del DDL del instalador contra la BD real de <Proyecto> (316 tablas): el script generado
**no se podía ejecutar entero**. Dos defectos de `installer-ddl.py` lo rompían y un tercero
degradaba las PK.

- **La coma separadora quedaba dentro del comentario de columna → `ORA-00907`.** El generador
  concatenaba `  -- <descripcion>` al final de la línea de columna y luego unía las líneas con
  `',\n'`, así que salía `COL VARCHAR2(40) NOT NULL  -- texto,` y la coma no separaba nada.
  Afectaba a 23 columnas en 11 tablas —justo las centrales: RBGES, RCLIENTECS, RCONVP, RESPECIE,
  ROBCL, ROBLG, RPRODUCTOS, RRELARATR, RTARS, RTARSDISC, RUSUARIOS—. Confirmado con el parser real
  de Oracle sobre el bloque de RCLIENTECS. Ahora la coma se emite **antes** del comentario.
- **Índice con el mismo nombre que la PK de su tabla → `ORA-00955`.** El filtro que evitaba emitir
  el índice que respalda la PK comparaba la lista de columnas *en orden*; si el modelo traía el
  índice con las columnas ordenadas distinto, se colaba un `CREATE UNIQUE INDEX PK_<tabla>` además
  del `CONSTRAINT PK_<tabla>` inline. Pasaba con `PK_RPAGOS` y `PK_RHTELE`. Ahora se compara por
  conjunto de columnas y, además, se descarta cualquier índice cuyo nombre sea el de la constraint.
- **Orden de columnas de la PK.** `pk_cols` salía del orden de declaración de las columnas, no de
  la posición real dentro de la PK: 19 tablas generaban la PK con las columnas en otro orden que
  producción (RTBGES, RCOMPAGO, RHLOTE, RMAILS, RTELE...), lo que cambia el índice que la respalda
  y tira los accesos por prefijo de clave. `pk` pasa a admitir un **entero con la posición** además
  del booleano; nueva función `pk_columns()` que ordena por él (retrocompatible: `bool` se descarta
  explícitamente antes de tratarlo como ordinal, porque en Python `True` es `1`).
  Documentado en `references/json-schema.md`.
- **Verificación tras el arreglo** (<Proyecto>, 380 tablas emitidas): 0 comas dentro de comentario,
  0 errores estructurales de separador, 0 índices con nombre de PK, 267/267 PK con las columnas en
  el mismo orden que la BD, 65/65 índices no-PK reales presentes con columnas y unicidad idénticas,
  y los 74 índices emitidos existen los 74 en la BD.
- **Ficheros**: `scripts/installer-ddl.py`, `references/json-schema.md`.

## 2.12.1 — 2026-07-20

Tres fallos reales detectados ejecutando `/rs-instalador` de principio a fin sobre <Proyecto> (Oracle).
El instalador terminaba con AgendaWeb sin publicar y 23 de 94 tablas paramétricas sin inserts.

- **`installer-agendaweb.ps1`: el publish generaba un `.zip` en vez de publicar a carpeta.** Con
  `/p:DeployOnBuild=true` pero **sin** `DeployTarget`, msbuild elige el target `Package` y deja
  `obj\Release\Package\<app>.zip`; el hook abortaba con `ERROR: publish sin ficheros`.
  - Se añade `/p:DeployTarget=WebPublish` y se pasa el `agendaweb.publishProfile` del JSON de config
    como `/p:PublishProfile` (p.ej. `FolderProfile`).
  - `publishUrl` sigue forzado al Instalador como propiedad global —gana al `<PublishUrl>` del
    `.pubxml`, que apunta al AIS **en vivo**— y se añade `/p:DeleteExistingFiles=false` como red de
    seguridad: si el override fallara, el peor caso es añadir ficheros al AIS, no borrarlo.
  - Verificado en real: `Publish profile: FolderProfile`, 544 ficheros en
    `C:\AIS\<Proyecto>\Instalador\AgendaWeb`, sin `.zip`, exit 0.
- **`installer-inserts.py`: 23 tablas sin inserts por tres defectos del generador de SQL.**
  - `SP2-0341` en tablas anchas (RCARTERA 34 columnas, RCARTERA_DEL, RPARAM): el SELECT de
    concatenación se emitía en **una sola línea**. Ahora va una expresión por línea.
  - `ORA-01489` latente por el mismo motivo: la primera expresión se envuelve en `TO_CLOB` para que
    toda la concatenación sea CLOB en vez de quedarse en el límite de 4000 de `VARCHAR2`.
  - `ORA-00932 expected NUMBER got BINARY` (RCENTMENSA `CMIDHILO`/`CMIDMENSAJE`, CUSUARIO `CUID`):
    se aplicaba `TO_CHAR` a columnas `RAW`. Ahora los binarios cortos (`RAW`/`VARBINARY`/`BINARY`)
    viajan en hexadecimal y se reconstruyen en el INSERT (`HEXTORAW('..')` en Oracle, literal `0x..`
    en SQL Server).
  - Los LOB binarios (`BLOB`/`LONG RAW`/`IMAGE`) no son inlineables en un INSERT de texto: se emiten
    como `NULL` y se avisa en la cabecera del `.sql` con la lista de columnas afectadas, en vez de
    reventar la tabla entera.
  - Verificado contra la BD real de <Proyecto>: las 5 tablas que fallaban generan ahora
    (RCARTERA 178, RCARTERA_DEL 181, RPARAM 1, RCENTMENSA 10, CUSUARIO 6 filas).
- **11 hooks `.ps1` guardados sin BOM no parseaban en Windows PowerShell 5.1.** `plugin.json` y
  `runner/runner.ps1` invocan `powershell -File ...` (5.1), que sin BOM decodifica el fichero con la
  codepage ANSI: los acentos rompían literales y bloques (`Falta la cadena en el terminador: "`,
  `Falta el nombre de tipo después de '['`). Fallaban los 4 hooks del instalador y
  `git-diff-revision.ps1`; los otros 6 eran latentes (mojibake en pantalla).
  - Reguardados en **UTF-8 con BOM** (solo cambia el BOM, cero cambios de código):
    `detect-vcs`, `git-add`, `git-diff-revision`, `git-log`, `git-status`, `installer-agendaweb`,
    `installer-batch`, `installer-scripts`, `installer-servicemanager`, `jira-attach`,
    `sync-model-tables`.
  - Convención documentada en `hooks/README.md` con el snippet de comprobación. Antes: 48/53 `.ps1`
    parseaban bajo 5.1; ahora **53/53**.
- **No reproducido**: el reporte incluía un cuarto fallo (`db-query.ps1` línea 110, `ConvertTo-Json`
  con `OrderedDictionary` bajo pwsh 7). Comprobado en pwsh 7.6.3 y en PS 5.1: serializa correctamente
  (`{"rows":[{"A":1,"B":2}]}`). No se toca. Queda anotado que el defecto real conocido de `db_query`
  con multicolumna está en el `-split '\|'` (valores que contienen `|`), pendiente de abordar aparte.
- **Ficheros**: `hooks/installer-agendaweb.ps1`, `scripts/installer-inserts.py`, 11 `.ps1`
  reguardados con BOM, `hooks/README.md`, `references/hooks.md`.

## 2.12.0 — 2026-07-20

- **`${CLAUDE_PLUGIN_ROOT}` no se expande en markdown — el contrato `skill_dir` apuntaba a la carpeta
  equivocada.** Síntoma reportado al ejecutar `/rs-instalador`: el agente avisaba de que el `skill_dir`
  recibido (`...\2.11.0\skills\rs-enterprise-agent`) no contenía `hooks\` ni `runner\`, y tenía que
  deducir la raíz del plugin por su cuenta.
  - **Diagnóstico**: Claude Code solo sustituye `${CLAUDE_PLUGIN_ROOT}` en `.claude-plugin/plugin.json`
    y `.mcp.json` (JSON). En `skills/*/SKILL.md`, `agents/*.md` y `commands/*.md` la variable llega
    literal y la resuelve el modelo — que la interpretaba como la carpeta de la propia skill, donde no
    hay `hooks\` ni `runner\` (issues upstream anthropics/claude-code #9354 y #9427). El nombre
    `skill_dir`, introducido en la migración a plugin de la 2.6.0, reforzaba justo la lectura errónea.
  - **Defecto adicional**: 8 comandos pasaban «`skill_dir` (resolved in PASO 0)», pero el bloque
    `PASO 0` se eliminó de `SKILL.md` en esa misma migración (ver entrada 2.6.0) — referencia colgante
    desde entonces. Solo reventaba de forma visible en `rs-instalador` y `rs-editor-build`, los que
    ejecutan `runner\` por ruta literal; los otros 10 agentes fallaban en silencio al leer `references\`.
- **Contrato renombrado `skill_dir` → `plugin_root`** en los 22 ficheros del contrato de invocación
  (9 `commands/*.md` + 13 `agents/*.md`), incluidas las rutas `$skill_dir\references\...`. El nombre
  ahora describe lo que es: la raíz del plugin, no la carpeta de la skill.
- **Regla canónica de resolución** — nueva sección `# Raíz del plugin (plugin_root)` en
  `skills/rs-enterprise-agent/SKILL.md`: partir de la ruta inyectada, si termina en `\skills\<algo>`
  subir dos niveles, **verificar con Glob que contiene `hooks\` y `runner\`**, subir un nivel más hasta
  3 saltos y, si no aparecen, detener y pedir la ruta — nunca inventarla ni asumir una versión del
  caché. Incluye el ⛔ de no usar `${CLAUDE_PLUGIN_ROOT}` como ruta en markdown.
- **Verificación defensiva** en los tres agentes que ejecutan `runner\`/`hooks\` por ruta
  (`rs-instalador`, `rs-editor-build`, `rs-editor-db-modeler`): comprueban el `plugin_root` recibido
  antes de usarlo, en vez de confiar en que el orquestador acierte.
- **Ficheros alineados**: `skills/rs-plugin-dev/SKILL.md` (alcance, fuente canónica y auto-verificación),
  `commands/rs-tarea.md` (lectura de `skills/rs-jira/SKILL.md`), `agents/rs-idiomas-standalone.md`,
  y `docs/plugin-architecture.md` (§3 contrato de invocación + §11.4 nueva inconsistencia conocida).
  No se tocan `plugin.json`, `.mcp.json`, `hooks/README.md` ni `README.md`: ahí la variable sí se expande.

## 2.11.0 — 2026-07-20

- **El pipeline se estaba ejecutando sobre una instalación fantasma pre-plugin.** Síntoma reportado:
  dos desarrollos seguidos sobre `AgendaWeb<Proyecto>.sln` no propusieron plan y fueron directos a
  implementar. Ni `SKILL.md` ni `agents/rs-editor-planner.md` tenían el fallo — los subagentes se
  resolvían contra restos de la instalación manual anterior al plugin.
  - **Diagnóstico** (logs de sesión en `~/.claude/projects/n--SVN-RS-<Proyecto>-trunk/`): la traza
    ejecutó `planner → core → analyzer → validator → tester → build` **en un solo turno**.
    `rs-editor-analyzer` y `rs-editor-bd` se eliminaron en la v2.7.0 y no existen en el caché del
    plugin: solo en `~/.claude/agents/` (7-jul). El planner de esa copia es "Etapa 1", `sonnet`, sin
    tools de BD, y su contrato es `SUMMARY` + `STATUS` — **sin bloque `PLAN` ni `STAGES`**. Sin `PLAN`
    el orquestador no tiene qué presentar en el Gate A (no para), y sin `STAGES` recae en la secuencia
    fija antigua. De ahí "no propone plan y lanza core".
  - **Cuatro superficies obsoletas** encontradas y retiradas a `~/.claude/_backup-preplugin-2026-07-20/`:
    `~/.claude/agents/` (28 ficheros), `~/.claude/commands/` (20), `~/.claude/rs-skill-full/` (server
    MCP + 38 hooks + scripts, 7-jul) y `~/.claude/hooks/rs` + `hooks/scripts` (25/29-jun).
  - **El MCP también servía de la copia**: `~/.claude.json` registraba globalmente `rs-workspace`
    apuntando a `~/.claude/rs-skill-full/mcp/rs-workspace-server.py`; como el server resuelve
    `HOOKS_DIR = __file__/../hooks`, **todas** las tools `mcp__rs-workspace__*` ejecutaban hooks del
    7-jul. Repuntado al árbol fuente. Se repunta y no se elimina porque el nombre `mcp__rs-workspace__*`
    está en el `tools:` de todos los agentes. Corolario: el trabajo del ERD de las v2.9.0/2.10.0 no se
    estaba aplicando (se generaba con la plantilla del 29-jun), lo que además explica por qué el ERD
    desplegado parseaba pese a los errores de sintaxis que corrigió la 2.9.0.
  - **Hooks duplicados**: `~/.claude/settings.json` registraba `skill-trigger.ps1` y `runner.ps1` de
    la copia vendorizada, los mismos dos que ya declara `plugin.json` — corrían por duplicado en cada
    prompt. Registro de usuario eliminado; queda solo el del plugin.
- **Remediación automática para el resto del equipo.** `/plugin marketplace update` solo refresca el
  caché del plugin: no toca `~/.claude/agents`, `~/.claude/commands`, `~/.claude.json` ni
  `~/.claude/settings.json`, así que **la limpieza no llega sola** a quien ejecutara en su día
  `install-hooks.ps1`. Y quedaban atrapados en un círculo: su `~/.claude/commands/rs-env.md` sombrea
  al del plugin, con lo que mandarles ejecutar `/rs-env` corre el comando viejo → agente viejo →
  hook viejo. El único vector que escapa es un hook declarado por el propio `plugin.json`, que se
  ejecuta desde `${CLAUDE_PLUGIN_ROOT}` sin pasar por comandos, agentes ni MCP:
  - **`scripts/cleanup-preplugin.ps1`** (nuevo) — detecta y retira las cuatro superficies, repunta el
    MCP y quita los hooks duplicados. **No borra nada**: mueve a
    `~/.claude/_backup-preplugin-<fecha>/`. Idempotente (marca `~/.claude/.rs-preplugin-cleaned`),
    con `-WhatIf` y `-Quiet`.
  - **Hook `SessionStart`** en `plugin.json` — lo ejecuta con `-Quiet` al arrancar cada sesión: quien
    actualice a esta versión queda limpio en el siguiente arranque, con informe de lo movido y aviso
    de reinicio. Silencioso si no hay nada que limpiar.
  - El registro global `rs-workspace` se **repunta, nunca se elimina** (ver caveat abajo). Destino por
    orden: `$env:RS_SKILL_SRC` → `N:\SVN\...\rs-skill-full` → `C:\Desarrollo\SVN\...` → raíz del
    plugin. Se evita apuntar al caché porque su ruta lleva la versión y se rompería en cada update.
- ⚠️ **Caveat arquitectónico detectado (sin resolver).** Los 27 agentes declaran
  `mcp__rs-workspace__*` en su `tools:`, nombre que **solo existe gracias al registro global** que
  creaba el instalador legacy. El `.mcp.json` del plugin publica el servidor como
  `mcp__plugin_rs-enterprise-agent_rs-workspace__*`, que ningún agente declara. Es decir: una
  instalación **solo-plugin** deja a los 27 agentes sin ninguna tool MCP. Por eso la limpieza repunta
  el registro en vez de quitarlo. Falta decidir el arreglo de fondo (renombrar en los 27 `tools:` o
  replantear el `.mcp.json`).
- **Ficheros PowerShell sin BOM.** `scripts/cleanup-preplugin.ps1` y `hooks/skill-trigger.ps1` se
  guardaban en UTF-8 sin BOM; los hooks se lanzan con `powershell` (5.1), que sin BOM lee el fichero
  como ANSI y rompe los caracteres no ASCII — `skill-trigger.ps1` llevaba tiempo inyectando su
  recordatorio con los acentos corrompidos, y el script nuevo directamente no parseaba. Añadido BOM a
  ambos (el resto de hooks ya lo tenían). Verificado con el parser de Windows PowerShell 5.1.
- **Blindaje para que no pueda repetirse:**
  - `mcp/rs-workspace-server.py` — `ping` devuelve ahora **`version`** (leída del `plugin.json`
    contiguo) y **`server_path`**. `SKILL.md` (`# Auto-verificación`) aborta si `server_path` no
    cuelga del plugin ni del árbol fuente. Es el guardián más barato: `ping` ya se llamaba al inicio
    de cada ejecución y su `hooks_dir` habría delatado esto desde el primer día.
  - `hooks/check-env.ps1` — nuevo check **"Coherencia instalación"** (`/rs-env`): detecta
    `~/.claude/agents/rs-*.md`, `~/.claude/commands/rs-*.md`, `~/.claude/rs-skill-full/`,
    `~/.claude/hooks/rs|scripts`, y verifica a qué ruta apunta el `rs-workspace` de `~/.claude.json`.
    `FAIL` → `overall: BLOQUEANTE`.
  - `SKILL.md` — los subagentes del pipeline se invocan **con prefijo de plugin**
    (`rs-enterprise-agent:rs-editor-*`): un nombre prefijado no lo puede ocupar un fichero suelto de
    `~/.claude/agents/`.
  - `SKILL.md` paso 2 — **fail-fast de contrato**: si la respuesta del planner no contiene bloque
    `STAGES`, detener con "planner devolvió contrato antiguo". Antes degradaba en silencio a "sin plan".
  - `scripts/install-hooks.ps1` — **marcado obsoleto**: es quien creaba las copias. Aborta con
    `exit 2` y remite a `/plugin install` + `/rs-env`; solo continúa con `-Force`.
- **Segundo defecto, independiente — los seguimientos no entraban al pipeline.** El otro desarrollo
  ("FrmCambioPass.aspx da errores de compilación") ejecutó `general-purpose → core`, sin planner: el
  disparador exigía el patrón `<Sln>.sln - <cambio>` y un seguimiento dentro de una sesión abierta no
  lo repite, así que no era "petición de pipeline" ni encajaba en ningún modo directo. Nueva regla en
  `# Modos directos`: **resuelta una solución en la sesión, cualquier petición posterior de cambio de
  código vuelve a entrar por el paso 2** (Planner + Gate A) aunque no repita el `.sln`; los modos
  directos y las consultas de solo lectura mantienen prioridad.
- `agents/rs-editor-db-modeler.md` — "Mostrar ERD" deja de invocar
  `$env:USERPROFILE\.claude\hooks\rs\render-erd.ps1` y usa `<skill_dir>\hooks\render-erd.ps1`.
- ⚠️ **Pendiente de revisar**: `executions/history.json` del workspace no tiene entradas desde el
  29-jun pese a que el paso 5 es "Log SIEMPRE" — `/rs-historial` y `/rs-stats` están ciegos para ese
  periodo. Probablemente mismo origen (el `log_execution` de la copia vieja); verificar tras reiniciar.

## 2.10.0 — 2026-07-20

- **Toolbar del ERD reorganizada en menús por función.** La barra acumulaba **26 controles en una
  fila** con `overflow-x:auto`: en cualquier pantalla por debajo de ~2000px la mitad quedaba fuera y
  había que hacer scroll horizontal para llegar a acciones cotidianas, sin distinguir lo diario
  (buscar, filtrar, encuadrar, guardar) de lo esporádico (importar DDL, exportar CSV, stats).
  - **Visible en barra**: título · selector de subvista · buscador · `Filtro ▾` · chip de filtro
    activo · `Fit view` · `PKs` · `Guardar` · los 4 menús · `?` · contadores. De 26 a 17 elementos.
  - **`Vista ▾`** — Auto layout, Gestor de subvistas, Nueva vista desde selección, Relaciones…,
    Presentación. **`Modelo ▾`** — Tabla +, Sugerir FKs, Validar, Stats. **`Exportar ▾`** — SQL
    Oracle/Server, SVG, PNG, los 4 CSV y las 2 fichas. **`Importar ▾`** — Abrir modelo…, Import DDL,
    Import Índices.
  - **Chip de filtro activo**: al filtrar por patrón o desmarcar confianzas de relación aparece
    junto al buscador un chip `Patrón: AG* · Relaciones: 3 de 4` con una ✕ que limpia todo
    (`clearAllFilters()`). Sustituye al aviso anterior —el botón se teñía de azul—, que se habría
    perdido al mover el control dentro de un menú.
  - **Un solo mecanismo de menú**: `toggleMenu(btn, popupId, align)` + `closeMenu()` +
    `runFromMenu(fn)` reemplazan las tres funciones casi idénticas que había
    (`togglePatternFilterPopup`, `toggleRelFilterPopup`, `toggleExportCSVPopup`). Aporta lo que
    antes no había: abrir un menú **cierra el anterior** (podían quedar dos abiertos), cierre con
    **Esc**, y clamp contra el borde derecho de la ventana. El rect del botón se toma **antes** de
    cerrar, porque "Relaciones…" vive dentro del menú Vista y si no quedaría un rect a cero.
  - **CSS**: los estilos inline repetidos de los tres popups pasan a las clases `.menu-popup` /
    `.menu-item` / `.menu-label` / `.menu-sep`, más `.tb-sep` y `#filter-chip`. `max-width:340px` en
    `.menu-popup` corrige de paso que el popup de confianza de relaciones se estirase a **1011px**
    (no tenía tope y sus textos largos no envolvían).
  - **Responsive**: por debajo de 1150px se ocultan los contadores y se recortan título, buscador y
    selector — primero se sacrifica información, nunca controles. Verificado sin scroll horizontal a
    1100px y 1280px con el modelo real de 379 tablas.
  - `agents/rs-editor-db-modeler.md` y `README.md` actualizados: "Abrir modelo…" ahora está en
    `Importar ▾`.

## 2.9.0 — 2026-07-20

- **El ERD HTML ya no caduca: carga el modelo JSON en caliente.** Hasta ahora
  `BD\<proyecto>-erd.html` era un snapshot — `render-erd.py` incrustaba el modelo serializado en la
  plantilla, así que cualquier cambio en `BD\<proyecto>-model.json` (`sync_from_db`, `analyze_dalc`,
  `sync_indexes`, edición manual) obligaba a regenerar el HTML o se miraba un ERD obsoleto sin aviso.
  `fetch()` sobre `file://` está bloqueado por CORS, pero la File System Access API sí funciona ahí:
  - **`scripts/erd-template.html`**: nuevo botón **"Abrir modelo…"** (`openModelFile()`) que usa
    `showOpenFilePicker` con fallback a `<input type="file">` + `FileReader`; `applyLoadedModel()`
    valida el JSON (tolerante a BOM, como `utf-8-sig` en el render), reemplaza `MODEL` y
    re-renderiza. El modelo embebido se mantiene como arranque por defecto (regresión cero).
  - `init()` se parte en `init()` (cableado de eventos, una vez) + **`renderModel()`** (todo lo que
    depende de `MODEL`, re-entrante: limpia cajas, `positions`, `_elCache`, selección y undo/redo).
  - **`resizeCanvas(n)`** calcula lienzo y modo compacto en cliente con la misma fórmula que tenía
    `render-erd.py`, de modo que el HTML se adapta al modelo que se le cargue.
  - El placeholder `{proyecto}` deja de estar hardcodeado en ~20 sitios (título, `LS_KEY`, nombres de
    export CSV/SVG/PNG/DDL/validación): pasa a la variable `PRJ`, que se recalcula del nombre del
    fichero abierto. Un mismo HTML sirve ya para cualquier proyecto.
  - **`saveModel()`** reutiliza el handle de "Abrir modelo…" (pidiendo permiso `readwrite`) y escribe
    **sobre el fichero real** — se acabó el "descárgalo y cópialo a mano al workspace", que queda
    solo como fallback para navegadores sin la API.
  - **`scripts/render-erd.py`**: dejan de inyectarse `{canvas_w}`/`{canvas_h}`/`{compact_js}` (los
    calcula el cliente); se conservan `{proyecto}`, `{model_json}`, `{render_ts}`, `{table_count}`,
    `{rel_count}`.
  - **`agents/rs-editor-db-modeler.md`**: la sección "Mostrar ERD" indica que, si el HTML ya existe y
    solo cambió el modelo, se usa "Abrir modelo…" en vez de regenerar.
- **Fix: la plantilla del ERD tenía dos errores de sintaxis que dejaban muerto el `<script>` entero.**
  Detectados con `node --check` sobre el HTML generado; afectaban a código añadido después del último
  ERD desplegado (el desplegado del 14-jul sí parseaba), o sea que cualquier ERD regenerado desde el
  repo habría salido en blanco:
  - `validateModel()` — `errs.map(i=>{...i,type:'error'})`: arrow devolviendo object literal sin
    paréntesis, que JS lee como bloque con rest parameter → `SyntaxError`.
  - `parseDDL()` / importador de índices / `ensureOracleChar` auxiliares — literales de regex con los
    backslashes duplicados (`/CREATE\\s+TABLE.../`), que además de romper el parseo (`\\(` abría un
    grupo sin cerrar) hacían no funcionales *Import DDL* e *Import Índices*.
  - **Escapes dobles en cadenas** (mismo origen, defecto que arrastraba también el ERD desplegado):
    ~20 literales usaban `'\\n'` y `'\\u2713'` donde se quería `'\n'` y `'✓'`. Efecto real: el DDL
    generado (`SQL Oracle`/`SQL Server`), los CSV de columnas/relaciones/índices/tablas/ficha, el SVG
    exportado y el informe de validación salían **en una sola línea con `\n` literal**, y los iconos
    de estado se imprimían como `✓`/`✕`/`⚠`. Corregidos a saltos reales y a los
    caracteres UTF-8 (`✓ ✕ ⚠ ¿`). Se respetan los dos usos donde el backslash doble **sí** era
    intencionado: el escapado de metacaracteres en el filtro por patrón y el separador de rutas
    Windows en el toast de descarga.

## 2.8.0 — 2026-07-20

- **Nuevo modo directo `/rs-instalador`** — genera el **instalador completo de cliente** (instalación
  limpia del producto en el servidor destino) en `C:\AIS\<Proyecto>\Instalador\`:
  - `EXES\` — procesos batch **activos del cliente** compilados en Release. La lista de procesos
    activos se lee de un nuevo JSON de config por cliente `docs\<Proyecto>-instalador.json` (campo
    `batch`); si el JSON no existe, el agente lo crea preguntando qué soluciones/módulos añadir; si
    existe, lo muestra y pregunta si añadir alguno más antes de compilar.
  - `AgendaWeb\` — publicación FileSystem (msbuild) de la Agenda Web, forzando el destino a la carpeta
    del instalador (no usa el `<PublishUrl>` del `.pubxml`, que apunta al AIS en vivo).
  - `ServiceManager\` — `dotnet publish` (net8) del host `AIS.ServicesManager`, con `Modulos\`
    conteniendo solo las DLL de los **módulos activos** del cliente (deduplicadas contra el host).
  - `Scripts\` — `<Proyecto>-CreacionTablas.sql` (DDL de todas las tablas **sin schema** en tabla/PK/
    índices) e `Inserts\<TABLA>.sql` (un fichero por **tabla paramétrica**). La clasificación
    paramétrica se toma del `BD\<Proyecto>-model.json` → clave raíz `subviews` (vista `"Parametricas"`
    por defecto, configurable) — el model.json del agente, **no** Oracle Data Modeler.
  - **Ficheros nuevos**: `agents/rs-instalador.md` (Opus, orquestador), `commands/rs-instalador.md`,
    fila en `# Modos directos` de `skills/rs-enterprise-agent/SKILL.md`; hooks
    `hooks/installer-batch.ps1`, `hooks/installer-agendaweb.ps1`, `hooks/installer-servicemanager.ps1`,
    `hooks/installer-scripts.ps1` (patrón runner, sin tool MCP, como `batch-build`/`online-publish`);
    scripts `scripts/installer-ddl.py` (DDL sin schema, reutiliza la lógica de tipos de
    `generate-sql.py`) y `scripts/installer-inserts.py` (inserts por tabla, detección de NULL fiable
    vía CASE-wrap, conexión leída de `XMLConfig.xml` igual que `db_query`).
  - **Limitaciones conocidas** (documentadas): `installer-inserts.py` asume que los valores de las
    tablas paramétricas no contienen el delimitador `|@#@|` ni saltos de línea (filas así se omiten
    con AVISO); la etapa Scripts termina con exit 2 (AVISO, no FAIL) si alguna tabla da error de BD.

## 2.7.2 — 2026-07-17

- **Fix: `rs-editor-core` leía ficheros `.sql` de `BD\` como fuente de datos.** La prohibición ya
  existía, pero estaba **fragmentada y enterrada** como sub-bullets condicionales (línea de "orden de
  consulta" bajo el caso `ORA-00942`, y sección "Scripts SQL generados"), y la sección era
  **schema-céntrica** ("tipos/columnas") — no cubría de forma prominente el caso de **datos/valores
  de fila** (RIDIOMA/RCONTROLES/config/seed), que es donde falló. Correcciones:
  - **`agents/rs-editor-core.md`**: nueva **regla marco** al inicio de la sección BD ("Fuente de
    datos y esquema"), única, prominente e incondicional: esquema → modelo (`model.json`); datos →
    `db_query` directo; ⛔ nunca `.sql` de `BD\`. Los sub-bullets antiguos ahora **remiten** a ella
    en vez de repetirla parcialmente.
  - **`references/bd.md`**: sección "Fuente de datos" al inicio (donde `rs-editor-core.md` ya apunta),
    mismo patrón que el cableado de la regla CHAR en 2.7.1.
  - **`agents/rs-editor-planner.md`**: el plan tampoco puede instruir a core a *leer* un `.sql` de
    `BD\` como fuente (antes solo se prohibía nombrar rutas de escritura).
- **Fix: versión desincronizada entre manifiestos.** `plugin.json` estaba en `2.7.1` pero
  `marketplace.json` seguía en `2.7.0`. Como Claude Code detecta la actualización por la versión de
  `marketplace.json`, los cambios no se propagaban. Ambos quedan sincronizados en `2.7.2`.
- **Mejora: `rs-editor-core` gana un Procedimiento (orden obligatorio).** El agente estaba organizado
  por temas (15 secciones sueltas), sin flujo ordenado — el único `-editor` sin espina dorsal (a
  diferencia de validator "Paso 1/2" y fixer "Estrategia 1-5"), y con gates críticos enterrados
  ("leer docs ANTES de emitir código", CHECKLIST compuerta). Se añade una sección numerada de 10
  pasos (validación → scope → docs → localizar → esquema/datos → implementar → SQL → GATE CHECKLIST →
  señales de salida → Output), cada paso remitiendo a su sección de detalle, y se eleva la CHECKLIST
  a sub-encabezado `### GATE`. Evita que el agente se líe o salte pasos. Contrato de Output intacto.

## 2.7.1 — 2026-07-17

- **Fix: DDL Oracle emite `VARCHAR2(n CHAR)` en todo el pipeline.** Un script SQL generado por el
  pipeline salió con `VARCHAR2(20)` sin `CHAR`. En Oracle, sin `CHAR` la longitud es en bytes y
  trunca strings multibyte (UTF-8). El `model.json` guarda el tipo sin `CHAR` por diseño; el `CHAR`
  se inyecta al emitir el DDL. Causa raíz en dos frentes, corregidos ambos:
  - **Agentes que redactan DDL a mano sin la regla en contexto** (origen del bug): se cablea la regla
    CHAR + `references/bd.md` en `agents/rs-editor-core.md` (sección "Scripts SQL generados") y en
    `agents/rs-editor-db-modeler.md` (fallback de DDL a mano). Antes solo estaba en planner/migracion/validacion-bd.
  - **Generador `generate_migration`** (`hooks/generate-migration.ps1`): nuevo helper idempotente
    `Ensure-OracleChar` aplicado en la rama ORACLE de `Get-ColDef` (cubre CREATE/ADD/MODIFY); la rama
    SQL Server ahora quita `CHAR` (`VARCHAR2(n CHAR)` → `VARCHAR(n)`).
  - **Editor ERD** (`scripts/erd-template.html`): helper `ensureOracleChar` en las ramas ORACLE de
    `ddlAddColumn`/`ddlModifyColumn`/`ddlCreateTable`, `generateTableSQL` y el export DDL completo;
    aplicado solo con motor ORACLE para no ensuciar tipos SQL Server.
  - Ya correctos, sin cambios: `scripts/generate-sql.py` (`ensure_oracle_char_semantics`), `assets/erd-widget.html`.

## 2.7.0 — 2026-07-17

Release mayor de la arquitectura del pipeline y de la documentación (sube directo desde 2.5.3; la 2.6.0 intermedia no llegó a publicarse). Tres frentes: rediseño del pipeline, modos de análisis standalone y gestión de documentación.

- **Rediseño del pipeline: planner como cerebro + pipeline delgado dirigido por `STAGES`.** El
  pipeline estaba sobrecargado (11 pasos, hasta 9 subagentes, 3 condicionales dispersos por el
  orquestador, doble fuente de verdad en el planner) y fallaba de forma intermitente en los saltos
  entre etapas. Motivación: centralizar toda la decisión en un planner con datos reales y que el
  resto de agentes solo **apliquen** el plan aprobado por el humano.
  - **`rs-editor-planner` es ahora el cerebro** (`agents/rs-editor-planner.md`): sube a **opus** y
    gana tools MCP de lectura (`search_model`, `get_model_index`, `get_table_schema`, `get_db_config`,
    `db_query`, `find_symbol`, `batch_find_symbols`, `search_code`) — antes planificaba a ciegas con
    solo `Read/Grep/Glob`. Con `get_db_config`+`db_query` el planner es un **superconjunto estricto**
    del antiguo `rs-editor-bd` (mismo toolset BD, más contexto de código, y **antes** de escribir): la
    fusión no pierde profundidad de validación BD. `db_query` restringido a SELECT (no DDL/DML). Analiza símbolos y modelo BD reales, y emite un **contrato único**: bloque
    `PLAN` (para el gate humano) + `STAGES` (lista ordenada y autoritativa de etapas) + `CONTEXT` +
    `STATUS`. Se derogan los flags sueltos `CREATE_TESTS`/`UPDATE_DOCS` (eran doble fuente de verdad):
    todo se lee de `STAGES`.
  - **Pipeline dirigido por `STAGES`** (`skills/rs-enterprise-agent/SKILL.md`, `commands/rs-enterprise-agent.md`):
    el orquestador recorre la lista del planner y ejecuta cada token **sin re-decidir** qué etapas
    corren. Se eliminan los condicionales dispersos del orquestador. Única corrección empírica: red de
    seguridad que ejecuta `db-modeler` si core devuelve `TABLES_TOUCHED` aunque el planner no lo pusiera.
  - **Menos subagentes** (de 9 a 6 en el pipeline): **eliminado `rs-editor-bd`** (la validación de
    tipos/longitudes/compatibilidad de motor la hace el planner en la fase de análisis) y **fusionado
    `rs-editor-analyzer` dentro de `rs-editor-validator`** (el validator ahora compila + análisis
    estático + revisión lógica, con `search_code`/`security_scan` añadidos).
  - **SKILL.md adelgazado** (~175 → ~135 líneas): los gates 2b (aprobación) y 10b (checklist) + Log se
    extraen a la nueva **`references/gates.md`**; el gate de aprobación se enuncia una vez (antes
    repetido 4×) y baja la densidad de marcadores ⛔.
  - **Modos VCS unificados**: `rs-diff-svn`+`rs-diff-git` → **`rs-diff`** y `rs-commit-svn`+`rs-commit-git`
    → **`rs-commit`**, cada uno ramificando internamente según `detect_vcs`. Comandos `/rs-diff` y
    `/rs-commit` actualizados. Total de agentes 28 → 24.
  - Docs sincronizadas: `docs/plugin-architecture.md` (§3/§4/§5/§8), `README.md` (tabla de pipeline),
    design spec (nota de actualización).
- **3 modos directos nuevos para análisis/validación fuera del pipeline.** Al fusionar `bd`/`analyzer`
  en el pipeline quedaron capacidades que solo eran invocables dentro de un run; se exponen ahora como
  modos ad-hoc (patrón §9.1: agente + comando + fila en la tabla de modos), **sin duplicar lógica** —
  comparten la fuente de reglas (`references/bd.md`) con las etapas del pipeline:
  - **`/rs-validar-bd`** (`rs-validacion-bd`, 🔷 sonnet) — valida código C# (DALC/clase/tabla) contra la
    BD real: tipos, longitudes (truncamiento silencioso), nullabilidad y compatibilidad de motor. Es la
    versión standalone de la validación BD que hace el planner.
  - **`/rs-analizar`** (`rs-analisis`, 🔷 sonnet) — análisis estático de calidad/riesgo de un **diff/cambio
    concreto** (reconstruye el delta vía `detect_vcs`; por defecto, cambios pendientes). Versión standalone
    del análisis estático que hace el validator. Complementa a `/rs-audit` (que audita toda la solución).
  - **`/rs-schema`** (`rs-esquema`, ⚡ haiku) — consulta pura del esquema de una o varias tablas
    (columnas/tipos/longitudes/nullabilidad/índices). Cierra el hueco de no tener un modo de esquema sin
    pasar por `/rs-erd` (que genera DDL/ERD).
  - Total de agentes 24 → 27, modos directos 19 → 22. Docs sincronizadas (`SKILL.md` tabla de modos,
    `docs/plugin-architecture.md` §4, `README.md`).
- **Documentación: técnica como input dirigido + actualización garantizada por tipo de doc.** La doc
  técnica de las soluciones RS es un **manual de convenciones** (cómo escribir clases/queries/controles),
  transversal, no un resumen por-solución. Antes core la leía de forma vaga y `tecnica/` no se
  actualizaba nunca. Ahora:
  - **Lectura dirigida:** el planner lee el `tecnica/00_INDICE_MAESTRO.md` (tabla tarea→docs), clasifica
    el cambio y emite `READ_DOCS` — la **lista exacta** de docs técnicos que core debe leer + el
    `CHECKLIST_CONVENCIONES_UI_BD.md` (compuerta antes de emitir `.aspx`/`.cs`). Core lee esos docs por
    sección y pasa la checklist antes de dar por emitido el código. Sube la calidad del código generado.
  - **Manual técnico (solo patrón nuevo, propuesta+confirmación):** core reporta `NEW_PATTERN` si
    introduce algo reutilizable nuevo (control AIS, clase común, convención de query/nomenclatura, tipo
    de tarea). La etapa `documentar` **propone** el cambio al fichero correcto del manual (`02`, `05`,
    `06`...) como `TECNICA_PROPUESTA`; ⛔ nunca escribe en `tecnica/` sin confirmación humana — es la
    referencia compartida de todas las soluciones.
  - **Resumen por-solución persistente:** nueva ruta `docs/agentic_manual/soluciones/<Sln>.md`;
    `/rs-doc` (GenerarDoc) ahora **escribe** ahí (antes solo mostraba); la etapa `documentar` lo refresca
    cuando cambia estructura/tablas/flujo.
  - **Doc funcional:** sigue actualizándose auto (sin confirmación) por la etapa `documentar`.
  - `find_doc_section` (hook + tool) ahora recorre también `tecnica/` (antes solo `funcional/` + raíz),
    necesario para localizar la sección a proponer.
  - Ficheros: `agents/rs-editor-planner.md`, `agents/rs-editor-core.md`, `agents/rs-documentar.md`,
    `hooks/find-doc-section.ps1`, `skills/rs-enterprise-agent/SKILL.md`, `commands/rs-enterprise-agent.md`,
    `references/gates.md` (Gate B), `references/mcp.md`, `references/hooks.md`.

## 2.5.3 — 2026-07-16
- **Guardrail en la Fase 2 de la skill `rs-jira`: encuadrar el requisito, no analizar código**
  (`skills/rs-jira/SKILL.md`). En un run de `/rs-tarea`, la Fase 2 se puso a **analizar el código**
  de la solución (qué columnas, qué nº de catálogo, qué pantalla) para "entender" la issue —
  solapándose con el `rs-editor-planner`, que ya hace ese análisis técnico **dentro** del pipeline
  (gate 2b). La Fase 2 solo debe traducir la issue a un **requisito accionable** (el *qué*); el
  *cómo* es del planner. El propio título de la fase ("**Análisis**, formateo y aclaración") invitaba
  al exceso. Cambios:
  - Fase 2 renombrada a **"Encuadre del requisito (NO análisis técnico)"** + bloque ⛔ que la limita
    a trabajar **solo** con Jira (issue + comentarios) y aclaraciones del usuario: **prohíbe** leer
    el código de la solución, llamar a `get_scope`/`find_symbol`/`search_code` o abrir ficheros
    fuente, y decidir el "cómo". Ambigüedad → **preguntar al usuario**, no explorar el repo.
  - Nueva **regla global** que fija el límite F2 (qué) vs `rs-editor-planner`/gate 2b (cómo), y
    puntos 3-4 reforzados para dejar explícita la frontera entre la aprobación del **requisito**
    (Fase 2) y la del **plan técnico** (gate 2b del pipeline, Fase 3).
  - Sin cambio del contrato de fases ni del resto del flujo. Bump por §10 (`plugin.json` +
    `marketplace.json` idénticos) para que Claude Code re-indexe la skill.

## 2.5.2 — 2026-07-16
- **Bump para forzar el re-indexado del comando `/rs-tarea`.** El comando (`commands/rs-tarea.md`)
  y la skill `rs-jira` existían en la fuente desde 2.4.0 y estaban correctos, pero `/rs-tarea` no
  aparecía como slash command en la sesión: el plugin está instalado como marketplace **tipo
  directorio** con `autoUpdate: false`, y los fixes de 2.5.0/2.5.1 editaron ficheros **sin cambiar
  el string de versión**, así que Claude Code no re-indexó (los slash commands se registran al
  arrancar / al cambiar la versión, no se hot-reload). Sin cambio funcional — solo bump de versión
  (`plugin.json` + `marketplace.json` idénticos, §10) para disparar `/plugin marketplace update`.

## 2.5.1 — 2026-07-16
- **Fix real del cuelgue de `/rs-tarea` (skill `rs-jira`).** El fix de 2.5.0 solo cambió el **texto de
  diagnóstico** ("si `ping` cuelga → sospechar EDR"), pero el modelo seguía **llamando a
  `mcp__rs-workspace__ping` como primera acción** de la auto-verificación. Bajo CrowdStrike el proceso
  `python.exe` del MCP queda bloqueado y `ping` no responde hasta el timeout de 1800s → congela el turno
  entero. Un cuelgue de tool call bloqueante **no es "detectable"** por el modelo (solo espera), así que
  la instrucción de 2.5.0 era inalcanzable. Ahora la auto-verificación (`skills/rs-jira/SKILL.md`):
  - ⛔ **No llama a `ping` (ni a ninguna tool `rs-workspace`) en el arranque** — solo comprueba
    **presencia del nombre en el registro** deferred (instantáneo, no cuelga).
  - **Prioriza Atlassian Rovo**, que es la dependencia real de las Fases 1–3 (selección/formateo/
    transición); `rs-workspace` solo interviene en la **Fase 4** (`jira_attach`/`log_execution`), donde
    se difiere su verificación viva.
  - **Fase 4**: nota de riesgo — si `jira_attach`/`log_execution` no responde en segundos → MCP
    bloqueado por el EDR; commit y transiciones ya están hechos, se reporta cierre **parcial** en vez de
    colgar.
- **Reconciliado el drift de versión de `marketplace.json`** (estaba en `2.2.0` mientras `plugin.json`
  iba por `2.5.0`). Ambos manifests quedan idénticos en `2.5.1`, como exige §10 del
  `plugin-architecture.md`.

## 2.5.0 — 2026-07-16
- **Endurecida la auto-verificación de la skill `rs-jira`** (`skills/rs-jira/SKILL.md`). El primer run
  falló declarando "MCP Atlassian Rovo ausente" cuando en realidad las tools estaban *deferred* en la
  sesión (solo el nombre visible, schema sin cargar). Ahora la Fase 0:
  - Carga el schema de las tools con **ToolSearch** antes de llamarlas (`select:...`), y explicita que
    *deferred ≠ ausente* — un `InputValidationError` por llamar directo no implica MCP inexistente.
  - Distingue los modos de fallo de `ping`: **cuelga/timeout** → proceso MCP bloqueado por el EDR
    (CrowdStrike FP, ver `docs/crowdstrike-fp-justification.md`), NO "reinstalar"; **nombre inexistente
    en el registro** → server no configurado.
  - Para Atlassian Rovo, decide por **presencia del nombre `...Atlassian_Rovo__*` en el registro**
    (deferred incluido): presente → conectado, cargar schema y confirmar auth con `atlassianUserInfo`;
    ausente del registro → integración no conectada; auth error → falta login Rovo interactivo.

## 2.4.0 — 2026-07-16
- **Seguridad: `runner/runner.ps1` deja de usar `Invoke-Expression`.** Ejecutaba un `COMMAND:`
  extraído del output del LLM (transcript) vía IEX, filtrado solo por substring `hooksRoot` + una
  denylist corta — no frenaba comandos añadidos (`.\hooks\x.ps1; <payload>`) → **inyección de
  comandos**. Ahora separa ruta del script + argumentos, valida que el `.ps1` resuelto queda dentro
  de `hooks/` (`GetFullPath` + `StartsWith`, bloquea `..\` escape), existe y es `.ps1`, tokeniza los
  argumentos respetando comillas y ejecuta con `& $script @argList` — todo lo que va tras el `.ps1`
  viaja como **argumento literal**, nunca como PowerShell (sin `;`/`|`/`&&`). Denylist conservada
  como defensa en profundidad.
- **Falso positivo de CrowdStrike documentado** — nuevo `docs/crowdstrike-fp-justification.md` para
  entregar a IT/Seguridad. CrowdStrike (EDR conductual) marcó "virus" al ejecutar `ping` del MCP
  `rs-workspace` y bloqueó el proceso `python.exe` → `ping` colgó → la skill `rs-jira` abortó. Es FP
  sobre código propio (spawn de `powershell -ExecutionPolicy Bypass`, `Add-Type System.Net.Http` en
  `jira-attach.ps1`, spawns svn/git/dotnet); sin descarga de red de código, sin `-EncodedCommand`,
  sin `FromBase64String`, sin reflection/shellcode. El doc incluye exclusión mínima recomendada
  (proceso python MCP + dir del plugin) y la petición del detalle de detección a IT.
- **Nota rs-jira**: el síntoma "MCP Atlassian Rovo ausente" del run fallido era falso — las tools
  Jira están registradas como *deferred* en la sesión; hay que cargar su schema con ToolSearch antes
  de declararlas ausentes. (Endurecer la precondición de la skill queda como mejora futura.)

## 2.3.0 — 2026-07-16
- **Fix gate de aprobación del plan que no detenía el pipeline.** El gate `Plan approval` existía en
  disco pero se había añadido **sin subir la versión** → Claude Code no recarga un plugin salvo que
  cambie la versión, así que las sesiones activas seguían cargando el cuerpo del command **anterior
  al gate** y encadenaban `rs-editor-core` sin presentar el plan. **Lección:** todo cambio en el
  contenido del pipeline (`commands/`, `skills/`) requiere bump de versión, es lo único que fuerza la
  recarga.
- **Reconciliada la numeración command↔SKILL** (`commands/rs-enterprise-agent.md`). Los dos ficheros
  divergían: en el command `2b` era *Scope* mientras que en `SKILL.md` `2b` era *Aprobación* — esa
  colisión hacía que el orquestador tratara "2b" como scope y se deslizara sobre la aprobación. Ahora
  ambos usan el mismo esquema canónico (igual que `docs/plugin-architecture.md`):
  `1 validate → 1b scope → 2 planner → 2b ⛔ aprobación → 4 core`, con scope resuelto **antes** del
  Planner (que lo recibe en su header).
- **Gate `2b` endurecido** en command y SKILL.md: primera línea `⛔⛔ PARADA OBLIGATORIA — NO invocar
  rs-editor-core en este turno`, imposible de confundir con un paso de preparación.

## 2.2.0 — 2026-07-16
- **Integración Jira: nueva skill `rs-jira` + comando `/rs-tarea`** (`skills/rs-jira/SKILL.md`,
  `commands/rs-tarea.md`). Orquesta el ciclo de vida de una tarea de Jira sobre una solución
  uCollect/RS: F1 selección (búsqueda JQL de tareas asignadas abiertas, o KEY/URL manual) · F2
  formateo del requisito al prompt del pipeline `<Sln>.sln - <cambio>` (⛔ el `.sln` **siempre se
  pregunta**, nunca se infiere) · F3 transición a "En Proceso" + lanzamiento del pipeline
  `rs-enterprise-agent` · F4 commit (`/rs-commit`) + adjuntar `.sql` + transición a "En Validación"
  + `log_execution` con la KEY de Jira para trazar issue↔ejecución en `/rs-historial`. **Cambio
  100% aditivo**: no toca el pipeline ni ningún `rs-editor-*`/`/rs-commit` — los envuelve. Diseño:
  Jira (búsqueda/lectura/transición/comentario) se opera con el **MCP Atlassian Rovo ya conectado**,
  sin cliente ni credenciales propias; los estados **no se hardcodean** (se resuelven con
  `getTransitionsForJiraIssue` + `statusMap` de config, robusto a idioma/workflow); toda escritura
  en Jira va detrás de un gate ⛔ de confirmación explícita.
- **Nuevo hook + tool MCP para adjuntar ficheros a Jira** (`hooks/jira-attach.ps1`,
  `jira_attach(issue_key, files)` en `mcp/rs-workspace-server.py` — **39 → 40 tools**). El MCP Rovo
  no expone attachment, así que el adjunto real se hace vía Jira Cloud REST v3
  (`POST /rest/api/3/issue/{KEY}/attachments`, `X-Atlassian-Token: no-check`, multipart con
  `HttpClient` compatible con Windows PowerShell 5.1). Credenciales en
  `~/.claude/rs-jira-credentials.json` (**fuera del repo**, nunca en `.jira-dev-config.json`); ⛔ el
  token nunca se escribe en stdout/stderr. Convención Preferente/Fallback 1:1 (tool ↔ hook) como el
  resto.
- **Config y documentación** — `docs\.jira-dev-config.json` (en la carpeta `docs\` del workspace,
  junto a `XMLConfig.xml`; no-secreto: `projectKey`, `jiraUser`, `cloudId?`, `statusMap`,
  `openStatuses?`; scaffolding con `/rs-tarea init`) y nueva
  reference `references/jira.md` (setup config + credenciales + tabla de herramientas). Sincronizado:
  `README.md` (comando, setup Jira, nº tools), `references/mcp.md`, `references/hooks.md`,
  `hooks/README.md`, `docs/plugin-architecture.md`. Límite documentado: el MCP Rovo usa auth
  interactiva → la skill no corre en headless/cron.

## 2.1.2 — 2026-07-16
- **el Planner siempre genera un PLAN legible, y el orquestador siempre lo presenta y detiene el turno — Plan Mode del harness OFF incluido**. Motivo: con el Plan Mode del harness OFF, en el pipeline `<Sln>.sln - <cambio>` el modelo podía saltarse la presentación del plan y encadenar Core directo. La intención ya estaba escrita (`SKILL.md` gate 2b: "con independencia del Plan Mode del harness") pero (1) la redacción no era lo bastante imperativa y (2) el Planner solo emitía una lista de pasos + el bloque de contrato para máquina (`FILES_CHANGED/CREATE_TESTS/UPDATE_DOCS/SUMMARY/STATUS`), sin un artefacto `PLAN` legible garantizado que presentar. Doble corrección: (1) `agents/rs-editor-planner.md` (sección Output) — nuevo bloque `PLAN` legible por humano (Objetivo · Pasos · Despliega a AIS · Genera tests · Impacto en datos/BD) que el Planner emite **SIEMPRE**, justo antes del bloque de contrato, con o sin Plan Mode. (2) `skills/rs-enterprise-agent/SKILL.md` — paso 2 con regla imperativa (⛔ el Planner se ejecuta SIEMPRE y su bloque `PLAN` es obligatorio, no se salta aunque Plan Mode esté OFF; nunca se llega a Core sin `PLAN`), paso 2b endurecido (con Plan Mode OFF el orquestador presenta el `PLAN` del Planner y detiene el turno igualmente, nunca encadena Core en el mismo turno sin aprobación; presentar el bloque ya emitido, no reconstruirlo) y Regla Global (línea 22) alineada. Sin cambios en las etapas de escritura ni en el contrato de salida (el bloque `PLAN` es un campo extra del Planner, ya cubierto por "+ campos extra documentados en cada `rs-editor-*.md`" de `docs/plugin-architecture.md`); `README.md` sin cambios (la tabla de pasos ya marca "planner | Siempre").

## 2.1.1 — 2026-07-15
- **fix incongruencia de ruta de scripts SQL (planner inventaba `BD\scripts\`)** — `agents/rs-editor-planner.md` no mencionaba ninguna ruta de destino para los `.sql`, así que el planner (modelo `sonnet`) rellenaba el hueco inventando una ruta, y en una ejecución eligió `BD\scripts\` del repo — justo la ubicación que el fix de v1.6.0 (ver entrada 1.6.0) documentó como bug ("una sesión dejó el script solo en `BD\` del repo y dio el paso por completado"). `rs-editor-core` tenía la regla correcta (`.sql` → `C:\AIS\<proyecto>\scripts\`, prohibido `BD\`) pero dejaba que la ruta nombrada por el plan la sobrescribiera. No era una convención doble: la única ruta válida para cualquier `.sql` (DDL/migración/seed/idiomas) es `C:\AIS\<proyecto-lowercase>\scripts\` (`rs-editor-core.md`, `rs-editor-db-modeler.md`, `rs-editor-tester.md`, `SKILL.md`). Doble corrección: (1) `rs-editor-planner.md` (sección Reglas) — regla explícita de que el plan **nunca** especifica dónde se guarda un `.sql`; solo indica qué script hace falta, ⛔ nunca nombrar `BD\scripts\` ni carpeta del repo. (2) `rs-editor-core.md` (sección Scripts SQL) — regla de **precedencia**: si el plan nombra otra ruta para un `.sql`, ignorarla; `C:\AIS\<proyecto>\scripts\` prevalece siempre. Sin cambios de comportamiento en ejecución de DDL/DML: los agentes siguen sin ejecutar scripts en BD (los ejecuta el usuario/DBA antes de desplegar); solo se corrige la ruta de escritura del fichero.

## 2.1.0 — 2026-07-14
- **`docs/plugin-architecture.md` (nuevo)**: doc canónico de la anatomía interna del plugin y del patrón para extenderlo — anatomía de directorios, manifests y qué se auto-descubre por convención, resumen del pipeline y sus contratos de invocación/salida, familias de agentes (`rs-editor-*` vs `rs-*`), patrón de comandos, MCP server (39 tools sobre hooks vía `_run_ps`), hooks infra vs worker, references, **cómo extender** (modo directo de 3 ficheros, etapa de pipeline, tool MCP, skill) y **puntos de sincronización de documentación** (checklist de coherencia). Documenta también 3 inconsistencias conocidas (referencias a `subagents/` vs `agents/` real; carpeta `BD/` del README que no vive en el repo; `settings.json` legacy). Complementa —no duplica— `README.md` (uso), `references/*.md` (dominio) y el design spec del pipeline.
- **Skill `rs-plugin-dev` (nueva)** — `skills/rs-plugin-dev/SKILL.md` + `commands/rs-plugin-dev.md`: meta-skill de mantenimiento del propio plugin (no de soluciones cliente). Lee `docs/plugin-architecture.md` como fuente canónica, clasifica el cambio, planifica, **se detiene en un gate de aprobación explícita antes de escribir**, aplica siguiendo las convenciones (agentes/comandos/references/SKILL/MCP Python/hooks PowerShell/manifests), **sube la versión de forma obligatoria** en `plugin.json` + `marketplace.json` idénticas —requisito para que Claude Code detecte la actualización—, y sincroniza `CHANGELOG`/`README`/tabla de modos/references con una verificación de coherencia final. Alcance de edición: toda la superficie del plugin, incluido MCP y hooks.
- **`.claude-plugin/marketplace.json`**: se añade `version` a la entrada del plugin, para que quede idéntica a `plugin.json` (la meta-skill mantiene ambas sincronizadas en cada cambio).

## 2.0.3 — 2026-07-14
- **fix `validate_solution`: falso error en soluciones válidas** — `hooks/validate-solution.ps1` no escribía nada en stdout en la ruta de éxito (solo `Write-Host "Solution not found"` + `exit 1` en la ruta de fallo, y en la válida ni output ni `exit`). `_run_ps` en `mcp/rs-workspace-server.py` trata stdout vacío como fallo, así que una `.sln` **válida** devolvía `{"error":"No output from validate-solution.ps1","exit_code":0}` y una inexistente devolvía `{"raw":"Solution not found"}` — la tool estaba efectivamente invertida y nunca daba un éxito limpio. Ahora el script emite JSON en ambas rutas (`@{...} | ConvertTo-Json` + `exit` explícito, misma convención que `detect-vcs.ps1`): válida → `{"success":true,"sln_path":...,"solution":...}` exit 0; inexistente → `{"success":false,"error":"Solution not found",...}` exit 1. Sin cambios en `rs-workspace-server.py` (el script se lee vía `subprocess` en cada llamada; no requiere reinicio del MCP server).

## 2.0.1 — 2026-07-09
- **Reducción de consumo de tokens en el pipeline principal**:
  - `rs-editor-build.md`/`rs-editor-analyzer.md`: `model: sonnet` → `haiku` — build es mecánico (lee resultado de `validate_solution` y reporta), analyzer es puramente advisory y no bloquea el flujo; ninguno de los dos necesita un tier más caro.
  - **Doble resolución de solución/scope corregida**: `SKILL.md` invocaba Planner en el paso 1 y resolvía `validate_solution`/`get_scope` después, en los pasos 2/2b — pero `rs-editor-planner.md` decía recibirlos ya resueltos y a la vez los volvía a llamar como paso propio "AnalyzeSolution", duplicando ambas tools en cada ejecución. Reordenado: solución+scope se resuelven primero (pasos 1/1b), Planner pasa a ser el paso 2 y los recibe ya resueltos en el header — se quitó "AnalyzeSolution" de `rs-editor-planner.md` y las tools `validate_solution`/`get_scope` de su frontmatter.
  - **Analyzer (paso 6) ahora condicional**: antes corría siempre aunque `rs-editor-planner.md` ya listaba "AnalyzeChanges" como paso opcional dentro de su propio plan; el orquestador lo ignoraba y lo invocaba de todas formas. Ahora solo se invoca si el plan del Planner lo incluyó (cambio no trivial). Riesgo bajo: Analyzer es advisory, Validator sigue siendo el único gate bloqueante.
  - **Tool `Bash` sin uso quitada** de `rs-editor-core.md` y `rs-editor-tester.md` — no aparecía referenciada en ningún paso del cuerpo de ninguno de los dos (a diferencia de `rs-editor-build.md`/`rs-editor-db-modeler.md`, donde sí hay uso real documentado). Menos overhead de definición de tools por invocación.
  - **Texto de troubleshooting `MSB4019` centralizado**: estaba duplicado casi literal en `rs-editor-build.md` y `rs-editor-tester.md`; ahora vive una sola vez en `references/troubleshooting.md`, ambos agentes solo lo referencian.

## 2.0.0 — 2026-07-08
- **Conversión a plugin de Claude Code (cambio de mecanismo de distribución)**: se retiran los DOS mecanismos anteriores — el paquete `.skill` para Claude Desktop (`rs-skill-full.skill`, `scripts/build-skill.ps1`, marker `agents/.skill-root`, bloque "PASO 0" de `SKILL.md` que buscaba ese marker bajo `%APPDATA%\Claude\local-agent-mode-sessions\...`) y los instaladores PowerShell a mano para Claude Code CLI (`scripts/install-hooks.ps1`/`install-to-project.ps1`, que copiaban `commands/`/`subagents/` a `~/.claude/` y editaban `~/.claude/settings.json`/`~/.claude.json` directamente). Motivo: en la sesión que llevó a v1.9.2/1.9.3 los instaladores a mano fallaron tres veces distintas (comando base inexistente, `~/.claude/agents/` nunca poblado, crash en PowerShell 5.1) — síntomas de mantener a mano algo que Claude Code ya resuelve nativamente.
- **`.claude-plugin/marketplace.json` + `.claude-plugin/plugin.json` (nuevos)**: manifiesto de plugin de un solo componente (`source: "./"`, mismo patrón que el plugin `caveman`). `plugin.json` declara los hooks `Stop` (runner de builds) y `UserPromptSubmit` (`skill-trigger.ps1`) inline, usando `${CLAUDE_PLUGIN_ROOT}` — sin tocar `~/.claude/settings.json`.
- **`.mcp.json` (nuevo)**: registra el MCP server `rs-workspace` (mismo `command`/`env` que tenía la entrada manual en `~/.claude.json`) apuntando a `${CLAUDE_PLUGIN_ROOT}/mcp/rs-workspace-server.py` — sin cambios en el propio `mcp/rs-workspace-server.py` (su resolución de rutas ya era relativa a sí mismo).
- **`SKILL.md` → `skills/rs-enterprise-agent/SKILL.md`**: bloque "PASO 0" eliminado por completo; las ~12 referencias a `$SKILL_DIR` pasan a `${CLAUDE_PLUGIN_ROOT}` (inyectado directo por Claude Code, sin bucle de reintentos buscando un marker).
- **`subagents/` → `agents/`** (renombrado, `svn move` preserva historial): la carpeta `agents/` ya no aparece en la convención de plugin como el marker suelto de Desktop — ahora contiene los 28 subagentes reales, descubiertos automáticamente por Claude Code.
- Instalación ahora es `/plugin marketplace add "N:\SVN\RS\Agentes\SkillsClaude\rs-skill-full"` + `/plugin install rs-enterprise-agent@rs-enterprise-agent`, en vez de instalar un `.skill` y correr un script PowerShell aparte. Ver `README.md`.

## 1.9.3 — 2026-07-08
- **`rs-editor-tester.md`: fix gate idiomas** — el gate solo disparaba para controles nuevos o cambios de `ICCONTROL` (rebind/rename); un texto (`LabelText`/`Text`/mensaje de validación/`Idm.Texto`) editado en un control YA EXISTENTE, sin tocar su clave, pasaba desapercibido y el Tester reportaba OK sin generar script. Caso real: cambiar el literal "Contrato" → "Contrato externo" en un label existente de `FrmBusqueda.aspx`. Regla ahora explícita: dispara el gate cualquier texto visible por el usuario que cambie, sea alta o edición. Nueva rama de acción — texto editado con clave igual: `UPDATE RIDIOMA` si el IDTEXTO es exclusivo de ese control, o alta de IDTEXTO nuevo + reasignar `RCONTROLES` si el IDTEXTO está compartido con otros controles (evita romper el texto de esos otros).

## 1.9.2 — 2026-07-08
- **fix crítico**: el nombre base `rs-enterprise-agent` nunca tuvo un archivo en `commands/` — solo existían los wrappers de modo directo (`rs-audit.md`, `rs-diff.md`, etc). El hook `skill-trigger.ps1` instruye a invocar "la skill `rs-enterprise-agent` (tool Skill)" para el patrón `<Sln>.sln - <cambio>` (pipeline completo), pero esa invocación fallaba siempre con `Unknown skill: rs-enterprise-agent` porque Claude Code CLI resuelve nombres de skill contra archivos en `commands/`/`agents/` instalados, no contra el `SKILL.md` de un paquete `.skill` de Claude Desktop (ese sí queda registrado bajo `%APPDATA%\Claude\local-agent-mode-sessions\...`, un registro completamente distinto e invisible para el CLI).
- **`commands/rs-enterprise-agent.md` (nuevo)**: entry point del pipeline completo, mismo patrón que los demás comandos (autocontenido, sin depender de resolver `$SKILL_DIR` en runtime) — reproduce "PIPELINE OBLIGATORIO" de `SKILL.md` para que el orquestador (main thread) lo seguido directamente al invocarse por nombre o por el hook.
- Recordatorio: tras instalar, correr `scripts/install-hooks.ps1` (o `install-to-project.ps1` para scope de proyecto) y reiniciar Claude Code — sin esto el comando nuevo no aparece y, si `~/.claude/agents/` nunca se pobló (instalación previa a la v1.7.0), ningún modo que despache a subagente Task-tool funciona.
- **`install-hooks.ps1`: fix compat PS 5.1** — el paso 3 (registrar MCP `rs-workspace` en `~/.claude.json`) usaba `ConvertFrom-Json -AsHashtable`, parámetro inexistente en Windows PowerShell 5.1 (el `powershell.exe` que de hecho ejecuta hooks/instalador en runtime — `pwsh` 7 no es lo que corre ahí). El fallback a `ConvertFrom-Json` plano tampoco sirve: este `.claude.json` en particular tiene una clave con nombre de propiedad vacío en otra sección que hace que hasta el parseo plano falle. Ahora usa `ConvertTo-HashtableDeep` (mismo helper que ya tenía `install-to-project.ps1`) y, si el parseo completo falla igual, atrapa el error y avisa sin tocar el archivo — nunca arriesga reserializar `~/.claude.json` completo a ciegas.

## 1.9.1 — 2026-07-07
- **build.md / tester.md / references/hooks.md**: fix — en <Proyecto>, `dotnet build`/`dotnet test`/`compile_check`/`run_tests` fallaban con `MSB4019` (falta `Microsoft.WebApplication.targets`) en cuanto el build tocaba un proyecto Online WebForms, incluso solo por `ProjectReference` desde un proyecto de test; `compile-check.ps1` solo parsea `CS####` así que el `MSB####` real quedaba invisible (`error_count=0` con `exit_code=1`, falso positivo). Documentado: compilar con `msbuild.exe` real (vswhere) y ejecutar tests con `vstest.console.exe` sobre el `.dll` compilado.
- **build.md / references/hooks.md**: fix — asumir `FolderProfile1` como nombre de perfil de publish causó fallo; el nombre real varía por proyecto (en <Proyecto> era `FolderProfile`, sin el "1"). Ahora obligatorio listar los `.pubxml` reales y leer `<PublishUrl>` antes de invocar `online-publish.ps1`.

## 1.9.0 — 2026-07-07
- **Soporte Git en paralelo a SVN (nuevo)**: pronto habrá proyectos RS en Git además de SVN — ambos deben seguir funcionando. Nueva tool `mcp__rs-workspace__detect_vcs(workspace)` (hook `detect-vcs.ps1`) detecta SVN/Git subiendo por las carpetas; nunca se asume uno u otro.
- **5 tools Git nuevas**, espejo 1:1 de las SVN existentes: `git_status` (`git-status.ps1`), `git_log` (`git-log.ps1`), `git_diff_revision` (`git-diff-revision.ps1`), `git_add` (`git-add.ps1`, fallback TortoiseGitProc), `_check_git_cli()`. `ping()` y `check_env`/`check-env.ps1` reportan también `git_cli`/fila "Git" (no bloqueante, igual que SVN)
- **2 subagentes nuevos**: `rs-diff-git` (Haiku, espejo de `rs-diff-svn`) y `rs-commit-git` (Sonnet, espejo de `rs-commit-svn` — con una diferencia importante: `git commit` es local, así que hace **commit + push con dos confirmaciones separadas**, no una)
- **`rs-historial` y `rs-validar-req`**: rama condicional vía `detect_vcs` para usar `git_log`/`git_diff_revision` en vez de sus pares SVN cuando el workspace es Git
- **`commands/rs-commit.md`, `commands/rs-diff.md`**: llaman `detect_vcs` antes de despachar, y eligen el subagente `-svn` o `-git` según corresponda
- **Convención de carpetas sin cambios**: los repos Git nuevos mantienen la misma estructura `trunk\Batch\Soluciones\*.sln` / `trunk\OnLine\Soluciones\*.sln` que SVN — `get-config.ps1`/`parse-sln.ps1` no se tocan
- **SKILL.md**: nueva sección "Detección de VCS", tabla "Modos directos" generaliza filas Diff/Commit

## 1.8.0 — 2026-07-07
- **Subagentes Sonnet/Opus (nuevo)**: 11 modos directos más despachan vía Task tool a subagentes reales — `rs-comparar-modelo` (Haiku), `rs-auditoria`/`rs-impacto`/`rs-generar-dalc`/`rs-documentar`/`rs-commit-svn`/`rs-crear-tests` (Sonnet), `rs-migracion-motor`/`rs-idiomas-standalone`/`rs-validar-req`/`rs-seguridad` (Opus). Modelo elegido por lo que exige la tarea (juicio real, escritura de código/SQL de producción, gate de seguridad/cumplimiento), no por el modelo activo del chat.
- **Dual-rol preservado**: `documentar.md`, `crear-tests.md` e `idiomas-standalone.md` se mantienen en `agents/` (sin cambios funcionales) para su uso embebido en el pipeline (pasos 8/8b/8c), que necesita continuidad de contexto con la tarea en curso — solo se aisló la invocación directa (`/rs-doc` GenerarDoc, `/rs-crear-tests`, `/rs-idiomas`). `db-modeler.md` (ERD/Modelo BD) queda igual, por el mismo motivo.
- **Pipeline principal y ERD/Modelo BD**: sin cambios — etapas encadenadas que comparten contexto implícito, aislarlas en subagente arriesgaría perder ese estado
- **SKILL.md** "Modos directos": tabla con marcas ⚡ Haiku / 🔷 Sonnet / 🟣 Opus por modo
- **agents/**: eliminados `auditoria.md`, `impacto.md`, `comparar-modelo.md`, `generar-dalc.md`, `migracion-motor.md`, `commit-svn.md`, `validar-requerimiento.md`, `seguridad.md` — contenido migrado a `subagents/`

## 1.7.0 — 2026-07-07
- **Subagentes Haiku (nuevo)**: `/rs-historial`, `/rs-diff`, `/rs-estructura`, `/rs-stats`, `/rs-env`, `/rs-deps` — 6 modos directos de solo-lectura/mecánicos — ahora despachan vía Task tool a subagentes reales (`subagents/rs-*.md`, frontmatter `model: haiku`) en vez de ejecutarse inline en el modelo activo del chat. Reduce costo sin afectar pipeline principal ni modos que requieren razonamiento (auditoría, impacto, seguridad, migración, etc.)
- **install-hooks.ps1**: vendoriza `subagents/*.md` → `~/.claude/agents/` (mismo patrón que `commands/` → `~/.claude/commands/`); requiere reinstalar + reiniciar Claude Code para que el Task tool descubra los subagentes
- **agents/**: eliminados `historial.md`, `diff-svn.md`, `estructura.md`, `stats.md`, `validar-entorno.md`, `dependencias.md` — contenido migrado a `subagents/` (ya no se leen inline)
- **SKILL.md** "Modos directos": marcadas con ⚡ las 6 filas que ahora despachan a subagente Haiku

## 1.6.0 — 2026-07-07
- **db-modeler.md / core.md**: DDL escrito a mano para tablas nuevas (cuando `generate_sql`/`generate_migration` no emiten el CREATE TABLE esperado) sigue requiriendo copia obligatoria a `C:\AIS\<proyecto>\scripts\` — fix: una sesión dejó el script solo en `BD\` del repo y dio el paso por completado
- **core.md** "Modelo BD — orden de consulta": prohibido el polling en bucle de vistas catálogo Oracle (`ALL_TABLES`/`ALL_OBJECTS`/`ALL_TAB_COLUMNS`/`USER_TABLES`) para confirmar existencia de tabla — máx 1 intento, luego SELECT directo a la tabla; `sync_model_tables`/`get_table_schema` siguen siendo autoritativos
- **references/troubleshooting.md**: nueva entrada "Tabla nueva no aparece en ALL_TABLES/ALL_OBJECTS (Oracle)" documentando el lag de dictionary cache; nueva regla clave anti-repetición de consultas ya respondidas
- **validator.md**: aclarado que `compile_check` (paso 1) es solo el gate del validator, no sustituye el paso 9 Build
- **SKILL.md**: nuevo paso **10b Checklist final** (obligatorio antes de Log) — verifica Build real ejecutado + copia AIS, scripts SQL copiados a AIS, y esquema BD consultado vía model.json — fix: una sesión reportó éxito tras `compile_check` sin ejecutar nunca el Build real ni la copia de binarios a AIS

## 1.5.0 — 2026-07-06
- **hooks/skill-trigger.ps1** (nuevo): hook UserPromptSubmit — detecta `.sln` en el prompt dentro de workspaces `\SVN\RS\` e inyecta recordatorio de invocar la skill (fix: Claude no siempre disparaba la skill con el patrón "Solucion.sln - cambio")
- **install-hooks.ps1**: registra automáticamente el UserPromptSubmit hook (idempotente); fix doble escape de backslashes en el Stop hook; fix lectura de `~/.claude.json` (`-AsHashtable`, `-Depth 100`, escritura solo si cambia)
- **SKILL.md description**: ampliada para mejorar el disparo (cualquier mención de .sln/solución RS, no solo el patrón exacto); `version` movida a `metadata:` (requisito del validador de empaquetado)
- **Deduplicación**: reglas globales (scope, warning model.json 180K, límite fixer, Preferente/Fallback) viven solo en SKILL.md; agentes recortados (~1.200 tokens menos por invocación de pipeline)
- **Convención global Preferente/Fallback** en SKILL.md — agentes solo detallan fallback cuando no es 1:1
- **Gate scripts-idiomas unificado**: core.md es la fuente única; tester.md y SKILL.md (paso 8b) lo referencian — cubre rebinds de grid en `.aspx.cs` que la condición ".aspx tocado" perdía
- **MCP**: eliminada tool redundante `get_bd_model` (cubierta por get_model_index/search_model/get_table_schema); quitados warnings obsoletos sobre `db_query`
- **idiomas-standalone.md**: reglas migradas de memoria — mensajes de error solo RIDIOMA (sin RCONTROLES), IDTEXTO nunca por huecos de coerr.cs, casing ICFORM
- **build.md**: verificación post-build obligatoria con evidencia mínima
- **references/hooks.md**: añadidos search-code, db-query, get-bd-model, sync-indexes y sección Build; **references/mcp.md**: firma real de compile_check, fila sync_indexes
- **hooks/sync-model-tables.ps1**: portada versión corregida desde copia instalada (fix colisión `$Tables`, manejo JSON-objeto)
- **Limpieza**: eliminado `hooks/config.json` (sin referencias); README documenta desarrollo del skill (fuente canónica, reempaquetado, reinstalación)

## 1.3.0 — 2026-06-26
- **compare-model.ps1**: detecta drift de tipo y nullable en columnas existentes (`modified_columns`)
- **generate-migration.ps1**: genera ALTER TABLE MODIFY (tipo/nullable), ADD CONSTRAINT FK, CREATE INDEX, DROP COLUMN comentado
- **db-modeler.md**: corregido comentario incorrecto sobre `render_erd` MCP
- **MCP**: descripciones actualizadas para `compare_model` y `generate_migration`
- **ERD viewer**: modal DDL en cada mutación de esquema (add/drop columna, rename, PK toggle, create/drop tabla)
- **ERD viewer**: modo presentación (P), panel atajos (?), DDL filtra tablas visibles
- **ERD viewer**: búsqueda columnas, filtro patrón, lock tabla, rubber band selection
- **ERD viewer**: export CSV (catálogo, relaciones, índices, resumen, ficha técnica)
- **sync-indexes.ps1** + MCP `sync_indexes`: sincronización de índices desde Oracle
- **generate-migration.ps1**: CREATE INDEX para tablas nuevas
- **Todos los slash commands**: `description:` en frontmatter YAML para tooltips

## 1.2.0
- ERD viewer: export SVG, PNG
- sync-model-tables.ps1: fix bug índices borrados en sync parcial
- generate-sql.py: soporte índices
- bd.md: validación [perf] para índices

## 1.1.0
- MCP server inicial
- Hooks: sync-from-db, compare-model, generate-migration, analyze-dalc
- ERD viewer: base con drag/zoom, relaciones, subvistas, undo/redo

## 1.0.0
- Release inicial
