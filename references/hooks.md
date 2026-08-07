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
| `hooks/installer-batch.ps1` | `<workspace> <destino> [-OmitirProcesosExes] [-LimpiarDllConfig]` | **Rebuild** Release (msbuild `/t:Rebuild`, wipe previo de bin/obj) de los csproj-exe de los batch activos (JSON `batch`) → copia EXEs a `<destino>\EXES`. Tres gates bloqueantes: **coherencia** (todos los .exe + DLLs compartidas del mismo build), **binding redirects** y **dependencias ODP.NET**; los dos últimos auditan `<destino>\EXES` **y** `C:\ais\<Proyecto>\Procesos\Exes` |
| `hooks/batch-centralizar.ps1` | `<workspace> [-Aplicar]` | Informa de si la configuración de los batch está centralizada (`Batch\App.Batch.config` + `Batch\Directory.Build.targets`) y con `-Aplicar` la centraliza. Fallback 1:1 de `check_batch_config` **solo en modo informe**: `-Aplicar` escribe en el workspace y exige confirmación humana. Ver `references/batch-config.md` |
| `hooks/installer-agendaweb.ps1` | `<workspace> <destino>` | Publish FileSystem (msbuild `DeployTarget=WebPublish` + `PublishProfile` del JSON) de la Agenda Web → `<destino>\AgendaWeb` |
| `hooks/installer-servicemanager.ps1` | `<workspace> <destino>` | `dotnet publish` host net8 → `<destino>\ServiceManager`; DLL de módulos activos → `\Modulos` |
| `hooks/installer-scripts.ps1` | `<workspace> <destino> [-Solo todo\|ddl\|objetos\|inserts] [-Tablas <lista ;-sep>]` | Llama a `scripts/installer-ddl.py` + `installer-objects.py` + `installer-inserts.py` → `<destino>\Scripts`. El DDL emite los **valores DEFAULT** de columna (campo `default` del modelo). El inventario final lista los **seis** ficheros de objetos y marca `AUSENTE` el que falte (exit 2): antes era un comodín y, si no se generaba ninguno, el resumen salía OK igual. Resuelve la config de BD **una vez** y la pasa por `RS_DB_CONFIG_JSON` (sin password). `-Solo`/`-Tablas` regeneran una parte o unas tablas concretas tras un fallo puntual (`-Tablas` implica `-Solo inserts` y **no** reescribe `Inserts\_run_all.sql`) |
| `hooks/instalacion-paquete.ps1` | `<workspace> <destino> <Instalacion\|Actualizacion> [entorno] [motor] [-Soluciones <lista ;-sep>]` | Copia el paquete de instalación en cliente desde `assets\instalacion\` (`Instalar.ps1`, `Ejecutar-Scripts.ps1` — copia literal, no generada), materializa `rutas.json` (incluidos `bd.autenticacion`/`tnsAdmin`/`schema` para wallet Oracle o autenticación integrada) desde el bloque `entornos` del JSON del proyecto (o plantilla + aviso) y, en modo `Instalacion`, el DDL de `RVERSIONES`, **su fila base por entorno** (`Scripts\PorEntorno\99-RVERSIONES-<E>.sql`, idempotente, motor por entorno; soluciones de `-Soluciones` o deducidas del JSON) y el **manifiesto `Scripts\scripts.json`** con el orden de dependencias (RVERSIONES → secuencias → tablas → vistas → funciones → procedimientos → triggers → sinónimos → inserts → fila base). Sin manifiesto el cliente ordena por nombre y los triggers se lanzan antes que las tablas. Avisa si falta algún fichero de objetos. Compartido por `/rs-instalador` y `/rs-actualizador` |
| `hooks/actualizador-build.ps1` | `<workspace> <destino> <manifiesto.json>` | Actualizador: Rebuild de las **soluciones batch afectadas** → `<destino>\Exes` (mismo gate de coherencia que `installer-batch`), AgendaWeb **completa** (delega en `installer-agendaweb.ps1`), DLL recién compiladas de los módulos afectados → `<destino>\ServiceManager\Modulos`, y **exclusión de la configuración funcional del cliente** (`web.config`, `<proceso>.xml` de cada batch, `appsettings*.json`, wildcards de `excluirEntrega`); los `*.config` del binario sí viajan. El `<proceso>.xml` se identifica por coincidencia de nombre con un `.exe` **o** por declaración en `batch_config` del JSON del proyecto — hace falta lo segundo porque algunos procesos reciben la ruta de su XML por línea de comandos y el nombre no coincide |

Scripts Python asociados: `scripts/installer-ddl.py` (DDL sin schema desde `model.json`, sin BD),
`scripts/installer-objects.py` (secuencias/vistas/funciones/procs/triggers/sinónimos desde la BD
viva, los 6 tipos **en paralelo**) y `scripts/installer-inserts.py` (inserts por tabla paramétrica
desde `subviews["Parametricas"]`, **agrupando tablas por sesión SQL** — el coste está en el login,
no en la consulta). Cap común de sesiones simultáneas: `parametricas.max_paralelo` del
`docs\<proyecto>-instalador.json` (default 8).

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
  ⛔ **Un gate que no puede evaluar no reporta OK**: XML ilegible, `SelectNodes` roto o versión de DLL
  no leíble → `exit 1`, no un AVISO que se salta la comprobación. Única excepción, `BadImageFormatException`:
  el fichero no es un assembly gestionado, así que ese redirect no le aplica.
  ⛔ Audita **dos carpetas**, no una: `<destino>\EXES` (la que produce la ejecución) y
  `C:\ais\<Proyecto>\Procesos\Exes` (la carpeta viva que escribe `batch-build.ps1`). Ambas son
  compartidas y ambas sufren last-writer-wins; auditar solo la primera dejaba pasar el desalineo de
  la segunda, que es donde los procesos corren de verdad. `-OmitirProcesosExes` la excluye.
  Tercer gate (dependencias ODP.NET): si `Oracle.ManagedDataAccess.dll` está desplegado, exige la
  presencia física de sus satélites (`System.Text.Json`, `System.Diagnostics.DiagnosticSource`,
  `System.Text.Encodings.Web`, `System.Collections.Immutable`, `System.IO.Pipelines`,
  `System.Formats.Asn1`, `Microsoft.Bcl.AsyncInterfaces`; override por JSON `odpDependencies`).
  `Comun.dll` no las referencia en su IL — las usa `Oracle.ManagedDataAccess.dll` —, así que MSBuild
  sigue la cadena, no encuentra la versión en `packages` y **descarta la referencia sin warning**: el
  proceso arranca y muere en el primer acceso a BD con un `TypeInitializationException` de
  `OracleCommand`. Ver `references/batch-config.md`.
  Además avisa de los `*.dll.config` huérfanos (la configuración centralizada ya no los genera) y con
  `-LimpiarDllConfig` los barre; y avisa —sin bloquear— si el workspace aún no está centralizado.
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
| `hooks/db-query.ps1` | `-Workspace <ws> -Sql "<SELECT\|WITH...SELECT>" [-MaxRows 200] [-Conexion <id>]` | Consulta solo-lectura (SELECT o CTE WITH...SELECT; WITH con verbo de escritura se rechaza) contra una BD de .rs-databases.json (`-Conexion <id>`, default principal; solo Oracle) (equivalente a `db_query`). Aplica la política PII vía `scripts/pii_cli.py` (con el `model_path` de la conexión seleccionada) y devuelve `columns`/`rows`/`pii` igual que la tool MCP. Falla **abierto** solo si el filtro no se puede ni ejecutar (sin `python` o sin el fichero): datos sin tocar + `pii.error`. Si el filtro corre y falla, falla **cerrado**: `success: false`, `pii.error` y **cero filas** |
| `hooks/lib-dbmodel.ps1` | (librería, no se invoca sola) | Lo que le falta a una columna de `model.json` al reconstruirla desde la BD, en dos huecos opuestos. `Get-RsColumnDefaults` / `ConvertTo-RsDefaultsMap`: lo que la BD **sí** sabe y el SELECT principal no puede traer — el valor DEFAULT, como mapa `TABLA.COLUMNA` → expresión. Pasada aparte porque en Oracle `DATA_DEFAULT` es **LONG** (no se concatena ni se limpia en SQL): se lee en un bloque PL/SQL con `DBMS_OUTPUT`. Descarta identidades (`ISEQ$$`), columnas virtuales/ocultas y `DEFAULT NULL`; no lanza. `New-RsColumnaModelo` / `ConvertTo-RsPkPosicion`: construye la columna del modelo con la **posición dentro de la PK** (ordinal, siempre — mezclar ordinal y booleano en una tabla ordena la clave al revés) y conserva lo que la BD **no** sabe y por tanto no puede volver a decir — `description` y las marcas manuales `pii`/`safe`. Los hooks tiran la columna y la reescriben entera, así que lo que no se copie aquí se pierde. La preservación va por **presencia** de la propiedad, nunca por su verdad: `safe: false` equivale a `pii: true` y una comprobación por verdad borraría justo la marca más restrictiva |
| `hooks/lib-dbconfig.ps1` | (librería, no se invoca sola) | Lectura/validación de `.rs-databases.json` y parseo de cadenas de conexión — usada internamente por `get-config.ps1`, `db-query.ps1`, `check-env.ps1`. Dot-sourcea `lib-crypto.ps1` para descifrar el password |
| `hooks/lib-deploy-gates.ps1` | (librería, no se invoca sola) | Gates de una carpeta de despliegue batch: `Test-RsCoherenciaBuild`, `Test-RsBindingRedirects`, `Test-RsOdpDependencies`, `Get-RsDllConfigHuerfanos`. **Deciden y devuelven; no imprimen ni hacen `exit`** — eso se queda en `installer-batch.ps1`, que es quien sabe qué es bloqueante en su flujo. Viven aparte porque soldados dentro del hook no eran ejecutables sin msbuild + workspace de cliente, y por eso ninguno estaba probado (ver CHANGELOG 3.7.1). Suite: `tests/DeployGates.Tests.ps1` |
| `hooks/lib-crypto.ps1` | (librería, no se invoca sola) | Cifrado en reposo de secretos con DPAPI: `Protect-RsSecret`/`Unprotect-RsSecret`/`Test-RsEncrypted` (formato `enc:<base64>`; valor sin prefijo = texto plano legacy). Paridad con `_unprotect_secret` (Python) |
| `hooks/secure-credentials.ps1` | `[-Workspace <ws>] [-SkipJira] [-SkipMantis]` | Cifra in situ (DPAPI) el password de `.rs-databases.json` + tokens Jira/Mantis de `~/.claude`. Idempotente, no imprime secretos → `{changed[], skipped[], errors[]}`. Fallback 1:1 de `secure_credentials` |
| `hooks/convert-config.ps1` | `<workspace> [-Force]` | `XMLConfig.xml` → `.rs-databases.json`. Uso único por workspace; no borra el XML |
| `hooks/compare-model.ps1` | `<workspace>` | Drift model.json vs esquema real BD |
| `hooks/generate-migration.ps1` | `<workspace>` | Scripts SQL (CREATE TABLE / ALTER TABLE ADD) desde drift |
| `hooks/sync-model-objects.ps1` | `<workspace> [<proyecto>] [-DryRun]` | Sincroniza a `model.json` el **inventario de objetos de BD** (vistas, procedimientos, paquetes, funciones, triggers, sinónimos, secuencias): ficha + **firma** del cuerpo, nunca el cuerpo. Reutiliza los extractores de `installer-objects.py`, así que no duplica consultas y la firma se calcula sobre el mismo texto que emitiría el instalador. `-DryRun` lista el inventario y el diff sin escribir. exit 2 = algún tipo falló; su sección se **conserva** del modelo anterior en vez de vaciarse |
| `hooks/sync-from-db.ps1` | `<workspace> <proyecto>` | Sincroniza tablas/columnas desde BD real → `table_count`, `defaults` (escritura atómica). Captura el **valor DEFAULT** de cada columna (campo `default`) y la **posición real dentro de la PK** (campo `pk` como ordinal), y **preserva `description` y las marcas manuales `pii`/`safe`** (vía `lib-dbmodel.ps1`), que antes se borraban en cada sync |
| `hooks/sync-model-tables.ps1` | `<workspace> <tablas-coma-separadas>` | Actualiza tablas específicas de model.json post-migración, incluidos los `default` de columna y la posición dentro de la PK, y preservando `description`/`pii`/`safe` |
| `hooks/sync-indexes.ps1` | `<workspace> [-Proyecto <nombre>]` | Sincroniza índices desde BD al modelo — preserva source=manual |
| `hooks/analyze-dalc.ps1` | `<workspace> <proyecto> [-SolutionPath <sln>]` | Infiere relaciones desde JOINs/WHERE en DALCs |
| `hooks/render-erd.ps1` | `<workspace> [-Proyecto <nombre>]` | Genera ERD HTML y lo abre en navegador → `{path, table_count}` |
| `hooks/render-dashboard.ps1` | `<workspace>` | Genera dashboard HTML de estadísticas (executions/history.json) y lo abre → `{path, opened}`. Fallback 1:1 de `render_dashboard` |
| `hooks/render-help.ps1` | `<workspace>` | Renderiza el README del plugin a un HTML navegable (guía de usuario) y lo abre → `{path, opened}`. Fallback 1:1 de `render_help` |
| `hooks/render-word.ps1` | `<workspace> -Sources <a.md;carpeta;...> [-Template <x.dotx>] [-Output <y.docx>] [-Title <t>] [-Objeto <o>] [-Autor <a>] [-Version <v>] [-StripMarks] [-Open]` | Convierte Markdown a Word `.docx` sobre una plantilla `.dotx` (Word COM) → `{path, pages, tables, sources, template, warnings}`. Fallback 1:1 de `render_word` |
| `hooks/generate-sql.ps1` | `<workspace> [-Proyecto <nombre>] [-Motor ORACLE\|SQLSERVER]` | Genera DDL SQL → `C:\AIS\<proyecto-lowercase>\scripts\<proyecto>-ddl-<motor>.sql` |
| `hooks/export-dmd.ps1` | `<workspace> [-Proyecto <nombre>]` | Exporta a Oracle Data Modeler `.dmd` |

## Protección de datos personales (PII)

Guardas `PreToolUse` — no son fallback de una tool MCP. Desde 3.4.0 las declara
`.claude-plugin/plugin.json` con `${CLAUDE_PLUGIN_ROOT}`: se instalan y actualizan con el plugin,
y **ya no se registran a mano**. En `~/.claude/settings.json` la ruta iba en absoluto y la del
caché lleva la versión del plugin, así que cada actualización las dejaba apuntando a un
directorio inexistente — fallando abiertas y sin avisar. Los restos los retira
`scripts/cleanup-preplugin.ps1` al arrancar la sesión. Ver `docs/proteccion-pii-consultas-bd.md`.

| Script | Parámetros | Descripción |
|--------|-----------|-------------|
| `hooks/pii-guard-bash.ps1` | (stdin: evento PreToolUse) | Guarda PreToolUse sobre `Bash`: bloquea `sqlplus`/`sqlcmd`/`osql`/`bcp`/`sqlldr`/`impdp`/`expdp` invocados directamente. **Guardarraíl, no control** — se elude con un script intermedio o invocando el binario por otra ruta; el control real es la credencial de BD (§3.1/§5.2b del documento). Declarada en `.claude-plugin/plugin.json`. **Solo actúa** si el workspace del `cwd` está en `audit`/`enforce` (§4.4) |
| `hooks/pii-guard-write.ps1` | (stdin: evento PreToolUse) | Guarda PreToolUse sobre `Write`/`Edit`: bloquea contenido con forma de DNI/NIE (con letra de control válida), IBAN o correo. Teléfono y tarjeta quedan fuera **a propósito** — son puramente numéricos y casarían con cualquier importe o identificador de fila largo, y una guarda que salta a diario se acaba desactivando. Excluye rutas `Instalador\` y `Actualizador\` (el volcado de datos reales es el propósito de esos ficheros). **Solo actúa** si el workspace **del fichero que se va a escribir** está en `audit`/`enforce` — no el de la sesión |
| `Get-RsPiiEstadoGuarda` (en `lib-pii.ps1`) | `-Desde <ruta>` | ¿Debe actuar la guarda sobre una operación que nace en esa ruta? → `@{activa; modo; motivo; workspace}`. Fuera de un workspace RS y en `off`, no; en `audit`/`enforce`, sí; con el modo **indeterminado** (política declarada que no se puede leer), **sí** — un workspace roto no degrada a uno sin protección. Con varias conexiones manda la más restrictiva: la guarda de Bash no sabe a qué BD apunta un comando |
| `hooks/lib-pii.ps1` | (librería, no se invoca sola) | Patrones DNI/NIE/IBAN/correo y el validador de letra de control (`Test-DniNieChecksum`), compartidos por `pii-guard-write.ps1` y `log-execution.ps1` — mismo patrón que `hooks/lib-dbconfig.ps1`. Deliberadamente **no** usa `scripts/pii_detect.py`: mantiene un subconjunto de formas distinto (sin teléfono ni tarjeta) porque aquí el texto inspeccionado no es un resultset de BD. Aloja además `Test-RsPiiGuards`, que usa `check-env.ps1` |
| `Test-RsPiiGuards` (en `lib-pii.ps1`) | `-SettingsPath <json> [-HooksDir <dir>] [-ManifestPath <plugin.json>]` | ¿Están las dos guardas disponibles **y existe el `.ps1` al que apuntan**? → `@{bash; write; ok; missing; stale; foreign; legacy; source}`. Fuente preferente el manifiesto del plugin; `settings.json` se mira para listar en `legacy` los restos manuales (vivos o muertos), que ya sobran. Declarada ≠ efectiva: una entrada rota falla sin código 2, así que no bloquea. `-HooksDir` marca en `foreign` las guardas vivas que cuelgan de otra copia del plugin |
| `scripts/pii_cli.py` | `<workspace> [<model_path>]` (stdin: `{columns,rows,sql}`) — o `--clasificar <model_path> [--tablas T1,T2] [--todo] [--max N]` | Envoltorio CLI de `scripts/pii_mask.py`: aplica la política PII completa (las seis formas) a un resultset. Lo usa `hooks/db-query.ps1` porque PowerShell no puede importar un módulo Python; la tool MCP `db_query` importa `pii_mask` directamente. **No busca el modelo**: la ruta se la pasa el llamante (`Get-RsModelPath` de `hooks/lib-dbconfig.ps1`, la misma que resuelve `get-config.ps1` → `model_path`). Salida != 0 = el filtro corrió y no pudo aplicar la política (2 uso, 3 modelo, 10 interno) → el llamante no debe devolver filas. El modo `--clasificar` devuelve el veredicto/motivo determinista por columna para `/rs-pii` |

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
| `hooks/vcs-delta.ps1` | `<workspace> -Desde <yyyy-MM-dd> [-Hasta <fecha>] [-Ruta <subruta>] [-Limit 500]` | Delta de commits entre dos fechas, **autodetectando SVN/Git** (reutiliza `detect-vcs.ps1`) → commits con IDs de tarea Mantis/Jira, ficheros tocados con acción y lista única de tareas. Fallback 1:1 de `vcs_delta` |
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
