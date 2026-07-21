# Integración Jira (skill `rs-jira` / `/rs-tarea`)

La skill `rs-jira` orquesta el ciclo de vida de una tarea de Jira sobre una solución uCollect/RS.
Jira se opera con el MCP **Atlassian Rovo** (ya conectado en la sesión): búsqueda, lectura,
transición y comentario **no requieren credenciales propias**. El único hueco es **adjuntar
ficheros** (Rovo no expone attachment), que cubre `mcp__plugin_rs-enterprise-agent_rs-workspace__jira_attach` con credenciales
propias.

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
  "openStatuses": []
}
```

- `projectKey` — clave del proyecto Jira.
- `jiraUser` — email o accountId; por defecto el de `atlassianUserInfo`.
- `cloudId` — opcional; si falta se resuelve con `getAccessibleAtlassianResources`.
- `statusMap` — nombres **reales** de los estados del workflow del proyecto (varían por proyecto/idioma).
- `openStatuses` — opcional; estados considerados "abiertos" en Fase 1. Vacío → se usa
  `statusCategory = "To Do"` (robusto a idioma).

Scaffolding rápido: `/rs-tarea init`.

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
| Adjuntar `.sql` | `mcp__plugin_rs-enterprise-agent_rs-workspace__jira_attach(issue_key, files)` → hook `jira-attach.ps1` |

⛔ Rovo usa auth interactiva → la skill no corre en headless/cron.
