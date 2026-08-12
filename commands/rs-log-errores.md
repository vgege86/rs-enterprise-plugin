---
description: "Analiza el log de errores de la web, deduplica los tipos de error, abre una tarea por tipo en Jira/Mantis y propone lanzar el pipeline para cada una."
argument-hint: "<ruta log|carpeta> [--desde YYYY-MM-DD] [--max N] [--glob *.log] [--niveles ERROR,FATAL]"
---

Invoke the `rs-log-errores` skill.

Usage: /rs-log-errores <ruta log|carpeta> [--desde YYYY-MM-DD] [--max N] [--glob *.log] [--niveles ERROR,FATAL]
Examples:
- /rs-log-errores C:\AIS\<Proyecto>\AgendaWeb\logs
- /rs-log-errores C:\AIS\<Proyecto>\AgendaWeb\logs\web.log --desde 2026-08-01
- /rs-log-errores \\servidor\logs\web --max 10 --niveles ERROR,FATAL,WARN

Turns a web error log into actionable tickets. Deduplication is **not** done by the model: the tool
`mcp__plugin_rs-enterprise-agent_rs-workspace__parse_web_log` (hook `parse-weblog.ps1`) groups the
occurrences by signature (exception + own-code frame + normalized message) and returns only the
aggregate, so the raw log never enters context and PII is redacted before anything reaches a ticket.

Run it **in the main thread** by following `<plugin_root>/skills/rs-log-errores/SKILL.md` — it
creates tickets and launches the pipeline, neither of which a subagent can do. `plugin_root` resolved
per SKILL.md "Raíz del plugin" (normalize the received path, verify it contains `hooks\` and
`runner\`). ⛔ `${CLAUDE_PLUGIN_ROOT}` does not expand in markdown.

Phases: F0 source · F1 parse+dedup · F2 triage and proposed tasks (⛔ gate) · F3 create in the
project's tracker (Jira or Mantis, detected exactly like `/rs-tarea`, applying the config `defaults`
and labels) · F4 propose the pipeline **one task at a time**. It does NOT modify the
`rs-enterprise-agent` pipeline and does NOT reimplement Jira/Mantis — F3/F4 delegate to `rs-jira` /
`rs-mantis`. Respect every ⛔ gate and relay tool output and ticket results verbatim.
