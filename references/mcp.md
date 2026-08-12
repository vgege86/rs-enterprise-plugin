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
| `compile_check(sln_path, no_restore=True, max_errors=20, builder="auto")` | Validator — build real → errors[], warnings[], success, `builder`/`builder_reason`. **El compilador se autodetecta leyendo los `.csproj`** (MSBuild de VS con .NET Framework/web/COM, CLI `dotnet` con SDK-style modernos). ⛔ `builder_error` = falta el compilador en la máquina → compilación **no verificada**, NO fallo del código: no mandarlo al fixer |
| `run_tests(sln_path, no_build?)` | Tester — ejecuta los tests → has_test_project (bool), total/passed/failed/skipped, failures[], source (`trx`/`console`/`none`), `runner`. **El runner se autodetecta** igual que en `compile_check`: `dotnet test` o MSBuild + `vstest.console.exe` en soluciones .NET Framework. Sin proyecto → solo has_test_project=false. ⛔ `parse_failed=true` (no se pudo leer el resultado), `no_tests_ran=true` (0 pruebas ejecutadas) o `runner_error` (falta el runner en la máquina) salen con success=false: es ausencia de evidencia, no verde ni rojo |
| `get_model_index(workspace)` | Índice ligero: {TABLA:[COL1,COL2,...]} ~15K tokens. Para impact analysis |
| `get_table_schema(workspace, tables)` | Esquema completo (cols/tipos/relaciones/índices) de tablas específicas. ~3K tokens |
| `get_db_objects(workspace, tabla?)` | Inventario de objetos de BD del modelo (vistas, procedimientos, paquetes, funciones, triggers, sinónimos, secuencias). Sin `tabla`, el conteo y los nombres por sección; con `tabla`, **solo los objetos que la usan** — el análisis de impacto de una columna sin salir del modelo. Guarda ficha y firma, **nunca el cuerpo**. `inventario: false` = nadie ha ejecutado el sync, y una respuesta vacía NO significa que la BD no tenga objetos. `tablas_usadas` se deriva por coincidencia de texto: un nombre en un comentario cuenta igual |
| `get_object_ddl(workspace, objeto, seccion?)` | DDL de **un** objeto leído de la BD viva — es la forma de leer el código que vive dentro de la BD y que ningún Grep del repo encuentra. Avisa si la firma de la BD no coincide con la del modelo (alguien lo tocó tras el último sync). Sin `seccion` usa el inventario para saber dónde mirar; si el objeto no está en él, barre los siete tipos (más lento). El cuerpo se lee, no se guarda |
| `search_model(workspace, keyword)` | Busca keyword en tablas/columnas/descripciones. Para localizar tablas sin saber el nombre |
| `compare_model_tables(workspace, tables, conexion="")` | Drift BD solo de tablas específicas. Post-migración. `conexion` = id de `.rs-databases.json`; sin él, la principal |
| `batch_find_symbols(symbols, scope_dirs)` | N símbolos en una llamada — evita N round-trips **y** N recorridos del árbol: baja al hook una sola vez con `-Symbols` |
| `search_code(workspace, sln_path, pattern)` | Regex en scope garantizado. Reemplaza 3-8× Grep |
| `svn_status(workspace)` | Estado SVN → modificados, añadidos, eliminados, ? sin versionar |
| `git_status(workspace)` | Estado Git → modificados, staged, ?? sin trackear, conflicto (U). Equivalente Git de `svn_status` |
| `create_test_project(sln_path, framework?, project_name?)` | Crea proyecto xUnit/mstest/nunit |
| `db_query(workspace, sql, max_rows=200, conexion="")` | Consulta de solo-lectura: `SELECT` o CTE (`WITH ... SELECT`); un `WITH` con verbo de escritura (INSERT/UPDATE/DELETE/MERGE) se rechaza. `conexion` = id de `.rs-databases.json`; sin él, la principal. Devuelve `columns[]` (nombres, una sola vez) y `rows[]` (listas de valores en ese orden). Aplica la política PII del workspace (`pii_policy.mode` del modelo BD) y devuelve `pii` con el detalle de lo enmascarado — **el bloque `pii` hay que leerlo y trasladarlo al usuario, ver debajo**. Detalle en `docs/proteccion-pii-consultas-bd.md` |
| `compare_model(workspace, conexion="")` | Diff model.json vs BD real → tablas/columnas nuevas/eliminadas. ⛔ "tabla eliminada" con una cuenta que solo ve por GRANT puede ser una tabla que existe y no se ve: contrastar con la `cobertura` de `sync_from_db` antes de borrar nada del modelo |
| `scan_aspx(sln_path)` | Extrae controles AIS de .aspx → IDs y textos para RIDIOMA/RCONTROLES |
| `log_execution(workspace, solution, task, status?, agents?)` | Registra en executions/history.json |
| `generate_migration(workspace)` | Scripts SQL migración desde drift modelo→BD |
| `svn_log(workspace, solution?, limit?)` | Historial SVN → revisión, autor, fecha, mensaje |
| `git_log(workspace, solution?, limit?)` | Historial Git → hash corto, autor, fecha, mensaje. Equivalente Git de `svn_log` |
| `vcs_delta(workspace, desde, hasta?, ruta?, limit?)` | Delta de commits entre dos fechas (SVN o Git, **autodetectado**) → `commits[]` (rev, autor, fecha, mensaje, `tareas[]` Mantis/Jira citadas), `ficheros[]` con acción y `tareas[]` únicas. `ruta` limita a una subruta (ej. `Batch\Soluciones\RSProcIN`); `hasta` vacío = ahora; `truncado: true` si se alcanzó `limit`. Base de `/rs-actualizador` |
| `find_doc_section(workspace, keyword)` | Localiza sección en docs funcionales y técnicas (para UpdateDocs y la propuesta al manual técnico) |
| `parse_web_log(path, glob="*.log", desde="", niveles="ERROR,FATAL", max_signatures=30, samples=2)` | Parsea un log de errores web (NLog/log4net, ELMAH XML, `rs-cerrores` —el formato propio de la AgendaWeb, `Error: (dd/MM/yyyy H:mm) - Codigo error: … Descripción error: …`— y volcado de stack .NET) y **agrupa por firma** (excepción o **código** `ORA-xxxxx`/`Codigo error` + frame de código propio + mensaje normalizado) → `signatures[]` con `{hash, exception, origin, pantalla, message, count, first_seen, last_seen, files, samples}` ordenado por `count`. `pantalla` es la `.aspx.cs` más cercana del stack (`""` si no hay), para triar sin abrir el código. Devuelve **solo el agregado**, nunca el log completo, y redacta PII en mensajes y muestras —incluidos los literales SQL, donde va el dato que no tiene forma reconocible—. `format_detected` dice qué formato se reconoció; `path` = fichero o carpeta. Base de `/rs-log-errores` |
| `svn_diff_revision(workspace, revisions, max_diff_chars?)` | Diff revisiones SVN filtrado (para rs-validar-req) |
| `git_diff_revision(workspace, revisions, max_diff_chars?, summary_only?)` | Diff de commits Git (hashes) filtrado. Equivalente Git de `svn_diff_revision` |
| `svn_add(workspace, files?)` | Añade ficheros ?: CLI → TortoiseProc → instrucciones manuales |
| `git_add(workspace, files?)` | Añade ficheros ??: CLI → TortoiseGitProc → instrucciones manuales. Equivalente Git de `svn_add` |
| `vcs_revert(workspace, files, dry_run?)` | Revierte una lista **explícita** de ficheros a su estado versionado (SVN/Git autodetectado) o los elimina si son nuevos. `dry_run=True` devuelve el plan sin ejecutar. Para `/rs-deshacer` (previa confirmación humana) |
| `security_scan(sln_path)` | Scan seguridad: SQL injection, XSS, credenciales, input sin validar |
| `sync_model_tables(workspace, tables, conexion="")` | Sincroniza tablas específicas model.json con BD (post-migración). `not_in_db[]` = las que no se leyeron, que puede ser "no existe" o "esta cuenta no la ve"; ninguna se toca |
| `map_dependencies(workspace)` | Mapa dependencias: proyectos compartidos entre soluciones, conflictos NuGet |
| `sync_from_db(workspace, conexion="")` | Sincroniza tablas/columnas del modelo BD desde esquema real de BD → `table_count`, `tablas_leidas`, `no_visibles[]`, `cobertura`, `parcial`. ⛔ Una tabla del modelo que no salga en la lectura **no se borra**: se conserva entera y se marca `visible:false` — con una cuenta que solo ve por GRANT, "no lo veo" es indistinguible de "no existe" |
| `sync_indexes(workspace, conexion="")` | Sincroniza índices desde BD al modelo — preserva source=manual. ⛔ **Solo toca las tablas que la lectura ve**: una tabla sin GRANT conserva sus índices en vez de quedarse a 0. Devuelve `tablas_intactas`, `cobertura`, `parcial` |
| `analyze_dalc(workspace, sln_path?)` | Infiere relaciones entre tablas analizando código DALC |
| `render_erd(workspace)` | Genera ERD HTML y abre navegador — sin cargar modelo en contexto |
| `render_dashboard(workspace)` | Genera dashboard HTML de estadísticas (executions/history.json) y abre navegador — sin cargar el HTML en contexto |
| `render_help(workspace)` | Renderiza el README del plugin a un HTML navegable (guía de usuario) y abre navegador — sin cargar el HTML en contexto |
| `secure_credentials(workspace?, skip_jira?, skip_mantis?)` | Cifra en reposo (DPAPI, cuenta Windows) el password de `.rs-databases.json` (si se da workspace) y los tokens Jira/Mantis de `~/.claude`. Idempotente, no imprime secretos. Para `/rs-cifrar` |
| `render_word(workspace, sources, template?, output?, title?, objeto?, autor?, version?, strip_marks?, open_file?)` | Convierte `.md` del agentic_manual a Word `.docx` sobre una plantilla `.dotx` del workspace. `sources` = ficheros y/o carpetas separados por `;` (el orden es el de los capítulos). Requiere Microsoft Word (COM), sin fallback. Devuelve `{path, pages, tables, warnings}` — sin cargar el documento en contexto |
| `check_env(workspace)` | Valida entorno: .rs-databases.json, AIS, dotnet, SVN, Git, modelo BD → checks[] |
| `check_batch_config(workspace)` | ¿Está centralizada la configuración de los batch (`Batch\App.Batch.config` + `Batch\Directory.Build.targets`)? Solo lectura: clasifica cada proyecto en `centralizable` / `excepcion` (probing privatePath, loadFromRemoteSources — MSBuild no puede autogenerarlos) / `revisar`, y resuelve los HintPath de ODP.NET → `status OK\|NEEDS_ACTION\|BLOCKED`. ⛔ Centralizar **no** es una tool: lo aplica `hooks/batch-centralizar.ps1 -Aplicar` tras confirmación humana. Ver `references/batch-config.md` |
| `generate_sql(workspace, motor?)` | Genera DDL SQL a fichero — devuelve ruta, SQL no entra en contexto |
| `export_dmd(workspace)` | Exporta modelo a Oracle Data Modeler (.dmd) — devuelve ruta |
| `jira_attach(issue_key, files)` | Adjunta ficheros (`.sql`) a una issue de Jira Cloud. files = rutas coma-separadas. Credenciales en `~/.claude/rs-jira-credentials.json`. Usado por la skill `rs-jira` (ver `references/jira.md`) |
| `jira_download(issue_key, file_id, out)` | Descarga un adjunto de una issue de Jira Cloud a `out`. `file_id` = id del adjunto (de `getJiraIssue`). Mismas credenciales que `jira_attach`. Usado por `rs-jira` y por `/rs-actualizador` para recoger los `.sql` de las tareas del rango |

---

## El bloque `cobertura` de las tools de modelo (obligatorio leerlo)

`sync_from_db`, `sync_indexes` y `sync_model_objects` devuelven `cobertura` y `parcial`. **No es
informativo.** Existe porque Oracle **no permite distinguir "no existe" de "no lo veo"**:
ORA-00942 es deliberadamente ambiguo y `ALL_TABLES`, `ALL_OBJECTS` y `ALL_SOURCE` están todas
filtradas por privilegio. Una cuenta que no es dueña del esquema ve solo lo que tiene concedido.

| Campo | Qué significa y qué hay que hacer |
|---|---|
| `parcial: true` | El modelo quedó **incompleto**, no erróneo. ⛔ No leerlo como "esos objetos ya no existen": no se ha borrado nada. Trasladar el hueco al usuario antes de tomar cualquier decisión sobre el modelo |
| `cobertura.es_dueno` | `false` = la cuenta ve por GRANT per-object. Es el **único** caso en que un conteo bajo puede ser falta de permiso. Con `true`, un descuadre es un fallo del script, no de permisos — y así lo dice `cobertura.nota` |
| `cobertura.grants` | GRANTs por privilegio sobre el esquema. **`EXECUTE: 0` explica un 0 de procedimientos y paquetes sin ninguna ambigüedad**: el PL/SQL exige EXECUTE, no SELECT, y sin él `ALL_SOURCE` devuelve cero filas sin error |
| `cobertura.secciones[]` | Por tipo: `real` (diccionario), `capturado`, `excluido` + `motivo` (lo que el script descarta a propósito) y `hueco`. Un hueco es lo que el diccionario ve y no se capturó |
| `no_visibles[]` / `tablas_intactas` | Tablas del modelo que esta lectura no vio. Se **conservan enteras** (columnas, relaciones e índices) y se marcan `visible:false` + `visible_check` |

⛔ Antes de proponer borrar una tabla u objeto del modelo porque "ya no está en la BD", mirar
`cobertura`. Con `es_dueno: false` y hueco, la lectura correcta es "esta cuenta no lo ve". La
salida es conceder el GRANT, o repetir con `conexion=<id de la conexión dueña del esquema>`.

---

## El bloque `pii` de `db_query` (obligatorio leerlo)

`db_query` devuelve siempre un objeto `pii`. **No es informativo: hay que mirarlo y, si trae
alguno de estos campos con contenido, decírselo al usuario en la respuesta.** Ignorarlo en
silencio convierte en nominales los avisos que la medida de protección de datos personales
promete (`docs/proteccion-pii-consultas-bd.md` §4.3 y §5.2c).

| Campo | Qué significa y qué hay que hacer |
|---|---|
| `pii.error` | El filtro no pudo aplicarse. En el camino de hook puede significar que los datos vienen **sin enmascarar** (fallo abierto), o que no vienen filas. **Avisar siempre, literal** |
| `pii.model_error` | El modelo BD declarado en `.rs-databases.json` no se puede usar: no existe, es ilegible, el JSON está corrupto o su raíz no es un objeto. La consulta sale con `success: false` y **cero filas** — no se devuelve nada sin política. Trasladar el mensaje literal: dice qué fichero falta y cómo generarlo (`/rs-init` en un workspace nuevo, `/rs-erd` para sincronizarlo desde la BD) |
| `pii.suspect` | Columnas que salían en claro y cuyos **valores** tienen forma de dato personal (DNI, IBAN, correo, teléfono, tarjeta). La lista de patrones está incompleta. Nombrar las columnas y sugerir `/rs-pii bootstrap` |
| `pii.predicate_warning` | Columnas con datos personales usadas como **filtro** en el `WHERE`. Aunque la salida vaya enmascarada, el valor se puede inferir repitiendo la consulta (§5.2c). Avisar de que esa consulta interroga un dato personal |
| `pii.mode` | `off` = sin protección, `audit` = **los datos salen en claro**, `enforce` = enmascarado activo. No decir "protegido" con `off` ni con `audit` |

⛔ Nunca reproducir el valor de una celda enmascarada ni intentar sortear el filtro (por ejemplo
consultando la misma columna con otra expresión). Si un dato hace falta en claro, la salida es
declarar la columna como segura en el modelo BD (`/rs-pii`), no rodear el filtro.

✅ **Pero el pseudónimo sí se puede usar para correlacionar.** `pii:xxxxxxxx` es determinista
(`HMAC(clave, NOMBRE_COLUMNA + valor)`): el mismo valor da siempre el mismo pseudónimo, en
cualquier consulta y en cualquier tabla. Se pueden unir filas de la misma persona entre tablas,
contar distintos y detectar duplicados sin desenmascarar nada. La condición es que la columna
**vuelva con el mismo nombre** en ambas consultas (si no, alinearlas con un alias). Detalle,
límites y avisos: `references/bd.md` → "Los pseudónimos SÍ se pueden cruzar entre tablas".
