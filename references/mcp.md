# MCP rs-workspace

Servidor MCP local. Preferente sobre hooks — más eficiente en tokens.
Fallback: hook equivalente listado en `references/hooks.md`.

> El primer parámetro `workspace` (raíz del workspace/trunk) acepta también el alias `path` en la
> entrada — mismo valor, cualquiera de los dos nombres funciona (ver CHANGELOG 2.15.10). El nombre
> canónico sigue siendo `workspace`.

| Tool | Uso |
|------|-----|
| `ping()` | Health check — **version**, **server_path**, hooks_dir, hooks_found, svn_cli, git_cli, python version. NO spawnea subprocesos: `svn_cli`/`git_cli` = `null` si aún no se comprobaron (perezoso, se resuelven al usar una tool VCS). `server_path`/`version` delatan si se está sirviendo una copia obsoleta fuera del plugin |
| `get_scope(sln_path)` | Paso 1b — parsea .sln → scope_dirs, tipo (Batch/Online/Servicio/Unknown), workspace (resuelto al trunk), installer_vdproj. Servicio = solución con Setup Project .vdproj |
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
| `db_query(workspace, sql, max_rows=200, conexion="")` | Consulta de solo-lectura: `SELECT` o CTE (`WITH ... SELECT`); un `WITH` con verbo de escritura (INSERT/UPDATE/DELETE/MERGE) se rechaza. `conexion` = id de `.rs-databases.json`; sin él, la principal. Devuelve `columns[]` (nombres, una sola vez) y `rows[]` (listas de valores en ese orden). Aplica la política PII del workspace (`pii_policy.mode` del modelo BD) y devuelve `pii` con el detalle de lo enmascarado — **el bloque `pii` hay que leerlo y trasladarlo al usuario, ver debajo**. Detalle en `docs/proteccion-pii-consultas-bd.md` |
| `compare_model(workspace)` | Diff model.json vs BD real → tablas/columnas nuevas/eliminadas |
| `scan_aspx(sln_path)` | Extrae controles AIS de .aspx → IDs y textos para RIDIOMA/RCONTROLES |
| `log_execution(workspace, solution, task, status?, agents?)` | Registra en executions/history.json |
| `generate_migration(workspace)` | Scripts SQL migración desde drift modelo→BD |
| `svn_log(workspace, solution?, limit?)` | Historial SVN → revisión, autor, fecha, mensaje |
| `git_log(workspace, solution?, limit?)` | Historial Git → hash corto, autor, fecha, mensaje. Equivalente Git de `svn_log` |
| `vcs_delta(workspace, desde, hasta?, ruta?, limit?)` | Delta de commits entre dos fechas (SVN o Git, **autodetectado**) → `commits[]` (rev, autor, fecha, mensaje, `tareas[]` Mantis/Jira citadas), `ficheros[]` con acción y `tareas[]` únicas. `ruta` limita a una subruta (ej. `Batch\Soluciones\RSProcIN`); `hasta` vacío = ahora; `truncado: true` si se alcanzó `limit`. Base de `/rs-actualizador` |
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
| `render_dashboard(workspace)` | Genera dashboard HTML de estadísticas (executions/history.json) y abre navegador — sin cargar el HTML en contexto |
| `render_help(workspace)` | Renderiza el README del plugin a un HTML navegable (guía de usuario) y abre navegador — sin cargar el HTML en contexto |
| `secure_credentials(workspace?, skip_jira?, skip_mantis?)` | Cifra en reposo (DPAPI, cuenta Windows) el password de `.rs-databases.json` (si se da workspace) y los tokens Jira/Mantis de `~/.claude`. Idempotente, no imprime secretos. Para `/rs-cifrar` |
| `check_env(workspace)` | Valida entorno: .rs-databases.json, AIS, dotnet, SVN, Git, modelo BD → checks[] |
| `generate_sql(workspace, motor?)` | Genera DDL SQL a fichero — devuelve ruta, SQL no entra en contexto |
| `export_dmd(workspace)` | Exporta modelo a Oracle Data Modeler (.dmd) — devuelve ruta |
| `jira_attach(issue_key, files)` | Adjunta ficheros (`.sql`) a una issue de Jira Cloud. files = rutas coma-separadas. Credenciales en `~/.claude/rs-jira-credentials.json`. Usado por la skill `rs-jira` (ver `references/jira.md`) |
| `jira_download(issue_key, file_id, out)` | Descarga un adjunto de una issue de Jira Cloud a `out`. `file_id` = id del adjunto (de `getJiraIssue`). Mismas credenciales que `jira_attach`. Usado por `rs-jira` y por `/rs-actualizador` para recoger los `.sql` de las tareas del rango |

---

## El bloque `pii` de `db_query` (obligatorio leerlo)

`db_query` devuelve siempre un objeto `pii`. **No es informativo: hay que mirarlo y, si trae
alguno de estos campos con contenido, decírselo al usuario en la respuesta.** Ignorarlo en
silencio convierte en nominales los avisos que la medida de protección de datos personales
promete (`docs/proteccion-pii-consultas-bd.md` §4.3 y §5.2c).

| Campo | Qué significa y qué hay que hacer |
|---|---|
| `pii.error` | El filtro no pudo aplicarse. En el camino de hook puede significar que los datos vienen **sin enmascarar** (fallo abierto), o que no vienen filas. **Avisar siempre, literal** |
| `pii.model_error` | Hay una política declarada pero el modelo BD no se puede usar (JSON corrupto, raíz que no es objeto): **la política NO se está aplicando**. Avisar y pedir revisar el modelo |
| `pii.suspect` | Columnas que salían en claro y cuyos **valores** tienen forma de dato personal (DNI, IBAN, correo, teléfono, tarjeta). La lista de patrones está incompleta. Nombrar las columnas y sugerir `/rs-pii bootstrap` |
| `pii.predicate_warning` | Columnas con datos personales usadas como **filtro** en el `WHERE`. Aunque la salida vaya enmascarada, el valor se puede inferir repitiendo la consulta (§5.2c). Avisar de que esa consulta interroga un dato personal |
| `pii.mode` | `off` = sin protección, `audit` = **los datos salen en claro**, `enforce` = enmascarado activo. No decir "protegido" con `off` ni con `audit` |

⛔ Nunca reproducir el valor de una celda enmascarada ni intentar sortear el filtro (por ejemplo
consultando la misma columna con otra expresión). Si un dato hace falta en claro, la salida es
declarar la columna como segura en el modelo BD (`/rs-pii`), no rodear el filtro.
