---
description: "Genera un dashboard HTML de estadísticas del pipeline y lo abre en el navegador. Uso: /rs-dashboard [workspace]"
argument-hint: "[workspace]"
---

⛔ Self-contained — do NOT invoke the `rs-enterprise-agent` skill. Everything this mode needs is
below; loading the skill costs ~7k tokens and adds nothing to a read-only dispatch.

Usage: /rs-dashboard
Example: /rs-dashboard

Dispatch to the `rs-dashboard` subagent (runs on Haiku — generates a self-contained stats dashboard HTML from executions/history.json and opens it; read-only, never loads the HTML into context) via the Agent tool. Pass in the prompt: `workspace` (the session cwd) and `plugin_root` (normalize the path you were given for this command — if it ends in `\skills\<x>`, go up two levels — and verify with Glob that it contains `hooks\` and `runner\`; ⛔ never `${CLAUDE_PLUGIN_ROOT}`, it is not expanded in markdown). Relay the subagent's output verbatim — do not reformat or summarize it.
