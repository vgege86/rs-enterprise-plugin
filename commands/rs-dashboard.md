---
description: "Genera un dashboard HTML de estadísticas del pipeline y lo abre en el navegador. Uso: /rs-dashboard [workspace]"
argument-hint: "[workspace]"
---

Invoke the `rs-enterprise-agent` skill in dashboard mode.

Usage: /rs-dashboard
Example: /rs-dashboard

Dispatch to the `rs-dashboard` subagent (runs on Haiku — generates a self-contained stats dashboard HTML from executions/history.json and opens it; read-only, never loads the HTML into context) via the Agent tool. Pass in the prompt: `workspace` (the session cwd) and `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\). Relay the subagent's output verbatim — do not reformat or summarize it.
