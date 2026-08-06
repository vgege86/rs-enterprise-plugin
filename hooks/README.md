# RS Enterprise Agent — Hooks

Scripts PowerShell ejecutados por el agente vía MCP o directamente como fallback.

## Registro MCP (preferente)

`mcp/rs-workspace-server.py` expone todos los hooks como tools MCP.
Registrado automáticamente por el plugin vía `.mcp.json` (raíz del repo) → ver README.md raíz.

## Registro hook Stop (build/publish) y UserPromptSubmit (skill-trigger)

Registrados automáticamente por el plugin vía `.claude-plugin/plugin.json` (raíz del repo), usando `${CLAUDE_PLUGIN_ROOT}` — no requiere configuración manual. Referencia de la forma que toma cada entrada:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "powershell -ExecutionPolicy Bypass -File \"${CLAUDE_PLUGIN_ROOT}/runner/runner.ps1\"", "timeout": 120, "statusMessage": "RS Runner..." } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "powershell -ExecutionPolicy Bypass -File \"${CLAUDE_PLUGIN_ROOT}/hooks/skill-trigger.ps1\"", "timeout": 10, "statusMessage": "RS skill trigger..." } ] }
    ]
  }
}
```

## Scripts disponibles

### Build / Deploy
| Script | Uso |
|--------|-----|
| `batch-build.ps1 <Solution> <workspace>` | Build Debug+Release + copia a AIS |
| `online-publish.ps1 <Solution> <workspace> <profile>` | Build + publish Online con msbuild |
| `service-build.ps1 <slnPath> <workspace>` | Build de servicio Windows (tipo=Servicio): código MSBuild + instalador .vdproj con devenv. No copia a AIS |
| `copy-ais.ps1 <source> <workspace>` | Copia bin/Release completo a AIS |

### Entregas a cliente (instalador / actualizador)
Se lanzan vía `runner/runner.ps1` (`TYPE: INSTALLER`), no tienen tool MCP.
Convenciones de entrega y modelo de `RVERSIONES`: `references/actualizador.md`.

| Script | Uso |
|--------|-----|
| `installer-batch.ps1 <workspace> <destino> [-OmitirProcesosExes] [-LimpiarDllConfig]` | Rebuild Release de los batch activos → `<destino>\EXES` + tres gates: coherencia, binding redirects y dependencias ODP.NET. Los dos últimos auditan también `C:\ais\<Proyecto>\Procesos\Exes` (`-OmitirProcesosExes` la excluye) |
| `batch-centralizar.ps1 <workspace> [-Aplicar]` | Informe (JSON, no escribe) de si la configuración de los batch está centralizada — `Batch\App.Batch.config` + `Batch\Directory.Build.targets` — y con `-Aplicar` la centraliza. Convención: `references/batch-config.md`. Tool MCP equivalente **solo del informe**: `check_batch_config` |
| `installer-agendaweb.ps1 <workspace> <destino>` | Publish FileSystem de la Agenda Web → `<destino>\AgendaWeb` |
| `installer-servicemanager.ps1 <workspace> <destino>` | `dotnet publish` host net8 + DLL de módulos → `<destino>\ServiceManager[\Modulos]` |
| `installer-scripts.ps1 <workspace> <destino> [-Solo todo\|ddl\|objetos\|inserts] [-Tablas <;-sep>]` | DDL + objetos + inserts paramétricas → `<destino>\Scripts`. Config de BD resuelta una vez (`RS_DB_CONFIG_JSON`, sin password); `-Solo`/`-Tablas` para regenerar solo una parte tras un fallo puntual |
| `actualizador-build.ps1 <workspace> <destino> <manifiesto.json>` | Delta: batch afectados + AgendaWeb completa + DLL de módulos afectados; excluye la config funcional del cliente (`web.config`, `<proceso>.xml`, `appsettings*.json`) y conserva los `*.config` del binario. El `<proceso>.xml` sale por nombre coincidente con un `.exe` **o** por declaración en `batch_config` del JSON (procesos que reciben la ruta de su XML por línea de comandos) |
| `instalacion-paquete.ps1 <workspace> <destino> <Instalacion\|Actualizacion> [entorno] [motor] [-Soluciones <;-sep>]` | `Instalar.ps1` + `Ejecutar-Scripts.ps1` + `rutas.json` + `readme.txt` (plantillas de `assets\instalacion\`); en `Instalacion`, además el DDL de `RVERSIONES` y `Scripts\PorEntorno\99-RVERSIONES-<E>.sql` por entorno. ⛔ `scripts.json.tpl` **no** se copia: es la referencia del formato del manifiesto, lo escribe `/rs-actualizador` con nombres reales |

### Análisis y scope
| Script | Uso |
|--------|-----|
| `validate-solution.ps1 <path>` | Verifica que existe la .sln |
| `parse-sln.ps1 <sln>` | Parsea .sln → scope_dirs, tipo, workspace |
| `find-symbol.ps1 <nombre> <scope_dirs>` | Localiza clase/método/propiedad → archivo:línea |
| `compile-check.ps1 <sln> [-NoRestore]` | dotnet build → errors[], warnings[], success |
| `test-runner-check.ps1 <sln> [-NoBuild]` | dotnet test → has_test_project (bool), passed/failed/failures[], skipped (conteo). Sin proyecto → solo has_test_project=false |
| `create-test-project.ps1 <sln> [-Framework xunit\|mstest\|nunit]` | Crea proyecto de test |
| `scan-aspx.ps1 -SlnPath <sln>` | Extrae controles AIS de .aspx |
| `security-scan.ps1 <sln_path>` | SQL injection, XSS, credenciales hardcodeadas, input sin validar |
| `map-dependencies.ps1 <workspace>` | Proyectos compartidos entre soluciones, conflictos NuGet |

### BD / Modelo
| Script | Uso |
|--------|-----|
| `get-config.ps1 <workspace>` | Lee .rs-databases.json → motor, datasource, schema, conexiones[], motores[] |
| `lib-dbconfig.ps1` | Librería, no se invoca directamente — dot-sourcear desde el hook que la necesite (`Get-CsPart`, `Read-RsDatabases`, `Resolve-RsWorkspace`, `Get-RsProyecto`) |
| `lib-deploy-gates.ps1` | Librería, no se invoca directamente — gates de carpeta de despliegue batch (`Test-RsCoherenciaBuild`, `Test-RsBindingRedirects`, `Test-RsOdpDependencies`, `Get-RsDllConfigHuerfanos`). Deciden y devuelven; los `Write-Host` y los `exit` se quedan en `installer-batch.ps1`. Mismo patrón que `lib-dbconfig.ps1` |
| `convert-config.ps1 <workspace> [-Force]` | Convierte `XMLConfig.xml` → `.rs-databases.json`. No borra el XML |
| `sync-from-db.ps1 <workspace>` | Sincroniza modelo completo desde BD |
| `compare-model.ps1 <workspace>` | Diff model.json vs esquema real BD |
| `generate-migration.ps1 <workspace>` | CREATE TABLE / ALTER TABLE ADD desde drift modelo→BD |
| `sync-model-tables.ps1 <workspace> <tablas>` | Actualiza tablas específicas model.json (post-migración) |
| `analyze-dalc.ps1 <workspace>` | Infiere relaciones entre tablas desde código DALC |
| `generate-sql.ps1 <workspace>` | DDL Oracle o SQL Server desde modelo JSON → `C:\AIS\<proyecto-lowercase>\scripts\` |
| `render-erd.ps1 <workspace>` | HTML ERD interactivo |
| `export-dmd.ps1 <workspace>` | Export a Oracle Data Modeler (.dmd) |

### Protección de datos personales (PII)
Guardas `PreToolUse` — no son fallback de una tool MCP. Desde 3.4.0 las declara
`.claude-plugin/plugin.json` con `${CLAUDE_PLUGIN_ROOT}`, así que se instalan y actualizan con el
plugin; **ya no se registran a mano** en `~/.claude/settings.json` (ahí la ruta iba en absoluto y la
del caché lleva la versión: cada actualización las dejaba muertas). Los restos manuales los retira
`scripts/cleanup-preplugin.ps1` al arrancar la sesión. Ver `docs/proteccion-pii-consultas-bd.md`.

| Script | Uso |
|--------|-----|
| `pii-guard-bash.ps1` (stdin: evento PreToolUse) | Bloquea sobre `Bash` la invocación directa de `sqlplus`/`sqlcmd`/`osql`/`bcp`/`sqlldr`/`impdp`/`expdp`. **Guardarraíl, no control** — se elude con un script intermedio o invocando el binario por otra ruta. Solo actúa si el workspace del `cwd` está en `audit`/`enforce` |
| `pii-guard-write.ps1` (stdin: evento PreToolUse) | Bloquea sobre `Write`/`Edit` contenido con forma de DNI/NIE (letra de control válida), IBAN o correo. Teléfono y tarjeta quedan fuera a propósito — casarían con cualquier importe o identificador de fila largo. Excluye `Instalador\`/`Actualizador\`. Solo actúa si el workspace **del fichero** está en `audit`/`enforce` |
| `Get-RsPiiEstadoGuarda` (en `lib-pii.ps1`) | `-Desde <ruta>` → `@{activa; modo; motivo; workspace}`. Las guardas siguen al modo del workspace: fuera de un workspace RS y en `off` no actúan; en `audit`/`enforce` sí; y en un workspace cuyo modo **no se puede determinar** también, para que uno roto no degrade a uno sin protección. Con varias conexiones manda la más restrictiva. Lee el modo con `Get-RsPiiModoDeModelo` (regex, no `ConvertFrom-Json`: esto corre en cada `Bash` y cada `Write`) |
| `lib-pii.ps1` | Librería, no se invoca directamente — dot-sourcear desde el hook que la necesite (`Test-DniNieChecksum`, `Remove-RsPii`, patrones DNI/NIE/IBAN/correo, `Test-RsPiiGuards`). Compartida por `pii-guard-write.ps1`, `log-execution.ps1` y `check-env.ps1`, mismo patrón que `lib-dbconfig.ps1` |
| `Test-RsPiiGuards` (en `lib-pii.ps1`) | ¿Están las dos guardas disponibles **y existe el `.ps1` al que apuntan**? → `@{bash; write; ok; missing; stale; foreign; legacy; source}`. Fuente preferente `-ManifestPath` (el `plugin.json` del plugin); el `settings.json` personal se mira solo para listar en `legacy` los restos manuales, que ya sobran. Declarada ≠ efectiva: una entrada que apunte a una ruta muerta falla sin código 2 — no bloquea nada. `-HooksDir` marca en `foreign` las que cuelgan de otra copia del plugin |

### SVN
| Script | Uso |
|--------|-----|
| `svn-diff.ps1 <workspace>` | Estado SVN del workspace → JSON (incluye ficheros ? sin versionar) |
| `svn-diff-revision.ps1 <workspace> <revisions>` | Diff de revisiones específicas → combined_diff filtrado |
| `svn-log.ps1 <workspace> [-Solution <nombre>] [-Limit 10]` | Historial commits → JSON |
| `vcs-delta.ps1 <workspace> -Desde <fecha> [-Hasta <fecha>] [-Ruta <subruta>] [-Limit 500]` | Delta de commits entre dos fechas (SVN o Git, autodetectado) → commits + tareas Mantis/Jira + ficheros tocados |
| `svn-add.ps1 <workspace> [-Files <lista>]` | Añade ficheros ?: CLI → TortoiseProc → instrucciones manuales |

### Entorno y logging
| Script | Uso |
|--------|-----|
| `check-env.ps1 <workspace>` | Valida .rs-databases.json, AIS, dotnet, SVN, modelo BD → JSON |
| `log-execution.ps1 <workspace> <sln> <task> [-Status]` | Registra ejecución en executions/history.json |
| `find-doc-section.ps1 <workspace> <keyword>` | Busca sección en docs funcionales para UpdateDocs |
| `render-dashboard.ps1 <workspace>` | HTML de estadísticas del pipeline (executions/history.json) → lo abre en navegador |
| `render-help.ps1 <workspace>` | Renderiza el README del plugin a un HTML navegable (guía de usuario) → lo abre en navegador |
| `render-word.ps1 <workspace> -Sources <a.md;carpeta> [-Template <x.dotx>] [-Output <y.docx>] [-Title <t>] [-Objeto <o>] [-Autor <a>] [-StripMarks] [-Open]` | Convierte Markdown del agentic_manual a Word `.docx` sobre la plantilla `.dotx` del workspace (requiere Word por COM) |

### Jira
| Script | Uso |
|--------|-----|
| `jira-attach.ps1 -IssueKey <KEY> -Files "<ruta1,ruta2>"` | Adjunta ficheros a una issue de Jira Cloud. Credenciales en `~/.claude/rs-jira-credentials.json`; nunca imprime el token. Ver `references/jira.md` |

## Convención de codificación (obligatoria)

Los `.ps1` de este plugin se guardan en **UTF-8 con BOM**. Windows PowerShell 5.1 —el intérprete que
usan `plugin.json` y `runner/runner.ps1` (`powershell -File ...`)— asume la codepage ANSI del sistema
cuando no hay BOM: los acentos y los guiones largos se decodifican mal y el script **ni siquiera
parsea** (`Falta la cadena en el terminador: "`, `Falta el nombre de tipo después de '['`,
`Token '$(' inesperado en la expresión o la instrucción`). Guardar sin BOM o quitarlo vuelve a
romperlos.

Ha pasado dos veces: con los 4 hooks del instalador, y en la 3.4.5 con `lib-pii.ps1`,
`installer-batch.ps1` y `vcs-revert.ps1` (ver CHANGELOG 3.4.6). Que esté escrito aquí no basta,
porque la causa es mecánica: **los editores y las herramientas de escritura automática guardan
UTF-8 sin BOM por defecto**. Tras crear o reescribir un `.ps1` entero, comprueba el BOM antes de
darlo por bueno.

⛔ Desde la 3.4.6 lo verifica `tests/Encoding.Tests.ps1` sobre todos los `.ps1` del repo (BOM +
UTF-8 estricto + parseo). Es el gate; esta sección solo explica el porqué.

```powershell
Invoke-Pester tests/Encoding.Tests.ps1
```

## `Join-Path` con dos argumentos, nunca tres (obligatoria)

El tercer posicional de `Join-Path` es `-AdditionalChildPath`, que **existe desde PowerShell 6**. En
5.1 no encaja en ningún parámetro y la llamada falla:

```powershell
Join-Path $base ".." "hooks" "x.ps1"   # ⛔ solo PS 7
Join-Path $base "../hooks/x.ps1"       # ✅ 5.1 y 7, Windows y Linux
```

La barra `/` funciona como separador en los dos sistemas, así que es la forma portable. Este fallo
es de **ejecución, no de sintaxis**: el parser no lo detecta, por eso lo comprueba
`tests/Encoding.Tests.ps1` aparte. Llevaba 35 apariciones en la suite dando 132 fallos que parecían
de código (CHANGELOG 3.5.1).

## `$IsWindows` no existe en 5.1

Es variable de PowerShell Core; en 5.1 vale `$null`. Un `-not $IsWindows` da `$true` y **salta el
bloque justo en Windows**. Comprobar siempre contra el `$false` explícito:

```powershell
if (-not $IsWindows) { ... }        # ⛔ se cumple en 5.1-Windows
if ($IsWindows -eq $false) { ... }  # ✅ solo PS Core fuera de Windows
```

## Ejecutar la suite

Con los dos intérpretes, porque prueban cosas distintas: `powershell` es el que lanza los hooks en
producción, `pwsh` es el del CI.

```powershell
powershell -NoProfile -Command "Invoke-Pester tests"   # 5.1: 3 skipped documentados
pwsh       -NoProfile -Command "Invoke-Pester tests"   # 7:   todo en verde
```

Comprobación rápida de todos los hooks bajo 5.1, sin Pester:

```powershell
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e) > $null
    if ($e.Count) { "$($_.Name): $($e[0].Message)" }
}
```

## Requisitos

- PowerShell 5.1+
- dotnet CLI en PATH (para compile-check y test-runner-check)
- TortoiseProc en `C:\Program Files\TortoiseSVN\bin\` (para svn-add nivel 2)
- sqlcmd (SQL Server) o sqlplus (Oracle) para db_query
