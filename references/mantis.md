# Integración MantisBT (skill `rs-mantis` / `/rs-mantis`)

La skill `rs-mantis` orquesta el ciclo de vida de una tarea de MantisBT sobre una solución
uCollect/RS, espejando `rs-jira`, y además permite **crear tareas nuevas**. A diferencia de Jira,
MantisBT **no tiene MCP** (no hay Atlassian Rovo equivalente): la skill llama a un **cliente REST
autónomo en PowerShell**, `hooks/mantis-cli.ps1`, invocado por Bash — nunca a tools del MCP
`rs-workspace`.

Motivo de esta arquitectura: si las operaciones Mantis fueran tools del MCP `rs-workspace`,
dependerían del proceso `python.exe` vivo desde la primera fase, exponiéndose al falso positivo de
CrowdStrike que cuelga el turno hasta 1800s (ver `docs/crowdstrike-fp-justification.md`). `rs-jira`
solo toca `rs-workspace` en su Fase 4 por la misma razón. Un hook autónomo esquiva `python.exe` por
completo, tiene un único camino de auth (API token) y es testeable con guardas puras y un test de
fallo de red local, sin tocar la instancia real.

Instancia objetivo: `https://soporte.ais-int.net/mantis/` — REST API 2.x confirmada viva.

## Base REST

⚠️ El rewrite `.htaccess` **no está activo** en esta instalación: `/api/rest/projects` → 404. La
API solo responde por el front controller, así que la **base real** que usa el cliente es:

```
{baseUrl}/api/rest/index.php
```

(p. ej. `GET {baseUrl}/api/rest/index.php/projects` + token → 200). Esta forma es además **más
portable**: funciona con y sin rewrite activo, por eso es la que construye `New-MantisRequest` en
`hooks/lib-mantis.ps1`. Verificado en vivo contra la instancia objetivo: 41 proyectos, estados en
uso `assigned`/`resolved`/`closed`, categorías incluyen `General`/`Evolutivo`/`Incidencia`.

## Config del workspace — `docs\.mantis-dev-config.json`

En la carpeta `docs\` del workspace, **junto a `.rs-databases.json`** (misma convención que la
config de Jira). **No contiene secretos** (aun así, recomendado añadirlo al ignore de VCS):

```json
{
  "projects": [
    { "id": 12, "name": "ClienteX 2025" },
    { "id": 8,  "name": "ClienteX 2024" }
  ],
  "defaultCategory": "General",
  "statusMap": { "inProgress": "assigned", "inValidation": "resolved" }
}
```

- `projects[]` — lista **curada manualmente** de proyectos Mantis del cliente (un repo puede tener
  varios; a menudo uno nuevo por año, los viejos siguen abiertos). No se filtra por nombre porque
  los nombres de cliente en Mantis no son consistentes. Se gestiona con `/rs-mantis proyectos`.
- `defaultCategory` — categoría por defecto al crear una issue.
- `statusMap` — nombres **reales** de los estados del workflow Mantis (varían por instalación). En
  la instancia objetivo se confirmaron en vivo con token real: por defecto `assigned` (En Proceso)
  y `resolved` (En Validación).

Scaffolding rápido: `/rs-mantis proyectos` (lista todos los proyectos que ve el token, numerados
`id — nombre (estado)`, y permite **Añadir** a la lista existente sin duplicar por `id`, o
**Crear** reemplazándola).

## Credenciales — `~/.claude/rs-mantis-credentials.json`

**Fuera de cualquier repo/workspace.**

```json
{ "baseUrl": "https://soporte.ais-int.net/mantis", "token": "<API token de Mantis>" }
```

- El token es un **API token de Mantis** (Mantis → *My Account → API Tokens → Create*).
- Es **por usuario**: identifica al reporter/handler de las operaciones; no se guarda un usuario
  aparte (a diferencia de Jira, que usa Basic auth `email:token`).
- `hooks/lib-mantis.ps1` (`Get-MantisCreds`) lee este fichero y valida que `baseUrl` y `token`
  estén presentes antes de tocar red; si falta o está incompleto, el error indica cómo crearlo.
- ⛔ El token **nunca** se imprime en output de hook/tool/log, ni se guarda en
  `.mantis-dev-config.json`.

## `hooks/mantis-cli.ps1` — subcomandos ↔ endpoint REST

Cliente REST autónomo con contrato JSON in/out: éxito `{ "success": true, ... }`, error
`{ "success": false, "error": "<msg>" }` + `exit 1`. Reutiliza el patrón `HttpClient` de
`hooks/jira-attach.ps1` (compatible Windows PowerShell 5.1), fuerza TLS 1.2 y UTF-8 en stdout.
Header de autenticación: `Authorization: <token>` — token **crudo**, **sin** prefijo `Bearer`.

| Subcomando | Llamada REST | Uso |
|---|---|---|
| `projects` | `GET /projects` | listar todos los proyectos que ve el token |
| `list -Project <id> [-PageSize <n>]` | `GET /issues?project_id={id}&page_size={n}` | issues del proyecto |
| `get -Id <n>` | `GET /issues/{id}` | leer una issue |
| `create -Project <id> -Category <s> -Summary <s> -Description <s> [-Handler <id>]` | `POST /issues` | crear issue |
| `transition -Id <n> -Status <name>` | `PATCH /issues/{id}` body `{"status":{"name":"<name>"}}` | cambiar estado |
| `comment -Id <n> -Text <s>` | `POST /issues/{id}/notes` body `{"text":"<s>"}` | añadir nota |
| `attach -Id <n> -Files a,b` | `POST /issues/{id}/files` (multipart, campo `files[]`) | adjuntar ficheros |
| `download -Id <n> -FileId <f> -Out <ruta>` | `GET /issues/{id}/files/{f}` | descargar un adjunto |

Notas de contrato:
- `create` devuelve `{ success, id, issue }` con el id de la issue creada.
- `attach` reutiliza el multipart de `jira-attach.ps1` (`ByteArrayContent` +
  `MultipartFormDataContent`), un `HttpClient` propio (no pasa por `Invoke-MantisHttp`).
- Todos los subcomandos validan argumentos obligatorios (guarda pura, sin red) y luego
  credenciales presentes/completas **antes** de la llamada HTTP; si faltan, el error remite a este
  documento.

## Nota sobre estados

MantisBT **no tiene un endpoint de "transiciones"** como Jira (`getTransitions`/
`transitionJiraIssue`): el estado es simplemente un **campo** de la issue, que se cambia con
`PATCH /issues/{id}` enviando `{"status":{"name":"<nombre>"}}`. Por eso `statusMap` en
`.mantis-dev-config.json` guarda **nombres de estado destino** (`assigned`, `resolved`, …), no ids
de transición — y esos nombres varían por instalación/workflow, por lo que deben confirmarse con
token real (`get`, o `GET /projects/{id}`) antes de fijarlos en la config. Un nombre de estado
desconocido hace que `transition` devuelva el error tal cual lo reporta Mantis.

## Seguridad

- El token vive únicamente en `~/.claude/rs-mantis-credentials.json`, fuera del repo.
- ⛔ Nunca se imprime ni se loguea el token ni el contenido del fichero de credenciales.
- `Protect-MantisToken` (en `hooks/lib-mantis.ps1`) redacta el token a `***` en cualquier mensaje
  de error antes de emitirlo (por ejemplo, si el propio token aparece reflejado en un cuerpo de
  respuesta HTTP de error).
- La config del workspace (`.mantis-dev-config.json`) no contiene secretos y está separada de las
  credenciales — misma disciplina que `rs-jira`.
