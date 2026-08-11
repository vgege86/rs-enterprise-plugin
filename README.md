# RS Enterprise Agent — Guía de usuario

Plugin de Claude Code para desarrollo C# en soluciones **uCollect / RS**. Combina dos cosas:

1. Un **pipeline de desarrollo automatizado** (planificación → análisis → validación → testing → build) que implementa un cambio de principio a fin con aprobación humana del plan.
2. **46 modos directos** (slash commands `/rs-*` y lenguaje natural) para tareas puntuales: auditar, analizar un diff, medir impacto, validar código contra la BD, ver esquema, gestionar el modelo BD/ERD, generar tests, hacer commits SVN o Git, documentar, revisar seguridad, proteger datos personales en consultas, generar el instalador de cliente o un actualizador de entorno, y más.

Todo respeta el **scope de la .sln activa**, la arquitectura por capas uCollect y las convenciones RS.

> Versión actual: **3.11.0** — ver `CHANGELOG.md` para el detalle por versión.

---

## Índice

- [Instalación](#instalación)
- [Cómo se usa (activación)](#cómo-se-usa-activación)
- [Leyenda de modelos](#leyenda-de-modelos)
- [El pipeline de desarrollo](#el-pipeline-de-desarrollo)
- [Catálogo de comandos](#catálogo-de-comandos)
  - [1. Pipeline principal](#1-pipeline-principal)
  - [2. Análisis y calidad de código](#2-análisis-y-calidad-de-código)
  - [3. Refactor y correcciones (escriben código)](#3-refactor-y-correcciones-escriben-código)
  - [4. Base de datos y modelo](#4-base-de-datos-y-modelo)
  - [5. Rendimiento y validación BD](#5-rendimiento-y-validación-bd)
  - [6. Testing](#6-testing)
  - [7. Control de versiones (SVN o Git)](#7-control-de-versiones-svn-o-git)
  - [8. Documentación e idiomas](#8-documentación-e-idiomas)
  - [9. Comprensión y onboarding](#9-comprensión-y-onboarding)
  - [10. Entorno, estadísticas y dashboard](#10-entorno-estadísticas-y-dashboard)
  - [11. Entregas a cliente: instalador y actualizador](#11-entregas-a-cliente-instalador-y-actualizador)
  - [12. Tareas (Jira / Mantis)](#12-tareas-jira--mantis)
  - [13. Mantis](#13-mantis)
  - [14. Errores de producción → tareas](#14-errores-de-producción--tareas)
- [Protección de datos personales en consultas a BD](#protección-de-datos-personales-en-consultas-a-bd)
- [Qué hay por debajo (MCP, hooks, modelo BD)](#qué-hay-por-debajo)
- [Reglas clave](#reglas-clave)
- [Requisitos y resolución de problemas](#requisitos-y-resolución-de-problemas)
- [Para mantenedores del plugin](#para-mantenedores-del-plugin)

---

## Instalación

**1. Dependencia Python del MCP server** (en una terminal, *antes* de instalar el plugin):

```bash
pip install "mcp>=1.2.0,<2"
```

Nadie la instala por ti: el plugin no ejecuta ningún `pip`. Sin ella el servidor MCP `rs-workspace`
no arranca y las tools no responden.

> ⛔ El tope `<2` no es cosmético: `mcp` 2.0.0 **eliminó** `mcp.server.fastmcp`, que es justo lo que
> importa el servidor. Un `pip install mcp` a secas arrastra 2.x y rompe el arranque.
>
> ⛔ Tiene que quedar en **el mismo Python que resuelve `python` en el PATH** — `.mcp.json` invoca
> literalmente `python`. Con varios Python o un venv de por medio, comprobar con
> `python -c "import mcp; print(mcp.__file__)"`.

**2. El plugin**, publicado como marketplace Git:

```
/plugin marketplace add https://github.com/vgege86/rs-enterprise-plugin.git
/plugin install rs-enterprise-agent@rs-enterprise-agent
```

El repo es **privado**: hace falta credencial de GitHub en la máquina (`gh auth login` o Git Credential Manager) para que Claude Code pueda clonarlo.

Claude Code descubre automáticamente `commands/`, `agents/`, los skills, los hooks (SessionStart/Stop/UserPromptSubmit) y el MCP server `rs-workspace` — no hay que copiar nada a mano ni editar `~/.claude/settings.json`.

Claude Code clona el marketplace en `~/.claude/plugins/marketplaces/` y ejecuta el plugin desde su copia cacheada por usuario: **el plugin es portable y no depende de ninguna ruta compartida**.

**Tras instalar: reiniciar Claude Code.** Después, `/rs-env` para validar la máquina y `/rs-help`
como prueba de que el MCP responde (si el paso 1 falló, se nota ahí).

Para actualizar tras una versión nueva:

```
/plugin marketplace update rs-enterprise-agent
```

…y reiniciar.

**Requisitos** (detalle abajo): Python 3.11+ **con el paquete `mcp`**, .NET SDK, PowerShell 7+, Visual Studio con MSBuild, y el CLI de SVN **o** Git según el proyecto.

### El marketplace publica dos plugins

Desde la 3.11.0 el mismo marketplace ofrece, además del agente C#, el plugin **`rs-validador`** —
desarrollo, mantenimiento y documentación de la herramienta de validación de ficheros
(Python/FastAPI + HTML/JS): estructuras de entrada, validación de lo que manda el cliente y
generación de los scripts SQL de configuración de uCollect.

```
/plugin install rs-validador@rs-enterprise-agent
```

Son independientes: se instalan, se versionan y se actualizan por separado. `rs-enterprise-agent`
trabaja sobre `.sln` de uCollect/RS; `rs-validador` no toca ninguna solución C#. Su guía está en
`plugins/rs-validador/README.md`.

> 💡 **Menos tokens por sesión (ya automático)**: Claude Code **difiere por defecto** los schemas de
> las tools MCP de `rs-workspace` — solo se cargan bajo demanda vía tool-search cuando una tarea las
> usa, ahorrando su coste fijo (~6k tokens/sesión) **sin configurar nada**. ⚠️ **No** pongas
> `ENABLE_TOOL_SEARCH`: el valor `auto` carga los schemas *upfront* (cuando caben en el 10% del
> contexto) y `false` los carga todos — ambos **deshacen** el ahorro. Dejar la variable **sin poner**
> (el default) es lo óptimo. Ver la doc de Claude Code sobre la ventana de contexto.

---

## Cómo se usa (activación)

Tres vías, todas equivalentes en potencia:

**1. Pipeline completo** — mensaje con el patrón `solución + cambio`:

```
RSProcIN.sln - añadir validación de fecha en cabecera
AgendaWeb.sln - modificar lógica de pedidos
```

**2. Slash commands** — `/rs-*` (catálogo completo abajo):

> ⛔ **Todos van con el prefijo del plugin**: `/rs-enterprise-agent:rs-audit`, no `/rs-audit`.
> Claude Code namespacea **siempre** lo que aporta un plugin, para que dos plugins puedan traer un
> comando con el mismo nombre sin pisarse. El prefijo es el campo `name` de
> `.claude-plugin/plugin.json`.
>
> En la práctica no hace falta teclearlo entero: escribe `/rs-audit`, el selector lo encuentra por
> coincidencia parcial y lo completa. Lo que **no** funciona es enviar `/rs-audit` literal, sin
> pasar por el selector.
>
> Por eso el pipeline principal se invoca `/rs-enterprise-agent:rs-enterprise-agent`: el plugin y el
> skill del pipeline se llaman igual, así que el nombre sale repetido. No es una errata.
>
> ⚠️ Las tablas del catálogo omiten el prefijo por legibilidad. Añádelo mentalmente a todas.

```
/rs-audit AgendaWeb.sln
/rs-impacto RCLIENTES en RSProcIN.sln
```

**3. Lenguaje natural** — cualquier mención de una `.sln` o solución RS dispara el plugin:

```
audita AgendaWeb.sln
muéstrame el ERD
qué usa RCLIENTES
faltan índices en RSProcIN
```

> Dentro de una sesión, una vez resuelta la solución, **toda petición posterior de cambio de código** vuelve a entrar por el planner con aprobación de plan — aunque no repitas el `.sln - `. Las consultas de solo lectura siguen siendo directas.

---

## Leyenda de modelos

Cada modo elige el modelo según lo que exige la tarea. Aparece junto a cada comando del catálogo:

| Icono | Modelo | Se usa para |
|-------|--------|-------------|
| ⚡ | **Haiku** | Lectura pura / mecánico (esquema, diff, stats) |
| 🔷 | **Sonnet** | Juicio autocontenido / advisory (auditoría, impacto, cobertura) |
| 🟣 | **Opus** | Escribe código/SQL de producción, o gate de seguridad/cumplimiento |

---

## El pipeline de desarrollo

El **planner es el cerebro**: analiza el cambio con acceso al modelo BD y al código, emite el bloque `PLAN` (que un humano **debe aprobar**) y la lista autoritativa de etapas `STAGES`. El orquestador **ejecuta `STAGES` en orden sin re-decidir** — el resto de agentes solo aplican el plan.

```
resolver .sln → scope → planner → [APROBACIÓN HUMANA] → STAGES → checklist → log
   STAGES ⊆ { core, plan-check, validator, tester, build, db-modeler, documentar }
```

| Etapa | Cuándo se ejecuta |
|-------|-------------------|
| Validación `.sln` + Scope | Siempre (orquestador) |
| **planner** 🟣 | Siempre — analiza, valida contra BD y decide STAGES |
| **Aprobación humana** | Siempre — gate bloqueante, no toca código sin tu OK |
| `core` 🟣 | Siempre — implementa el cambio |
| `plan-check` 🔷 | Tras core, **solo en cambios complejos** (≥3 ítems, ≥2 proyectos, esquema BD o funcionalidad nueva) — verifica que el código cubre **todos** los ítems del PLAN |
| `validator` 🔷 | Siempre — compila + análisis estático + revisión lógica |
| `fixer` 🟣 | Si el validator falla (máx 2 ciclos) |
| `tester` 🔷 | Si hay lógica testeable, o es Online y toca controles/idiomas |
| `crear-tests` 🔷 | Auto si el tester detecta código nuevo sin cobertura |
| scripts idiomas | Solo Online — controles/`Idm.Texto`/rebinds nuevos |
| `build` ⚡ | Tras modificar código, con verificación de evidencia real |
| `db-modeler` 🟣 | Si añade/modifica tablas o DALCs |
| `documentar` 🔷 | Si el cambio cumple los criterios de documentación |
| checklist + log | Siempre — verificación + registro en `history.json` |

> La validación de tipos/longitudes/motor BD la hace el **planner** en la fase de análisis. Validator y Tester son **bloqueantes**: el build no se ejecuta si fallan.

---

## Catálogo de comandos

46 modos directos. El argumento `<Solution>.sln` casi siempre puede sustituirse por lenguaje natural equivalente.

> El catálogo de abajo lista 50 comandos: los 46 modos directos más el pipeline completo (`/rs-enterprise-agent`, que no es un modo directo) y los tres comandos de gestión de tareas — `/rs-tarea`, router que autodetecta el gestor de tickets del proyecto; `/rs-mantis`, puerta explícita de Mantis; y `/rs-log-errores`, que convierte el log de errores de la web en tareas —, que despachan a los skills `rs-jira`, `rs-mantis` y `rs-log-errores` y no al principal.

> ⛔ **Los nombres de estas tablas van sin el prefijo del plugin, por legibilidad.** El comando real
> es `/rs-enterprise-agent:<nombre>` — ver [Cómo se usa](#cómo-se-usa-activación). Basta con teclear
> el nombre corto y dejar que el selector lo complete.

### 1. Pipeline principal

| Comando | Qué hace |
|---------|----------|
| `/rs-enterprise-agent <Solution>.sln - <cambio>` 🟣 | Lanza el pipeline completo de desarrollo. Ej: `/rs-enterprise-agent RSProcIN.sln - añadir validación de fecha` |

---

### 2. Análisis y calidad de código

Solo lectura, no modifican nada. Sirven para entender riesgo antes de tocar.

| Comando | Qué hace |
|---------|----------|
| `/rs-audit <Solution>.sln` 🔷 | Auditoría estática de calidad (naming, estructura, lógica, seguridad) de **toda** la solución. |
| `/rs-analizar <Solution>.sln [rev\|ficheros]` 🔷 | Análisis de calidad/riesgo de **un diff concreto** (el delta, no toda la solución). Por defecto, cambios pendientes. |
| `/rs-review <Solution>.sln [--rev <r>] [--pr <n> [owner/repo]]` 🟣 | Revisión de un cambio con **veredicto de bloqueo** `APRUEBA / CAMBIOS / BLOQUEA` (riesgo + seguridad + BD sobre el delta). Opcional: publica en un PR de GitHub. |
| `/rs-impacto <clase\|método\|tabla> en <Solution>.sln` 🔷 | Mapa de todas las referencias a un símbolo, con clasificación de riesgo. Ej: `/rs-impacto RCLIENTES en RSProcIN.sln` |
| `/rs-dead-code <Solution>.sln` 🔷 | Inverso de impacto: símbolos sin referencias. Marca como "no concluyente" puntos de entrada, handlers `.aspx`, reflexión/DI. Advisory, no borra. |
| `/rs-hotspots <Solution>.sln` 🔷 | Puntos calientes de riesgo cruzando frecuencia de cambios (churn VCS) con complejidad. Ranking para priorizar tests/refactor. |
| `/rs-security <Solution>.sln` 🟣 | Scan de seguridad: SQL injection, credenciales hardcoded, XSS, input sin validar. Findings con severidad y `archivo:línea`. |

---

### 3. Refactor y correcciones (escriben código)

⛔ **Escriben código.** Todos piden **confirmación humana** antes de aplicar cambios.

| Comando | Qué hace |
|---------|----------|
| `/rs-rename <Solution>.sln <viejo> a <nuevo>` 🟣 | Renombrado seguro: localiza todas las referencias y las reescribe. Avisa de referencias cross-solución y colisiones. Ej: `/rs-rename RSProcIN.sln GrabarCobro a RegistrarCobro` |
| `/rs-format <Solution>.sln [fichero]` 🟣 | Auto-fix de convenciones (naming/usings/formato) — el complemento de `/rs-audit`. ⛔ Solo formato, **nunca lógica**; renombrados públicos se derivan a `/rs-rename`. |
| `/rs-migrar <Solution>.sln a <ORACLE\|SQLSERVER>` 🟣 | Adapta DALCs y SQL entre SQL Server ↔ Oracle. Alto impacto: reescribe SQL en todo el scope. |
| `/rs-generar-dalc <Tabla> en <Solution>.sln` 🔷 | Genera clases DALC completas desde el modelo BD. Ej: `/rs-generar-dalc RCLIENTES en RSProcIN.sln` |

---

### 4. Base de datos y modelo

| Comando | Qué hace |
|---------|----------|
| `/rs-schema <tabla\|keyword>` ⚡ | Esquema real de una o varias tablas: columnas, tipos, longitudes, nullabilidad, índices. Consulta pura. Ej: `/rs-schema RCLIENTES` |
| `/rs-erd [workspace]` 🟣 | Gestión del **modelo BD**: actualiza desde BD real, visualiza ERD interactivo (drag/zoom, edición de descripciones, export SQL/CSV/SVG/PNG), genera DDL, exporta a Oracle Data Modeler. |
| `/rs-comparar-modelo [workspace]` ⚡ | Drift entre `BD/<proyecto>-model.json` y el esquema real. Ofrece generar scripts de migración y sincronizar. |
| `/rs-comparar-entornos [id1] [id2] [tablas]` 🔷 | Diff de esquema entre **dos conexiones** de `.rs-databases.json` (ej. dev vs pro): tablas/columnas/tipos/longitudes/índices divergentes. ⛔ Solo SELECT. Ej: `/rs-comparar-entornos dev pro` |
| `/rs-sync-indexes [workspace]` ⚡ | Sincroniza índices desde la BD real al modelo (solo Oracle). Preserva índices `source=manual`. |
| `/rs-seed <Solution>.sln <tabla> [N]` 🔷 | Genera INSERTs sintéticos de prueba respetando tipo/longitud/nullabilidad/FKs/unicidad. Salida a `C:\AIS\<proyecto>\scripts\`. ⛔ No ejecuta contra la BD. Ej: `/rs-seed RSProcIN.sln RCLIENTES 20` |

---

### 5. Rendimiento y validación BD

| Comando | Qué hace |
|---------|----------|
| `/rs-validar-bd <Solution>.sln <DALC\|clase\|tabla>` 🔷 | Valida código C# contra la BD real: tipos, longitudes (truncamiento silencioso), nullabilidad, compatibilidad de motor. Ej: `/rs-validar-bd RSProcIN.sln CobrosDalc.cs` |
| `/rs-perf <Solution>.sln [DALC\|tabla]` 🟣 | Rendimiento de acceso a BD: cruza el SQL de los DALC contra los índices del modelo → índices que faltan, full-scans, filtros no-sargables (`UPPER(col)=`, `LIKE '%x'`), `SELECT *` en tablas anchas. |

---

### 6. Testing

| Comando | Qué hace |
|---------|----------|
| `/rs-test <Solution>.sln` ⚡ | Ejecuta `dotnet test` y reporta passed/failed/skipped (leídos del `.trx`, no del texto de consola: así el conteo no depende del idioma del CLI). Sin lanzar el pipeline. Si no hay proyecto de test, deriva a `/rs-crear-tests`. Si el resultado no se puede leer o no corre ninguna prueba, lo dice — no lo presenta como verde. |
| `/rs-crear-tests <Solution>.sln` 🔷 | Crea proyecto de test (xUnit/MSTest/NUnit) si no existe + genera tests unitarios para las clases públicas. |
| `/rs-cobertura <Solution>.sln` 🔷 | Mapa de cobertura: qué clases/métodos públicos (DALC/BUS primero) **no** tienen test. Advisory. |

---

### 7. Control de versiones (SVN o Git)

> `detect_vcs` decide automáticamente SVN o Git según el workspace — nunca hay que indicarlo. Sin el CLI correspondiente, degradan a instrucciones manuales vía TortoiseSVN/TortoiseGit.

| Comando | Qué hace |
|---------|----------|
| `/rs-diff [Solution.sln]` ⚡ | Cambios pendientes de commit, agrupados por solución/proyecto. |
| `/rs-commit <Solution>.sln` 🔷 | Filtro de scope + diff + mensaje de commit sugerido. **Confirmación explícita** antes de ejecutar. En Git, `commit` y `push` se confirman por separado. |
| `/rs-deshacer <Solution>.sln` 🔷 | Revierte los cambios **pendientes** del último cambio del pipeline a su estado versionado. ⛔ Gate de confirmación. No toca commits ya hechos ni la BD. |
| `/rs-historial [Solution.sln] [N]` ⚡ | Historial de ejecuciones del pipeline y commits. Ej: `/rs-historial RSProcIN.sln 5` |
| `/rs-validar-req "<req>" --rev <r> [--sln <S>] [--session]` 🟣 | Valida si los commits implementan lo requerido. Detecta tests faltantes. `--rev` = revisión SVN o hash Git (coma para varios); `--session` incluye el transcript de la sesión. |
| `/rs-release-notes [Solution] [N] [--desde YYYY-MM-DD]` 🔷 | Convierte el historial de commits en notas de versión funcionales agrupadas (✨ nuevo · 🐛 correcciones · 🗄️ BD · ⚙️ interno), en lenguaje de negocio/QA. |

---

### 8. Documentación e idiomas

| Comando | Qué hace |
|---------|----------|
| `/rs-doc <Solution>.sln` 🔷 | Genera y **persiste** el resumen por-solución (propósito, estructura, tablas, flujo, config) en `docs/agentic_manual/soluciones/`. |
| `/rs-doc-drift <Solution>.sln [--rev <r>]` 🔷 | Cruza los cambios recientes contra la doc funcional y marca secciones obsoletas / incompletas / sin doc. Advisory, no reescribe. |
| `/rs-runbook <Solution>.sln <proceso>` 🔷 | Runbook operativo de un proceso (carga inicial, cierre, reproceso): precondiciones, procedimiento, reglas críticas de esa operación, verificación y errores conocidos. **Te entrevista** — lo que no está en el código lo aportas tú. Persiste en `docs/agentic_manual/funcional/OPERACION/`. Ej: `/rs-runbook RSProcIN.sln carga inicial de históricos` |
| `/rs-idiomas <Solution>.sln` 🟣 | Escanea `.aspx`, busca controles AIS y genera INSERTs para `RIDIOMA`/`RCONTROLES`. **Solo Online.** Salida a `C:\AIS\<proyecto>\scripts\`. |

> **Los idiomas salen de la BD, no de una lista fija**: del catálogo 32 de `RTABL` (`SELECT TBCODE, TBTEXT FROM RTABL WHERE TBNUME = 32`), donde `TBCODE` es el id de idioma. Varían por instalación, así que ni `/rs-idiomas` ni el gate del pipeline dan por hecho `ESP`/`POR`.
>
> **Los IDTEXTO van por rangos según el tipo de texto** — errores (`coerr.eXXXX`) **1000–1999**, mensajes en pantalla (`coMens.mXXXX`) **2000–2999**, textos de pantalla (labels, headers de grid, validadores) **desde 3000** sin techo. Al asignar uno nuevo se **rellenan los huecos** empezando por el suelo del rango, no se continúa desde el máximo. Si un rango se agota, el id se busca a partir de 3000 y el script lo avisa en su cabecera.

> **Documentación en el pipeline.** El manual técnico de convenciones (`docs/agentic_manual/tecnica/`) es **input**: el planner clasifica la tarea y core lee los docs que aplican antes de emitir código. La doc **funcional** y el **resumen por-solución** se actualizan automáticamente tras un cambio; el manual técnico solo se toca por **propuesta que un humano confirma**.

---

### 9. Comprensión y onboarding

| Comando | Qué hace |
|---------|----------|
| `/rs-explicar <Solution>.sln <clase\|método\|proceso>` 🔷 | Explica en lenguaje natural qué hace, su flujo de datos y efectos laterales. Puntual, no persiste. Ej: `/rs-explicar RSProcIN.sln CobrosDalc` |
| `/rs-estructura <Solution>.sln` ⚡ | Mapa de capas, grafo de dependencias, detección de referencias circulares. |
| `/rs-deps [proyecto]` ⚡ | Dependencias entre soluciones: proyectos compartidos, conflictos de versión NuGet. Ej: `/rs-deps RSDalc` |

---

### 10. Entorno, estadísticas y dashboard

| Comando | Qué hace |
|---------|----------|
| `/rs-init` 🔷 | Bootstrap de un workspace nuevo: crea `.rs-databases.json` (o migra `XMLConfig.xml`), el andamiaje de docs y el primer `model.json`. ⛔ Nunca sobrescribe. |
| `/rs-env [workspace]` ⚡ | Valida `.rs-databases.json`, ruta AIS, dotnet, SVN/Git, modelo BD y docs agentic. |
| `/rs-pii [status\|bootstrap\|audit\|enforce\|off]` 🔷 | Protección de datos personales en consultas a BD: estado (`status`), inventario de columnas afectadas (`bootstrap`), y cambio de modo (`audit`/`enforce`/`off`). `enforce` registra las guardas `PreToolUse` en la configuración personal de Claude Code, previa confirmación. Ver `docs/proteccion-pii-consultas-bd.md`. |
| `/rs-stats [solution]` ⚡ | Estadísticas de `history.json`: total ejecuciones, tasa de éxito, top soluciones, agentes más usados, tendencia 7 días. |
| `/rs-dashboard` ⚡ | Dashboard HTML autónomo de `history.json` (KPIs, estados, top soluciones, tendencia), tema claro/oscuro. Versión visual de `/rs-stats`. |
| `/rs-help` ⚡ | Renderiza **esta guía** (README) a un HTML navegable con formato (índice, tablas, tema claro/oscuro) y lo abre en el navegador. Ideal para pasar a usuarios. |
| `/rs-cifrar` ⚡ | Cifra en reposo (DPAPI, cuenta de Windows) los secretos en texto plano: password de BD (`.rs-databases.json`) y tokens Jira/Mantis (`~/.claude`). Idempotente, no imprime secretos, retrocompatible (los valores sin cifrar siguen funcionando). |
| `/rs-word <ficheros\|carpeta>` ⚡ | Convierte documentación Markdown del `agentic_manual` a un **Word `.docx`** sobre la plantilla corporativa `.dotx` del workspace (portada, historial de cambios, índice y estilos de la plantilla). Requiere Microsoft Word instalado. Ej: `/rs-word docs\agentic_manual\funcional\OPERACION` |

---

### 11. Entregas a cliente: instalador y actualizador

| Comando | Qué hace |
|---------|----------|
| `/rs-instalador [<Proyecto>\|<workspace>]` 🟣 | Genera el **instalador completo de cliente** (instalación limpia) en `C:\AIS\<Proyecto>\Instalador\`: `EXES\` (batch en Release), `AgendaWeb\`, `ServiceManager\` + `Modulos\`, `Scripts\` (DDL de tablas + DDL de `RVERSIONES` + `Inserts\` de tablas paramétricas + `PorEntorno\99-RVERSIONES-<ENTORNO>.sql`, la fila base de la instalación) y el **paquete de instalación**: `Instalar.ps1` (backup + copia), `Ejecutar-Scripts.ps1`, `rutas.json` y `readme.txt`. La config por cliente vive en `docs\<Proyecto>-instalador.json`. |
| `/rs-actualizador <DESA\|TEST\|PROD> [<Sln>...] [--hasta AAAA-MM-DD]` 🟣 | Genera el **actualizador incremental** de un entorno en `C:\AIS\<Proyecto>\Actualizador\<ENTORNO>_<AAAAMMDD>\`. Mira en la tabla **`RVERSIONES`** cuándo se entregó por última vez cada solución en ese entorno, calcula el delta de commits (SVN/Git) hasta hoy —o hasta la fecha de `--hasta`, descartando desarrollos posteriores— y empaqueta solo lo afectado: `Exes\`, `AgendaWeb\` (completa), `ServiceManager\Modulos\`, más `scripts\` con los SQL de las tareas Mantis/Jira del rango y el insert de registro. ⛔ La configuración del cliente no viaja (`web.config`, el `<proceso>.xml` de cada batch, `appsettings*.json`): los parámetros nuevos se listan en `readme.txt`. Los `*.config` del binario (`RSProcIN.exe.config`) **sí** van — llevan los binding redirects. |

**Tabla `RVERSIONES`** (una fila por entorno + solución entregada): guarda `FECHA_CORTE` —el punto
de partida del siguiente delta— y una `DESCRIPCION` **funcional, no técnica**, pensada para que el
usuario final pueda llegar a leerla. El actualizador genera el insert para la BD del cliente y otro
para nuestra BD de control; ninguno se ejecuta solo. Detalle: `references/actualizador.md`.

Instalación en el servidor del cliente (ambos paquetes):
1. `Ejecutar-Scripts.ps1 -Entorno <E>` — SQL en orden, fail-fast, con pre-vuelo y confirmación.
   El orden lo fija `scripts.json` si el paquete lo trae; si no, la convención de tres tandas: los
   `.sql` de la carpeta, luego `Inserts\` (paramétricas) y por último la fila base
   `PorEntorno\99-RVERSIONES-<E>.sql`, **solo la del entorno indicado**.
   Conecta con **wallet Oracle / autenticación integrada** o con usuario y contraseña, según
   `bd.autenticacion` de `rutas.json`. La contraseña nunca viaja por la línea de comandos.
   Flags: `-Simular` (conecta y lista, no escribe), `-Recargar` (purga opt-in), `-SinConfirmar`,
   `-Schema`, `-NlsLang`.
2. `Instalar.ps1 -Entorno <E>` — backup ZIP de cada carpeta destino y copia (rutas en `rutas.json`).
3. Parámetros de configuración a mano, según `readme.txt`.

---

### 12. Tareas (Jira / Mantis)

| Comando | Qué hace |
|---------|----------|
| `/rs-tarea [PROJ-123 \| URL \| 1234 \| init]` | **Router**: detecta qué gestor de tickets usa el proyecto y orquesta el ciclo completo de la tarea con el skill que corresponda (`rs-jira` o `rs-mantis`) — selecciona issue → formatea el requisito a `<Sln>.sln - <cambio>` → transiciona a "En Proceso" → **lanza el pipeline** → tras el commit, adjunta los `.sql` y pasa a "En Validación". Capa **opcional y aditiva**. `/rs-tarea init` crea el config del gestor elegido. |

> **Detección**: mira qué config existe en `docs\` del workspace — `.jira-dev-config.json` → Jira, `.mantis-dev-config.json` → Mantis. Si existen **los dos**, desambigua por la forma del argumento (`PROJ-123` → Jira, `1234` → Mantis) y, si no basta, **pregunta**: nunca adivina. Si no existe ninguno, pregunta el gestor y ofrece crear su config. El gestor detectado se anuncia antes de tocar ningún ticket.
>
> **Requisitos (rama Jira)**: MCP **Atlassian Rovo** conectado. Para adjuntar `.sql` hace falta un API token en `~/.claude/rs-jira-credentials.json`. Setup completo → `references/jira.md`. Uso interactivo (no corre en headless/cron). Requisitos de la rama Mantis → sección siguiente.

---

### 13. Mantis

| Comando | Qué hace |
|---------|----------|
| `/rs-mantis [1234 \| crear \| proyectos \| init]` | Puerta **explícita** de Mantis (salta la detección de `/rs-tarea`). Orquesta el ciclo de una issue de MantisBT: selecciona o **crea** issue (siempre **asignada al usuario del token**) → formatea el requisito a `<Sln>.sln - <cambio>` → transiciona a "En Proceso" → **lanza el pipeline** → tras el commit, adjunta los `.sql` y pasa a "En Validación". Capa **opcional y aditiva**. El proyecto **nunca se asume**: si hay más de uno (o ninguno) se listan y se pregunta. `/rs-mantis proyectos` gestiona la lista curada de proyectos; `/rs-mantis init` crea el config. |

> **Requisitos**: MantisBT no tiene MCP — usa el cliente REST autónomo `hooks/mantis-cli.ps1` (token auth, sin depender de `python.exe`). Token en `~/.claude/rs-mantis-credentials.json`; lista curada de proyectos en `docs\.mantis-dev-config.json`. Setup completo → `references/mantis.md`. Auth por token (a diferencia de rs-jira, no depende de OAuth interactivo), pero toda escritura en Mantis se confirma en uso interactivo.
>
> **Nota de rate**: la instancia devuelve HTTP 500 ante `PATCH` rápidos seguidos al mismo issue; `mantis-cli.ps1` intercala ~800ms + retry con backoff en `advance`/`create`/`assign` (ver `references/mantis.md`).

> **Valores por defecto y etiquetas**: los dos configs aceptan un bloque `defaults` con los campos que se aplican a **toda** tarea que cree el plugin — en Jira `issueTypeName`, `priority`, `components`, `labels`, `customfield_*`; en Mantis `category`, `priority`, `severity`, `tags`. Precedencia: **lo que digas tú → `defaults` → réplica de la última tarea** (esta última se apaga con `defaults.replicarUltimaTarea: false`). Las etiquetas no se pisan: se acumulan. Detalle en `references/jira.md` / `references/mantis.md`.

---

### 14. Errores de producción → tareas

| Comando | Qué hace |
|---------|----------|
| `/rs-log-errores <ruta log\|carpeta> [--desde YYYY-MM-DD] [--max N] [--glob *.log] [--niveles ERROR,FATAL]` 🟣 | Lee el log de errores de la web, **deduplica** las ocurrencias del mismo fallo, tría lo que es bug de lo que es ruido, abre **una tarea por tipo de error** en el gestor del proyecto (Jira o Mantis, detectado igual que `/rs-tarea`) y propone lanzar el pipeline para cada una, de una en una. |

> **La deduplicación no la hace el modelo**: la hace el hook `parse-weblog.ps1` agrupando por **firma** — excepción + frame de código propio + mensaje normalizado (números, GUIDs, fechas y rutas pasan a marcadores, así que "Cliente 4711 no existe" y "Cliente 8322 no existe" son **una** tarea, no dos). Reconoce NLog/log4net, ELMAH XML y volcados planos de stack .NET.
>
> **El log no entra en contexto**: la tool devuelve solo el agregado (top-N firmas con recuento, ventana temporal y un par de muestras), nunca las líneas — da igual que el fichero pese cientos de MB. Los mensajes y muestras van con **PII redactada** antes de acabar copiados en un ticket.
>
> **No duplica tareas entre pasadas**: cada tarea lleva el marcador `[log:<firma>]` en el resumen; si al volver a analizar ya existe una issue abierta con esa firma, en vez de crearla otra vez ofrece añadir una nota con las nuevas ocurrencias.
>
> ⛔ Nada se crea sin que apruebes la lista propuesta, y el pipeline se lanza **de una en una**, nunca en lote.

---

## El modelo de BD no son solo tablas

Desde la 3.10.0, `BD\<proyecto>-model.json` incluye además el **inventario de objetos**:
vistas, procedimientos, paquetes, funciones, triggers, sinónimos y secuencias. Se rellena con
`hooks\sync-model-objects.ps1` (con `-DryRun` para ver qué haría sin escribir) y se ve en el
ERD, que gana una sección por tipo y, en el panel de cada tabla, **qué objetos la usan** — la
pregunta que se hace antes de cambiarle una columna.

⛔ **Se guarda la ficha y una firma del cuerpo, nunca el cuerpo.** El instalador sigue
extrayendo el DDL de la BD viva: esa es la garantía de que un paquete no puede entregar código
viejo. La firma añade lo que faltaba —saber **qué cambió** desde la última entrega, que el
delta por VCS de `/rs-actualizador` no ve porque un procedimiento modificado en BD no está en
el repositorio— sin renunciar a ella. Con eso, el actualizador ya pregunta por los objetos que
cambiaron en vez de depender de que alguien se acuerde, y el instalador avisa si el modelo y
la BD han derivado.

## Protección de datos personales en consultas a BD

Los agentes consultan la BD con `db_query` (solo `SELECT`, nunca escritura). Hasta la 3.0.0 el resultado íntegro entraba en el contexto de la conversación —y de ahí a un proveedor externo— sin ningún filtro: nombres, DNI, teléfonos, cuentas y direcciones de personas en gestión de cobro. Ahora esos valores se sustituyen, **antes de salir de la herramienta**, por un seudónimo determinista (HMAC-SHA256 con una clave que vive en tu perfil local, fuera del repositorio):

```
IDDEUDOR | NOMBRE           | DNI              | SALDO
---------+------------------+------------------+--------
1024     | pii:3f9a2c1b7e04 | pii:7e04dd5111a6 | 1250.00
1025     | pii:c8b17ff2a390 | pii:11a6b930c8b1 |  340.50
1026     | pii:3f9a2c1b7e04 | pii:7e04dd5111a6 |  980.00   <- misma persona: sigue siendo detectable
```

**Arranca apagada: si no haces nada, no cambia nada.** El modo por defecto es `off` mientras `BD\<proyecto>-model.json` no declare otra cosa, así que un workspace que actualiza sigue viendo exactamente los mismos resultados que antes. Nada se activa solo.

Dos cosas sí aplican siempre, también con el modo en `off`, porque no dependen de la política del workspace: `executions/history.json` se sanea al escribirlo (un DNI/NIE, IBAN o correo en la descripción de una tarea se guarda como `[PII]`), y las guardas `PreToolUse` —**si** están registradas— bloquean `sqlplus`/`sqlcmd` directos y la escritura de datos personales en ficheros. Ninguna de las dos cambia lo que devuelve una consulta.

### Los tres modos

| Modo | Qué hace |
|------|----------|
| `off` (por defecto) | Nada se evalúa, los datos salen en claro. Cada respuesta lo indica con `pii.mode = "off"`. **No protege.** |
| `audit` | Evalúa cada columna e informa de qué se **habría** enmascarado (`pii.masked`, `pii.suspect`, `pii.predicate_warning`). ⚠️ **No protege: los datos siguen saliendo en claro.** Quien activa `audit` no puede reportar que ha activado la protección. |
| `enforce` | Enmascarado real. `pii_policy.transform`: `hash` (seudónimo, por defecto — permite correlacionar filas) o `suppress` (literal `[PII]`, sin correlación). |

Qué se considera dato personal, por precedencia: la marca `"pii"`/`"safe"` de la columna → el patrón del nombre (`TELEFON*`, `DNI*`, `*IBAN*`…) → tabla paramétrica → tipo (numérico, fecha, PK y FK salen en claro) → por defecto, el texto se enmascara. Detalle y ajustes del bloque `pii_policy` → `references/json-schema.md`.

### Cómo activarla, en orden

Todo lo que escribe pide **confirmación explícita**, en cualquier dirección (también al volver a `off`).

1. **`/rs-pii status`** — modo actual, si las guardas están registradas y qué columnas salen hoy en claro. Solo lectura.
2. **`/rs-pii bootstrap`** — muestrea la BD y escribe `docs/inventario-pii.md` (tabla, columna, categoría, tratamiento propuesto). No toca el modelo y **nunca reproduce un valor muestreado**. Es requisito de `enforce`, y ⛔ no se ejecuta con `enforce` ya activo: los valores llegarían enmascarados y el inventario saldría vacío o falso.
3. **`/rs-pii audit`** — mide sin proteger. Aquí es donde se revisan `pii.masked` y `pii.suspect` en el trabajo diario y se corrigen las clasificaciones equivocadas, antes de que empiecen a molestar.
4. **`/rs-pii enforce`** — comprueba el inventario, registra las dos guardas `PreToolUse` en tu `~/.claude/settings.json` (configuración **personal**, fuera del repo, afecta a todas tus sesiones de Claude Code), verifica el registro y **solo entonces** escribe el modo. Si el registro falla, no conmuta.
5. **Reiniciar Claude Code.**

> ⚠️ **El paso 5 no es opcional.** Claude Code lee la configuración de hooks al arrancar: las guardas registradas en una sesión **no están vivas en esa sesión**. Hasta que reinicies, `enforce` solo enmascara lo que pasa por `db_query` — el bypass por `Bash` (`sqlplus`/`sqlcmd` directos) y por `Write`/`Edit` sigue abierto. `/rs-pii status` dice si están registradas, pero eso describe el fichero, no la sesión en curso.

`/rs-pii off` vuelve atrás. **No** desregistra las guardas: son configuración personal, posiblemente compartida con otros workspaces, y siguen bloqueando `sqlplus`/`sqlcmd` y la escritura de PII con o sin `enforce`.

### Corregir una columna mal clasificada

La clasificación va por nombre, tipo y tabla — no adivina. Las dos direcciones se corrigen en el modelo BD (`references/json-schema.md` → "Política PII"):

- **Sale en claro y sí es dato personal** → `"pii": true` en la columna. Si el caso es sistemático, un patrón en `pii_policy.patterns_add`.
- **Sale enmascarada y no lo es** → `"safe": true` en la columna. Si sobra el patrón de nombre para todo el workspace, `pii_policy.patterns_remove`.
- **Sigue enmascarada pese a `"safe": true`** → son sus **valores** los que tienen forma de dato personal (DNI, NIE, IBAN, correo, teléfono, tarjeta). Es la red de seguridad, y **no se puede desactivar**: no existe una marca de "en claro pase lo que pase". Comprobar el contenido real antes de darlo por falso positivo → `references/troubleshooting.md`.

⛔ El remedio de un enmascarado que molesta nunca es rodear el filtro.

### Qué NO protege

Resumen de `docs/proteccion-pii-consultas-bd.md` §5. Esta medida es **provisional**: el control definitivo (usuario de BD de solo lectura + redacción en el propio motor) está pedido a Sistemas en ese mismo documento.

- **Solo filtra `db_query`.** Las tools que mantienen el modelo y leen estructura (`sync_from_db`, `compare_model`, `get_table_schema`, `render_erd`…) no pasan por el filtro: leen metadatos —nombres de tabla, columna, tipo, índice—, no datos de personas. Nombres en claro siempre, también en `enforce`. ⚠️ Reverso: si el **catálogo del sistema** se consulta con `db_query` (`ALL_TAB_COLUMNS`, `INFORMATION_SCHEMA.COLUMNS`), esos nombres **sí** vuelven enmascarados —esas tablas no están en el modelo—. Para leer estructura, usar las tools de modelo. Ver `docs/proteccion-pii-consultas-bd.md` §4.5.
- **El dato sale de la base de datos.** El motor sigue emitiendo el valor en claro y el filtro actúa después. Cualquier fallo, error de configuración o ruta no prevista lo expone. El control en BD no tiene esta propiedad.
- **Es evitable.** El bloqueo de `sqlplus`/`sqlcmd` es un **guardarraíl frente al descuido, no una frontera de seguridad**: se elude con un script intermedio o invocando el binario por otra vía.
- **Un `WHERE` sigue infiriendo el valor.** `SELECT COUNT(*) ... WHERE DNI LIKE '1234%'` devuelve un número, que sale en claro por diseño; repitiendo la consulta se reconstruye el dato sin haber visto un solo valor enmascarado. La medida **avisa** (`pii.predicate_warning`), no bloquea — bloquear rompería el filtrado legítimo.
- **Un seudónimo sigue siendo dato personal.** Art. 4(5) RGPD: la seudonimización reduce el riesgo, no saca el dato del ámbito de la norma. `pii:3f9a2c1b7e04` se sigue transfiriendo al proveedor externo. Si el requisito es que el dato personal **no salga en claro**, esto lo cumple; si es que **no salga**, no lo cumple.
- **Depende de que el plugin esté instalado.** *(Corregido en 3.4.0: hasta entonces las guardas se registraban a mano en la configuración personal de cada desarrollador, no viajaban con el repositorio y guardaban rutas absolutas que cada actualización dejaba apuntando a una carpeta inexistente — fallaban abiertas y sin señal.)* Hoy las declara el propio plugin y se instalan, actualizan y retiran con él. Queda la dependencia ordinaria: sin plugin no hay guardas, y un plugin recién instalado o actualizado no las tiene vivas hasta reiniciar Claude Code. `/rs-env` y `/rs-pii status` distinguen las dos caras — si están **disponibles** y si **bloquean aquí** (`guards_missing`).
- **La vía de respaldo puede devolver datos sin filtrar.** Si `db_query` cae al hook y ahí el filtro **no se puede ni ejecutar** (falta Python o el fichero del filtro en el puesto), la consulta devuelve los datos sin enmascarar y lo señala en la respuesta. Es deliberado: dejar sin servicio la consulta empuja al cliente de BD directo, que no pasa por ningún filtro. Si el filtro sí corre y falla, no se devuelve ninguna fila.
- **Una columna marcada `"safe"` por error no se detecta** salvo que sus valores tengan forma reconocible — nombres, apellidos y direcciones no la tienen. Solo lo ve la revisión del cambio en el control de versiones.
- **Fuera del filtro**: los ficheros que generan el instalador y el actualizador, la exportación del modelo y los informes HTML. Se entregan al cliente por diseño y pueden contener datos reales; su control es organizativo.

---

## Qué hay por debajo

No necesitas esto para usar el plugin, pero explica cómo funciona.

### MCP Server

Servidor local `mcp/rs-workspace-server.py` (FastMCP) con **49 tools** que envuelven la lógica del plugin. Preferente sobre los hooks — más eficiente en tokens, con caché en memoria y disco.

**Protección de contexto** — nunca satura la conversación:
- `compile_check` / `run_tests` / `find_symbol` / `db_query` truncan resultados a un máximo.
- `parse_web_log` devuelve el **agregado** de un log de errores (firmas + recuento), nunca sus líneas: un log de cientos de MB se resume sin cargarlo.
- `render_erd`, `render_dashboard`, `generate_sql`, `export_dmd` generan **ficheros**, nunca cargan el contenido en contexto.
- El modelo BD (~180K tokens) nunca se carga entero: `search_model` → `get_model_index` → `get_table_schema`.

Lista completa → `references/mcp.md`.

### Hooks

Scripts PowerShell en `hooks/` — fallback cuando el MCP no está activo. Dos hooks de infraestructura corren solos:
- `skill-trigger.ps1` — fuerza el disparo del plugin al mencionar una `.sln` en workspaces RS.
- `runner/runner.ps1` — ejecuta los builds encolados (batch-build / online-publish / copy-ais).

Lista completa → `references/hooks.md`.

### Modelo de BD

Modelo JSON vivo en `BD/<proyecto>-model.json`:
- Tablas y columnas desde el esquema real (SQL Server / Oracle).
- Relaciones inferidas desde código DALC con nivel de confianza.
- Índices sincronizables desde BD; descripciones semánticas editables.
- Export a DDL y Oracle Data Modeler (`.dmd`).
- Detección de drift + generación de scripts de migración.
- **Merge seguro**: preserva siempre `source="manual"` y descripciones; tablas ausentes se marcan `orphan`, nunca se borran.
- **Formato estable**: lo escribe un único serializador canónico (`indent=2`, `ensure_ascii`,
  CRLF, UTF-8 con BOM), verificado tras cada escritura. El fichero vive en el repositorio y se
  revisa por diff, así que dos escritores con dos formatos hacían el diff inservible aunque el
  contenido fuera idéntico.

#### "No lo veo" no es "no existe"

Si la cuenta de BD **no es dueña del esquema**, ve solo lo que tiene concedido por GRANT — y
Oracle no permite distinguir un objeto inexistente de uno sin permiso. Por eso:

- Una tabla que no sale en la sincronización **se conserva entera** (columnas, relaciones e
  índices) y se marca `visible: false`. Nunca se borra ni se degrada.
- Cada sincronización emite un **bloque de cobertura**: cuántos objetos de cada tipo ve el
  diccionario frente a los capturados, con qué cuenta se leyó y qué GRANTs tiene. Con hueco,
  devuelve `parcial` — "el modelo está incompleto", que no es lo mismo que "eso ya no está".
- El **PL/SQL exige `GRANT EXECUTE`**, no `SELECT`. Sin él, el diccionario devuelve cero
  procedimientos sin error; `/rs-instalador` y `/rs-actualizador` ahora **fallan** en ese caso en
  vez de entregar un paquete sin lógica de servidor.
- Para leer con otra cuenta: `-Conexion <id>` en los hooks y `conexion=<id>` en las tools, contra
  las `conexiones[]` de `.rs-databases.json`. Es la única forma de ver los **sinónimos privados**.
  Sin `-Conexion` se usa siempre la conexión principal; un id que no existe corta con la lista de
  válidas, y la conexión usada aparece en la salida.

---

## Reglas clave

- **Aprobación humana del plan** obligatoria antes de tocar código (no aplica a los modos de solo lectura).
- Validator y Tester son **bloqueantes** — el build no se ejecuta si fallan.
- **Scope estricto**: solo proyectos incluidos en la `.sln` activa.
- **Build con evidencia**: nunca "build OK" sin output real del runner.
- El modelo BD preserva siempre descripciones y relaciones manuales.
- Scripts SQL generados siempre a `C:\AIS\<proyecto>\scripts\`.
- Scripts de idiomas (RIDIOMA/RCONTROLES) obligatorios en Online cuando hay controles/`Idm.Texto`/rebinds nuevos. Idiomas del **catálogo 32** de `RTABL`; IDTEXTO por rango (errores 1000–1999, mensajes 2000–2999, pantalla ≥3000) **rellenando huecos**.
- **VCS nunca se asume** — `detect_vcs` decide SVN/Git/ninguno antes de cualquier diff/commit.
- Los comandos que **escriben** (`/rs-rename`, `/rs-format`, `/rs-migrar`, `/rs-commit`, `/rs-deshacer`, `/rs-pii audit|enforce|off`, pipeline) piden confirmación antes de aplicar.

---

## Requisitos y resolución de problemas

**Requisitos de la máquina:**

| Componente | Para qué |
|------------|----------|
| Python 3.11+ + `pip install "mcp>=1.2.0,<2"` | MCP server. El paquete **no se instala solo** y sin él `rs-workspace` no arranca; el tope `<2` es obligatorio (`mcp` 2.0.0 eliminó `mcp.server.fastmcp`). Debe quedar en el Python que resuelve `python` en el PATH |
| .NET SDK | `dotnet build` / `dotnet test` |
| PowerShell 7+ | Hooks |
| Visual Studio + MSBuild | Builds Online (vía vswhere) |
| Subversion CLI **o** Git CLI 2.x | Diff/commit/historial (según el proyecto) |

> Subversion: instala el CLI con la **misma versión que TortoiseSVN** para evitar conflictos de working copy.

**Primer arranque en un workspace nuevo:** ejecuta `/rs-init` (crea la config de BD, el andamiaje de docs y el primer modelo BD), luego `/rs-env` para validar que todo está en su sitio.

Guía de problemas comunes → `references/troubleshooting.md`.

---

## Para mantenedores del plugin

- **Fuente canónica**: el repo Git privado `https://github.com/vgege86/rs-enterprise-plugin.git`. El checkout local es solo un checkout — nada del plugin debe depender de su ruta.
- **Anatomía interna y patrón de extensión** → `docs/plugin-architecture.md`. Léelo antes de añadir un modo, agente, tool MCP o hook.
- **Modificar el plugin de forma guiada** → `/rs-plugin-dev <qué cambiar>`: lee el doc de arquitectura, planifica, pide aprobación, **sube la versión** (obligatorio) y sincroniza la documentación.
- ⛔ Nunca editar la copia cacheada por Claude Code (`~/.claude/plugins/cache/...`) — es un snapshot, se pisa en cada update.
- Tras cualquier cambio → **bump de versión** en `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` (idénticas), luego `/plugin marketplace update rs-enterprise-agent` y reiniciar.

### Estructura del repo

```
.claude-plugin/   marketplace.json + plugin.json (manifiesto, versión, hooks)
.mcp.json         registro del MCP server rs-workspace
skills/           rs-enterprise-agent (pipeline + modos) · rs-plugin-dev · rs-jira · rs-mantis
agents/           51 subagentes: pipeline y modos directos
commands/         49 definiciones de slash commands
hooks/            scripts PowerShell (build, SVN/Git, BD, análisis, trigger)
mcp/              servidor MCP con 49 tools
references/       documentación de referencia (carga bajo demanda)
docs/             plugin-architecture.md (fuente canónica) + agentic_manual
scripts/          utilidades python (render-erd, render-dashboard, export-dmd…)
runner/           runner.ps1 — ejecutor de builds (Stop hook)
tests/            suite de tests del plugin (pytest + Pester)
executions/       history.json — historial de ejecuciones
assets/           widget ERD inline
```
