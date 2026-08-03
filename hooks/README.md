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
| `installer-batch.ps1 <workspace> <destino>` | Rebuild Release de los batch activos → `<destino>\EXES` + gate de coherencia |
| `installer-agendaweb.ps1 <workspace> <destino>` | Publish FileSystem de la Agenda Web → `<destino>\AgendaWeb` |
| `installer-servicemanager.ps1 <workspace> <destino>` | `dotnet publish` host net8 + DLL de módulos → `<destino>\ServiceManager[\Modulos]` |
| `installer-scripts.ps1 <workspace> <destino>` | DDL + objetos + inserts paramétricas → `<destino>\Scripts` |
| `actualizador-build.ps1 <workspace> <destino> <manifiesto.json>` | Delta: batch afectados + AgendaWeb completa + DLL de módulos afectados; excluye la config funcional del cliente (`web.config`, `<proceso>.xml`, `appsettings*.json`) y conserva los `*.config` del binario |
| `instalacion-paquete.ps1 <workspace> <destino> <Instalacion\|Actualizacion> [entorno] [motor] [-Soluciones <;-sep>]` | `Instalar.ps1` + `Ejecutar-Scripts.ps1` + `rutas.json` + `readme.txt` (plantillas de `assets\instalacion\`); en `Instalacion`, además el DDL de `RVERSIONES` y `Scripts\PorEntorno\99-RVERSIONES-<E>.sql` por entorno |

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
Guardas `PreToolUse` — no son fallback de una tool MCP, se registran directamente en la config
personal del usuario (`~/.claude/settings.json`) solo tras `/rs-pii enforce`. Ver
`docs/proteccion-pii-consultas-bd.md`.

| Script | Uso |
|--------|-----|
| `pii-guard-bash.ps1` (stdin: evento PreToolUse) | Bloquea sobre `Bash` la invocación directa de `sqlplus`/`sqlcmd`/`osql`/`bcp`/`sqlldr`/`impdp`/`expdp`. **Guardarraíl, no control** — se elude con un script intermedio o invocando el binario por otra ruta |
| `pii-guard-write.ps1` (stdin: evento PreToolUse) | Bloquea sobre `Write`/`Edit` contenido con forma de DNI/NIE (letra de control válida), IBAN o correo. Teléfono y tarjeta quedan fuera a propósito — casarían con cualquier importe o identificador de fila largo. Excluye `Instalador\`/`Actualizador\` |
| `lib-pii.ps1` | Librería, no se invoca directamente — dot-sourcear desde el hook que la necesite (`Test-DniNieChecksum`, `Remove-RsPii`, patrones DNI/NIE/IBAN/correo). Compartida por `pii-guard-write.ps1` y `log-execution.ps1`, mismo patrón que `lib-dbconfig.ps1` |

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

### Jira
| Script | Uso |
|--------|-----|
| `jira-attach.ps1 -IssueKey <KEY> -Files "<ruta1,ruta2>"` | Adjunta ficheros a una issue de Jira Cloud. Credenciales en `~/.claude/rs-jira-credentials.json`; nunca imprime el token. Ver `references/jira.md` |

## Convención de codificación (obligatoria)

Los `.ps1` de este plugin se guardan en **UTF-8 con BOM**. Windows PowerShell 5.1 —el intérprete que
usan `plugin.json` y `runner/runner.ps1` (`powershell -File ...`)— asume la codepage ANSI del sistema
cuando no hay BOM: los acentos y los guiones largos se decodifican mal y el script **ni siquiera
parsea** (`Falta la cadena en el terminador: "`, `Falta el nombre de tipo después de '['`). Pasó en
real con los 4 hooks del instalador. Guardar sin BOM o quitarlo vuelve a romperlos.

Comprobación rápida de todos los hooks bajo 5.1:

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
