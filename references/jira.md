# Integración Jira (skill `rs-jira` / `/rs-tarea`)

La skill `rs-jira` orquesta el ciclo de vida de una tarea de Jira sobre una solución uCollect/RS.
Jira se opera con el MCP **Atlassian Rovo** (ya conectado en la sesión): búsqueda, lectura,
transición, comentario, crear y asignar **no requieren credenciales propias**. Los huecos son
**adjuntar y descargar ficheros** (Rovo no expone attachment ni download), cubiertos por
`jira_attach` y `jira_download` con credenciales propias.

⚠️ El MCP `rs-workspace` **solo interviene en la Fase 4** (`jira_attach` / `log_execution`). Las Fases
1–3 (selección, formateo, transición) usan **solo Atlassian Rovo** — por eso la auto-verificación de la
skill **no pinguea `rs-workspace` al arranque** (evita el cuelgue por el FP de CrowdStrike; ver
`docs/crowdstrike-fp-justification.md`).

## Config del workspace — `docs\.jira-dev-config.json`

En la carpeta `docs\` del workspace, **junto a `.rs-databases.json`** (misma convención que la config del
proyecto). **No contiene secretos** (aun así, recomendado añadirlo al ignore de VCS):

```json
{
  "projectKey": "PROJ",
  "jiraUser": "victor.garcia@ubimia.com",
  "cloudId": "opcional-uuid-del-site",
  "statusMap": {
    "inProgress": "En Proceso",
    "inValidation": "En Validación"
  },
  "openStatuses": [],
  "defaults": {
    "issueTypeName": "Error",
    "priority": { "name": "Medium" },
    "components": [{ "name": "AgendaWeb" }],
    "labels": ["mantenimiento"],
    "customfield_10050": "valor",
    "replicarUltimaTarea": true
  }
}
```

- `projectKey` — clave del proyecto Jira.
- `jiraUser` — email o accountId; por defecto el de `atlassianUserInfo`.
- `cloudId` — opcional; si falta se resuelve con `getAccessibleAtlassianResources`.
- `statusMap` — nombres **reales** de los estados del workflow del proyecto (varían por proyecto/idioma).
- `openStatuses` — opcional; estados considerados "abiertos" en Fase 1. Vacío → se usa
  `statusCategory = "To Do"` (robusto a idioma).
- `defaults` — opcional; valores por defecto del proyecto (ver abajo).

Scaffolding rápido: `/rs-tarea init`.

## Valores por defecto y etiquetas — `defaults` (desde 3.18.0)

Todo lo que va dentro de `defaults` se vuelca en `additional_fields` de `createJiraIssue` para
**cualquier** issue que cree el plugin (`/rs-tarea` Fase 1b, `/rs-log-errores` Fase 3). Admite
cualquier campo que acepte tu proyecto: `issueTypeName`, `priority`, `components`, `labels`,
`versions`, `fixVersions`, `duedate`, `environment` y cualquier `customfield_*`.

**`labels` son las etiquetas** que se asignan a las tareas. Es el único campo que **se acumula** en
vez de sobrescribirse: las de `defaults`, más las que pida el usuario, más las que aporte quien
llame al alta (p. ej. `/rs-log-errores` añade `log-<firma>`), sin duplicados.

### Precedencia (⛔ el primero que informa un campo gana)

| Orden | Origen | Por qué va ahí |
|---|---|---|
| 1 | Lo que el usuario indique en la conversación | Decisión explícita del momento |
| 2 | `defaults` del config | Valor declarado del proyecto: explícito, revisable, estable |
| 3 | Réplica de la última tarea creada | Heurística — adivina; cede ante cualquier valor declarado |

`replicarUltimaTarea: false` apaga del todo el paso 3 (la copia de "todos los informados" de la
última tarea del usuario). Por defecto es `true`, así que un config **sin** `defaults` se comporta
exactamente como antes de 3.18.0.

## Credenciales para adjuntar — `~/.claude/rs-jira-credentials.json`

**Fuera de cualquier repo/workspace.** Solo se necesitan en la Fase 4 si hay `.sql` que adjuntar.

```json
{
  "baseUrl": "https://ubimia.atlassian.net",
  "email": "victor.garcia@ubimia.com",
  "token": "<Jira API token>"
}
```

- El token es un **Jira API token** (Atlassian → *Account settings → Security → API tokens*).
- El hook `jira-attach.ps1` lee este fichero, hace Basic auth `email:token` y `POST
  {baseUrl}/rest/api/3/issue/{KEY}/attachments` con `X-Atlassian-Token: no-check`.
- ⛔ El token **nunca** se imprime en output de tool/hook ni se guarda en `.jira-dev-config.json`.
- 🔐 **Cifrado en reposo (opcional):** el `token` puede guardarse cifrado con DPAPI como `enc:<base64>`;
  `jira-attach.ps1`/`jira-download.ps1` lo descifran al vuelo (`Unprotect-RsSecret`). Un token sin el
  prefijo `enc:` se trata como texto plano. Para cifrar el fichero existente: `/rs-cifrar`.

## Descarga de adjuntos — `hooks/jira-download.ps1` (desde 2.25.0)

Reusa las mismas credenciales `~/.claude/rs-jira-credentials.json` (baseUrl, email, token). El hook
hace Basic auth y `GET {baseUrl}/rest/api/3/attachment/content/{FileId}` (siguiendo redirects),
escribiendo los bytes en `-Out`. Expuesto como tool `jira_download(issue_key, file_id, out)`.

- **Destino**: la skill descarga a `docs/<filename>` (plano) del workspace; colisión de nombre →
  sufijo `_2`, `_3`. El hook acepta cualquier `-Out` (ruta alternativa futura solo cambia cómo la
  skill calcula `-Out`).
- **Triggers**: (a) oferta en Fase 1 si la issue trae adjuntos; (b) subrutina `/rs-tarea descargar <KEY>`.
- ⛔ El token nunca se imprime; en fallo (credenciales/404/HTTP no-2xx) devuelve `success:false` sin
  escribir fichero parcial.

## Herramientas usadas

| Operación | Herramienta |
|-----------|-------------|
| Usuario actual / auth | `atlassianUserInfo` (Rovo) |
| Resolver cloudId | `getAccessibleAtlassianResources` (Rovo) |
| Buscar tareas asignadas | `searchJiraIssuesUsingJql` (Rovo) |
| Leer issue | `getJiraIssue` (Rovo) |
| Transiciones disponibles | `getTransitionsForJiraIssue` (Rovo) |
| Cambiar estado | `transitionJiraIssue` (Rovo) |
| Comentar | `addCommentToJiraIssue` (Rovo) |
| Crear issue | `createJiraIssue` (Rovo) |
| Asignar issue (assignee) | `editJiraIssue` (Rovo) / `assignee` en `createJiraIssue` |
| Adjuntar `.sql` | `mcp__plugin_rs-enterprise-agent_rs-workspace__jira_attach(issue_key, files)` → hook `jira-attach.ps1` |
| Descargar adjunto | `mcp__plugin_rs-enterprise-agent_rs-workspace__jira_download(issue_key, file_id, out)` → hook `jira-download.ps1` |

## Comentarios automáticos de trazabilidad (desde 2.16.0)

La skill deja **dos** comentarios en la issue vía `addCommentToJiraIssue`, ambos bajo confirmación:

- **Fase 3** — el **prompt exacto** (`<Solucion>.sln - <cambio>`) que se pasa al orquestador, al lanzar.
- **Fase 4** — el **resumen final** de la tarea (mismo "Informe final": qué se hizo, SQL adjuntados,
  revisión de commit, estado), al cerrar.

⛔ Rovo usa auth interactiva → la skill no corre en headless/cron.
