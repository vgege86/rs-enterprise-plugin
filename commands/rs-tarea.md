---
description: "Orquesta una tarea de Jira sobre una solución RS (selección → formateo → En Proceso → pipeline → commit → adjuntar SQL → En Validación)."
argument-hint: "[PROJ-123]"
---

Invoke the `rs-jira` skill.

Usage: /rs-tarea [PROJ-123 | URL de Jira]
Examples:
- /rs-tarea                → lista tus tareas abiertas del proyecto configurado y eliges una
- /rs-tarea PROJ-123       → arranca directamente con esa issue
- /rs-tarea init           → crea/actualiza `docs\.jira-dev-config.json` del workspace

This orchestrates a Jira issue through its full dev lifecycle by **following
`skills/rs-jira/SKILL.md` in the main thread**. It does NOT modify the `rs-enterprise-agent`
pipeline — Fase 3 launches that pipeline with the formatted prompt. Jira operations use the
connected **Atlassian Rovo** MCP; SQL attachments use `mcp__plugin_rs-enterprise-agent_rs-workspace__jira_attach`.

Read `<plugin_root>/skills/rs-jira/SKILL.md` — `plugin_root` resolved per SKILL.md "Raíz del plugin"
(normalize the received path, verify it contains `hooks\` and `runner\`) — and run its phases (F1 selección · F2 formateo ·
F3 transición+lanzamiento · F4 commit+cierre), respecting every ⛔ gate. Relay Jira results and the
pipeline output verbatim.
