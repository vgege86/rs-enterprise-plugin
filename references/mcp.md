# MCP rs-workspace

Servidor MCP local. Preferente sobre hooks — más eficiente en tokens.
Fallback: hook equivalente listado en `references/hooks.md`.

> El primer parámetro `workspace` (raíz del workspace/trunk) acepta también el alias `path` en la
> entrada — mismo valor, cualquiera de los dos nombres funciona (ver CHANGELOG 2.15.10). El nombre
> canónico sigue siendo `workspace`.

| Tool | Uso |
|------|-----|
| `ping()` | Health check — **version**, **server_path**, hooks_dir, hooks_found, svn_cli, git_cli, python version. NO spawnea subprocesos: `svn_cli`/`git_cli` = `null` si aún no se comprobaron (perezoso, se resuelven al usar una tool VCS). `server_path`/`version` delatan si se está sirviendo una copia obsoleta fuera del plugin |
| `get_scope(sln_path)` | Paso 2b — parsea .sln → scope_dirs, tipo, workspace |
| `validate_solution(sln_path)` | Paso 2 — confirma que la .sln existe y es accesible |
| `detect_vcs(workspace)` | Detecta SVN/Git subiendo por las carpetas → `{vcs, root}`. Llamar antes de cualquier tool `svn_*`/`git_*` |
| `get_db_config(workspace)` | Paso BD — lee .rs-databases.json → motor, datasource, schema (principal) + conexiones[], motores[] |
| `find_symbol(symbol, scope_dirs, symbol_type?)` | Localiza clases/métodos/propiedades en scope |
| `compile_check(sln_path, no_restore=True, max_errors=20)` | Validator — build real → errors[], warnings[], success |
| `run_tests(sln_path, no_build?)` | Tester — dotnet test → has_test_project (bool), passed/failed/failures[], skipped (conteo). Sin proyecto → solo has_test_project=false |
| `get_model_index(workspace)` | Índice ligero: {TABLA:[COL1,COL2,...]} ~15K tokens. Para impact analysis |
| `get_table_schema(workspace, tables)` | Esquema completo (cols/tipos/relaciones/índices) de tablas específicas. ~3K tokens |
| `search_model(workspace, keyword)` | Busca keyword en tablas/columnas/descripciones. Para localizar tablas sin saber el nombre |
| `compare_model_tables(workspace, tables)` | Drift BD solo de tablas específicas. Post-migración |
| `batch_find_symbols(symbols, scope_dirs)` | N símbolos en una llamada — evita N round-trips |
| `search_code(workspace, sln_path, pattern)` | Regex en scope garantizado. Reemplaza 3-8× Grep |
| `svn_status(workspace)` | Estado SVN → modificados, añadidos, eliminados, ? sin versionar |
| `git_status(workspace)` | Estado Git → modificados, staged, ?? sin trackear, conflicto (U). Equivalente Git de `svn_status` |
| `create_test_project(sln_path, framework?, project_name?)` | Crea proyecto xUnit/mstest/nunit |
| `db_query(workspace, sql, max_rows=200, conexion="")` | Consulta de solo-lectura: `SELECT` o CTE (`WITH ... SELECT`); un `WITH` con verbo de escritura (INSERT/UPDATE/DELETE/MERGE) se rechaza. `conexion` = id de `.rs-databases.json`; sin él, la principal. Devuelve `columns[]` (nombres, una sola vez) y `rows[]` (listas de valores en ese orden) |
| `compare_model(workspace)` | Diff model.json vs BD real → tablas/columnas nuevas/eliminadas |
| `scan_aspx(sln_path)` | Extrae controles AIS de .aspx → IDs y textos para RIDIOMA/RCONTROLES |
| `log_execution(workspace, solution, task, status?, agents?)` | Registra en executions/history.json |
| `generate_migration(workspace)` | Scripts SQL migración desde drift modelo→BD |
| `svn_log(workspace, solution?, limit?)` | Historial SVN → revisión, autor, fecha, mensaje |
| `git_log(workspace, solution?, limit?)` | Historial Git → hash corto, autor, fecha, mensaje. Equivalente Git de `svn_log` |
| `find_doc_section(workspace, keyword)` | Localiza sección en docs funcionales y técnicas (para UpdateDocs y la propuesta al manual técnico) |
| `svn_diff_revision(workspace, revisions, max_diff_chars?)` | Diff revisiones SVN filtrado (para rs-validar-req) |
| `git_diff_revision(workspace, revisions, max_diff_chars?, summary_only?)` | Diff de commits Git (hashes) filtrado. Equivalente Git de `svn_diff_revision` |
| `svn_add(workspace, files?)` | Añade ficheros ?: CLI → TortoiseProc → instrucciones manuales |
| `git_add(workspace, files?)` | Añade ficheros ??: CLI → TortoiseGitProc → instrucciones manuales. Equivalente Git de `svn_add` |
| `vcs_revert(workspace, files, dry_run?)` | Revierte una lista **explícita** de ficheros a su estado versionado (SVN/Git autodetectado) o los elimina si son nuevos. `dry_run=True` devuelve el plan sin ejecutar. Para `/rs-deshacer` (previa confirmación humana) |
| `security_scan(sln_path)` | Scan seguridad: SQL injection, XSS, credenciales, input sin validar |
| `sync_model_tables(workspace, tables)` | Sincroniza tablas específicas model.json con BD (post-migración) |
| `map_dependencies(workspace)` | Mapa dependencias: proyectos compartidos entre soluciones, conflictos NuGet |
| `sync_from_db(workspace)` | Sincroniza tablas/columnas del modelo BD desde esquema real de BD |
| `sync_indexes(workspace)` | Sincroniza índices desde BD al modelo — preserva source=manual |
| `analyze_dalc(workspace, sln_path?)` | Infiere relaciones entre tablas analizando código DALC |
| `render_erd(workspace)` | Genera ERD HTML y abre navegador — sin cargar modelo en contexto |
| `check_env(workspace)` | Valida entorno: .rs-databases.json, AIS, dotnet, SVN, Git, modelo BD → checks[] |
| `generate_sql(workspace, motor?)` | Genera DDL SQL a fichero — devuelve ruta, SQL no entra en contexto |
| `export_dmd(workspace)` | Exporta modelo a Oracle Data Modeler (.dmd) — devuelve ruta |
| `jira_attach(issue_key, files)` | Adjunta ficheros (`.sql`) a una issue de Jira Cloud. files = rutas coma-separadas. Credenciales en `~/.claude/rs-jira-credentials.json`. Usado por la skill `rs-jira` (ver `references/jira.md`) |
