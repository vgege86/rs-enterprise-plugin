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
| `copy-ais.ps1 <source> <workspace>` | Copia bin/Release completo a AIS |

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

### SVN
| Script | Uso |
|--------|-----|
| `svn-diff.ps1 <workspace>` | Estado SVN del workspace → JSON (incluye ficheros ? sin versionar) |
| `svn-diff-revision.ps1 <workspace> <revisions>` | Diff de revisiones específicas → combined_diff filtrado |
| `svn-log.ps1 <workspace> [-Solution <nombre>] [-Limit 10]` | Historial commits → JSON |
| `svn-add.ps1 <workspace> [-Files <lista>]` | Añade ficheros ?: CLI → TortoiseProc → instrucciones manuales |

### Entorno y logging
| Script | Uso |
|--------|-----|
| `check-env.ps1 <workspace>` | Valida .rs-databases.json, AIS, dotnet, SVN, modelo BD → JSON |
| `log-execution.ps1 <workspace> <sln> <task> [-Status]` | Registra ejecución en executions/history.json |
| `find-doc-section.ps1 <workspace> <keyword>` | Busca sección en docs funcionales para UpdateDocs |

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
