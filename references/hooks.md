# Hooks disponibles

Scripts PowerShell en `hooks/`. Ejecutar directamente si el MCP no está activo.

## Build / Deploy

| Script | Parámetros | Descripción |
|--------|-----------|-------------|
| `hooks/compile-check.ps1` | `<sln> [-NoRestore]` | Build real → `errors[], warnings[], success` |
| `hooks/test-runner-check.ps1` | `<sln> [-NoBuild]` | dotnet test → `passed/failed/failures[]` |
| `hooks/create-test-project.ps1` | `<sln> [-Framework xunit\|mstest\|nunit] [-ProjectName <nombre>]` | Crea proyecto de test y lo añade a la .sln |
| `hooks/validate-solution.ps1` | `<sln>` | Confirma que la .sln existe y es accesible |

## Instalador (modo `/rs-instalador`)

Generan el instalador completo de cliente en `<destino>` (= `C:\AIS\<Proyecto>\Instalador`). Se
invocan vía `runner/runner.ps1` (patrón `TYPE: INSTALLER` / `COMMAND`), no como tools MCP. Leen la
config por cliente de `docs\<Proyecto>-instalador.json`.

| Script | Parámetros | Descripción |
|--------|-----------|-------------|
| `hooks/installer-batch.ps1` | `<workspace> <destino>` | **Rebuild** Release (msbuild `/t:Rebuild`, wipe previo de bin/obj) de los csproj-exe de los batch activos (JSON `batch`) → copia EXEs a `<destino>\EXES`, con **gate de coherencia** (todos los .exe + DLLs compartidas del mismo build) |
| `hooks/installer-agendaweb.ps1` | `<workspace> <destino>` | Publish FileSystem (msbuild `DeployTarget=WebPublish` + `PublishProfile` del JSON) de la Agenda Web → `<destino>\AgendaWeb` |
| `hooks/installer-servicemanager.ps1` | `<workspace> <destino>` | `dotnet publish` host net8 → `<destino>\ServiceManager`; DLL de módulos activos → `\Modulos` |
| `hooks/installer-scripts.ps1` | `<workspace> <destino>` | Llama a `scripts/installer-ddl.py` + `scripts/installer-inserts.py` → `<destino>\Scripts` |

Scripts Python asociados: `scripts/installer-ddl.py` (DDL sin schema desde `model.json`) y
`scripts/installer-inserts.py` (inserts por tabla paramétrica desde `subviews["Parametricas"]`).

⛔ Reglas de estos hooks (violarlas ya ha roto el instalador en real):
- **Batch (frankenbuild → StackOverflow)**: NUNCA `dotnet build` incremental. Las DLLs compartidas
  (`Comun`/`BusComun`/`RSModel`) no tienen strong-name y su `AssemblyVersion` es `1.0.*` → el CLR
  enlaza por nombre simple; mezclar exes y DLLs de builds de días distintos hace que un exe llame a un
  método con firma cambiada → recursión infinita → `StackOverflowException` al arrancar. Por eso:
  `msbuild /t:Rebuild` de los **csproj-exe** (no la .sln — un proyecto de Tests rompía `dotnet build` y
  dejaba el .exe sin actualizar) tras **wipe de todos los bin/obj del scope**, y un **gate final** que
  exige que todos los `.exe` + DLLs compartidas desplegados sean de ese mismo build (si alguno es de
  otra fecha → `exit 1`). Trampa asociada: `<Reference><HintPath>..\bin\Debug\X.dll` de un proyecto
  con `X.csproj` en el workspace enlaza contra una DLL de otro build → usar `<ProjectReference>` (el
  hook lo avisa). Config opcional `sharedAssemblies` en el JSON (default `Comun,BusComun,RSModel`).
  Segundo gate (binding redirects): en carpeta de deploy compartida, last-writer-wins deja un
  `<exe>.exe.config` viejo (`bindingRedirect newVersion=X`) junto a una `System.*.dll`/tercero nueva
  (`AssemblyVersion=Y`) → `FileLoadException` en bucle → StackOverflow. El hook verifica que, para cada
  redirect cuyo DLL está desplegado, `newVersion` == `AssemblyName.Version` real del DLL; si no → `exit
  1`. "Terceros version-pinned = OK" es falso en carpeta compartida.
- **AgendaWeb**: `DeployOnBuild` sin `DeployTarget=WebPublish` hace que msbuild empaquete
  (`obj\Release\Package\<app>.zip`) en vez de publicar a carpeta. `publishUrl` se pasa siempre como
  propiedad global para ganar al `PublishUrl` del `.pubxml`, que apunta al AIS **en vivo**.
- **Inserts**: el SELECT se emite con una expresión por línea (una sola línea → `SP2-0341`) y con
  `TO_CLOB` en la primera (concatenación ancha → `ORA-01489`). Las columnas `RAW` viajan en
  hexadecimal (`RAWTOHEX`/`HEXTORAW`); `TO_CHAR` sobre `RAW` da `ORA-00932`. Los LOB binarios
  (`BLOB`) se emiten `NULL` con aviso en la cabecera del `.sql`.

## Análisis / Scope

| Script | Parámetros | Descripción |
|--------|-----------|-------------|
| `hooks/parse-sln.ps1` | `<sln>` | Parsea .sln → `scope_dirs, tipo (Batch/Online), workspace` |
| `hooks/find-symbol.ps1` | `<nombre> "<scope_dirs>" [-Type class\|method\|property\|interface\|enum\|any]` | Localiza símbolo → `archivo:línea` |
| `hooks/find-doc-section.ps1` | `<workspace> <keyword>` | Busca en docs funcionales y técnicas → sección, archivo, línea |
| `hooks/security-scan.ps1` | `<sln_path>` | SQL injection, credenciales hardcodeadas, XSS, input sin validar → findings con severidad |
| `hooks/map-dependencies.ps1` | `<workspace>` | Mapa dependencias entre soluciones → proyectos compartidos, conflictos NuGet |
| `hooks/search-code.ps1` | `<workspace> <sln> <pattern> [-Glob *.cs] [-Context 2] [-MaxResults 50]` | Regex en scope garantizado (equivalente a `search_code`) |

## BD / Modelo

| Script | Parámetros | Descripción |
|--------|-----------|-------------|
| `hooks/get-config.ps1` | `<workspace>` | Lee .rs-databases.json → `motor, datasource, schema, model_path` (principal) + `conexiones[], motores[]` |
| `hooks/get-bd-model.ps1` | `-Workspace <ws> [-Tables "T1,T2"]` | Schemas de tablas del model.json (equivalente a `get_table_schema`) |
| `hooks/db-query.ps1` | `-Workspace <ws> -Sql "<SELECT\|WITH...SELECT>" [-MaxRows 200] [-Conexion <id>]` | Consulta solo-lectura (SELECT o CTE WITH...SELECT; WITH con verbo de escritura se rechaza) contra una BD de .rs-databases.json (`-Conexion <id>`, default principal; solo Oracle) (equivalente a `db_query`) |
| `hooks/lib-dbconfig.ps1` | (librería, no se invoca sola) | Lectura/validación de `.rs-databases.json` y parseo de cadenas de conexión — usada internamente por `get-config.ps1`, `db-query.ps1`, `check-env.ps1` |
| `hooks/convert-config.ps1` | `<workspace> [-Force]` | `XMLConfig.xml` → `.rs-databases.json`. Uso único por workspace; no borra el XML |
| `hooks/compare-model.ps1` | `<workspace>` | Drift model.json vs esquema real BD |
| `hooks/generate-migration.ps1` | `<workspace>` | Scripts SQL (CREATE TABLE / ALTER TABLE ADD) desde drift |
| `hooks/sync-from-db.ps1` | `<workspace> <proyecto>` | Sincroniza tablas/columnas desde BD real → `table_count` (escritura atómica) |
| `hooks/sync-model-tables.ps1` | `<workspace> <tablas-coma-separadas>` | Actualiza tablas específicas de model.json post-migración |
| `hooks/sync-indexes.ps1` | `<workspace> [-Proyecto <nombre>]` | Sincroniza índices desde BD al modelo — preserva source=manual |
| `hooks/analyze-dalc.ps1` | `<workspace> <proyecto> [-SolutionPath <sln>]` | Infiere relaciones desde JOINs/WHERE en DALCs |
| `hooks/render-erd.ps1` | `<workspace> [-Proyecto <nombre>]` | Genera ERD HTML y lo abre en navegador → `{path, table_count}` |
| `hooks/render-dashboard.ps1` | `<workspace>` | Genera dashboard HTML de estadísticas (executions/history.json) y lo abre → `{path, opened}`. Fallback 1:1 de `render_dashboard` |
| `hooks/render-help.ps1` | `<workspace>` | Renderiza el README del plugin a un HTML navegable (guía de usuario) y lo abre → `{path, opened}`. Fallback 1:1 de `render_help` |
| `hooks/generate-sql.ps1` | `<workspace> [-Proyecto <nombre>] [-Motor ORACLE\|SQLSERVER]` | Genera DDL SQL → `C:\AIS\<proyecto-lowercase>\scripts\<proyecto>-ddl-<motor>.sql` |
| `hooks/export-dmd.ps1` | `<workspace> [-Proyecto <nombre>]` | Exporta a Oracle Data Modeler `.dmd` |

## Control de versiones (SVN / Git)

`hooks/detect-vcs.ps1` decide cuál de los dos bloques usar — nunca asumir uno u otro sin llamarlo primero.

| Script | Parámetros | Descripción |
|--------|-----------|-------------|
| `hooks/detect-vcs.ps1` | `<workspace>` | Detecta VCS subiendo por las carpetas → `{vcs: "svn"\|"git"\|"none", root}` |
| `hooks/svn-diff.ps1` | `<workspace>` | Estado SVN → `modificados, añadidos, eliminados, ?` |
| `hooks/svn-log.ps1` | `<workspace> [-Solution <nombre>] [-Limit 10]` | Historial commits SVN → JSON (requiere svn CLI) |
| `hooks/svn-diff-revision.ps1` | `<workspace> <revisions> [-MaxDiffChars 15000]` | Diff revisiones SVN → `files_changed, combined_diff` (requiere svn CLI) |
| `hooks/svn-add.ps1` | `<workspace> [-Files <lista>]` | Añade ficheros ?: CLI → TortoiseProc → instrucciones manuales |
| `hooks/git-status.ps1` | `<workspace>` | Estado Git → `modificados, staged, sin trackear (?), conflicto` |
| `hooks/git-log.ps1` | `<workspace> [-Solution <nombre>] [-Limit 10]` | Historial commits Git → JSON, `revision` = hash corto (requiere git CLI) |
| `hooks/git-diff-revision.ps1` | `<workspace> <revisions> [-MaxDiffChars 15000]` | Diff de commits Git (hashes coma-separados) → `files_changed, combined_diff` (requiere git CLI) |
| `hooks/git-add.ps1` | `<workspace> [-Files <lista>]` | Añade ficheros ??: CLI → TortoiseGitProc → instrucciones manuales |
| `hooks/vcs-revert.ps1` | `<workspace> -Files <lista ;-sep> [-DryRun]` | Revierte una lista **explícita** de ficheros a su estado versionado (SVN/Git autodetectado) o los elimina si son nuevos. `-DryRun` devuelve el plan sin ejecutar. Fallback 1:1 de `vcs_revert` |

## Entorno / Logging

| Script | Parámetros | Descripción |
|--------|-----------|-------------|
| `hooks/check-env.ps1` | `<workspace> <proyecto>` | Valida .rs-databases.json, AIS, dotnet, SVN, Git, modelo BD, docs → `checks[], overall` |
| `hooks/log-execution.ps1` | `<workspace> <sln> <task> [-Status success\|fail\|partial] [-Agents <lista>]` | Registra en `executions/history.json` (max 500, archiva mensualmente) |
| `hooks/scan-aspx.ps1` | `-SlnPath <sln>` | Extrae controles AIS de .aspx → `RIDIOMA/RCONTROLES` inserts |
| `hooks/skill-trigger.ps1` | (stdin JSON, hook UserPromptSubmit de Claude Code) | Detecta `.sln` en el prompt dentro de workspaces RS e inyecta recordatorio de invocar la skill — no lo ejecutan los agentes |

## Jira

| Script | Parámetros | Descripción |
|--------|-----------|-------------|
| `hooks/jira-attach.ps1` | `-IssueKey <KEY> -Files "<ruta1,ruta2>"` | Adjunta ficheros a una issue de Jira Cloud (`POST /rest/api/3/issue/{KEY}/attachments`). Lee credenciales de `~/.claude/rs-jira-credentials.json`; ⛔ nunca imprime el token. Equivalente a la tool `jira_attach`. Ver `references/jira.md` |

## Build (via runner — ver `agents/rs-editor-build.md`)

| Script | Parámetros | Descripción |
|--------|-----------|-------------|
| `hooks/batch-build.ps1` | `<Solution> "<workspace>"` | Build Debug+Release y copia binarios a `C:\ais\<proyecto>\Procesos\Exes` |
| `hooks/online-publish.ps1` | `<csproj> [<Profile>]` | Publish MSBuild con perfil — `FolderProfile1` es solo el default del script, NO asumir que es el nombre real: verificar `<WebFolder>\Properties\PublishProfiles\*.pubxml` antes |
| `hooks/service-build.ps1` | `<slnPath> [<workspace>]` | Build de solución `tipo=Servicio` — código con MSBuild + instalador `.vdproj` con devenv (degrada a solo-código si falta devenv). No copia a AIS; el `.msi`/`setup.exe` es el entregable |
| `hooks/copy-ais.ps1` | `<source> <workspace>` | Copia binarios a destino AIS del proyecto |

## Scripts de utilidad (manuales)

| Script | Descripción |
|--------|-------------|
| `scripts/clean-build.ps1` | Limpia carpetas bin/obj antes de compilar |
| `scripts/clean-ais.ps1` | Limpia destino AIS antes de deploy |
| `scripts/print-structure.ps1` | Imprime estructura del proyecto |
| `scripts/reset-environment.ps1` | Resetea entorno de desarrollo |
| `scripts/run-agent.ps1` | Invoca agente manualmente via CLI |
| `scripts/test-runner.ps1` | Ejecuta tests reales (`dotnet test`) |
