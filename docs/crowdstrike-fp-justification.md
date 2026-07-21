# CrowdStrike Falcon — Justificación de falso positivo (plugin rs-enterprise-agent)

**Para:** equipo de IT / Seguridad que gestiona CrowdStrike Falcon
**Asunto:** detección conductual (posible cuarentena/bloqueo) sobre el servidor MCP del plugin
**Fecha:** 2026-07-16

## Resumen

CrowdStrike marcó "virus detectado" al ejecutar la herramienta `ping` del servidor MCP
`rs-workspace` (plugin de desarrollo interno para Claude Code). El proceso quedó bloqueado/colgado.
Tras revisión del código fuente, se trata de un **falso positivo por heurística conductual**: no hay
payload malicioso, descarga de red de código, ejecución de código remoto, ni ofuscación. El plugin
es una herramienta de desarrollo que orquesta compilación .NET, SVN/Git y consultas a BD internas.

## Qué es el proceso señalado

- **Proceso:** `python.exe` ejecutando `mcp/rs-workspace-server.py` (servidor MCP, transporte stdio).
- **Lanzado por:** Claude Code (config `.mcp.json`): `python ${CLAUDE_PLUGIN_ROOT}/mcp/rs-workspace-server.py`.
- **Qué hace `ping` (el disparador):** enumera `hooks/*.ps1` (solo lista nombres, no los lee ni
  ejecuta) y lanza `svn --version` y `git --version`. Nada más. Ref: `mcp/rs-workspace-server.py:684-694`.

## Patrones que la heurística puntúa, y por qué son benignos

| Patrón detectado | Dónde | Por qué es legítimo |
|---|---|---|
| `python.exe` → `powershell.exe -ExecutionPolicy Bypass` | `mcp/rs-workspace-server.py:91` (`_run_ps`); hooks `Stop`/`UserPromptSubmit` en `.claude-plugin/plugin.json:14,26` | Ejecuta **scripts `.ps1` del propio repo** con `-File` (nunca `-Command` ni `-EncodedCommand`/`-enc`). `Bypass` es para correr scripts locales no firmados del plugin, no descargados. |
| `Add-Type System.Net.Http` + `HttpClient` + POST multipart de bytes de fichero a URL | `hooks/jira-attach.ps1:63-81` | Sube **adjuntos a Jira Cloud** vía REST oficial (`/rest/api/3/issue/{KEY}/attachments`). El MCP de Jira no expone adjuntos; se hace por REST. Destino = instancia Jira corporativa, no host arbitrario. |
| `Invoke-Expression` | `runner/runner.ps1` (**ya eliminado** en v2.4.0), `compile-check.ps1:38`, `test-runner-check.ps1:58` | En compile/test es `dotnet build`/`dotnet test` sobre cadena construida localmente. En el runner se ha reemplazado por `& $script @args` (v2.4.0). |
| Spawns `svn`/`git`/`sqlcmd`/`sqlplus`/`dotnet`/`msbuild` | varios hooks | Tooling estándar de desarrollo .NET + control de versiones + consulta a BD internas. |
| Temporal `.sql` + spawn `sqlplus` + borrado | `mcp/rs-workspace-server.py:287-293` | Consulta Oracle: `sqlplus` requiere script en fichero. Es un `.sql` (datos, no ejecutable), borrado tras uso. |

## Lo que NO existe en el código (descarta amenaza real)

- Sin `DownloadString` / `DownloadFile` / `Invoke-WebRequest` / `Net.WebClient` / `certutil` / `bitsadmin` → **no descarga código de red**.
- Sin `FromBase64String` → **no decodifica/ejecuta payloads** (solo `ToBase64String` de credenciales Basic-auth para Jira).
- Sin `-EncodedCommand` / `-enc` → **no hay comandos ofuscados**.
- Sin `[Reflection.Assembly]::Load` / `Marshal` / `VirtualAlloc` / `GetDelegateForFunctionPointer` → **no hay inyección/shellcode**.
- `powershell` siempre con `-File` + `subprocess` sin `shell=True` → **no hay construcción dinámica de líneas de comando**.

## Acción recomendada

1. **Confirmar el detalle de la detección** en la consola Falcon: nombre exacto de la detección,
   fichero/proceso puesto en cuarentena y timestamp. (Determina si CrowdStrike solo bloqueó el
   proceso o además puso en cuarentena algún `.ps1` — en cuyo caso hay que restaurarlo.)
2. **Clasificar como falso positivo** y aplicar exclusión mínima:
   - Proceso: `python.exe` cuyo argumento de línea de comandos contiene
     `...\rs-enterprise-agent\...\mcp\rs-workspace-server.py`.
   - Directorio del plugin instalado:
     `C:\Users\<usuario>\.claude\plugins\cache\rs-enterprise-agent\` (y el repo fuente si se ejecuta
     desde `N:\SVN\RS\Agentes\SkillsClaude\rs-skill-full\`).
3. **Alternativa preferible a excluir** (si la política lo permite): firmar los `.ps1` del plugin y
   exigir política de firma, en lugar de una exclusión amplia de directorio.

## Contacto / referencias de código

Todas las rutas son relativas al repo del plugin `rs-skill-full`. Ficheros clave para revisión:
`mcp/rs-workspace-server.py`, `runner/runner.ps1`, `hooks/jira-attach.ps1`, `.claude-plugin/plugin.json`, `.mcp.json`.
