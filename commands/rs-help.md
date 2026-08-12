---
description: "Renderiza la guía de usuario del plugin (README) a un HTML navegable con formato y lo abre en el navegador. Uso: /rs-help"
argument-hint: ""
---

⛔ Self-contained — do NOT invoke the `rs-enterprise-agent` skill. Everything this mode needs is
below; loading the skill costs ~7k tokens and adds nothing to a read-only dispatch.

Usage: /rs-help
Example: /rs-help

Dispatch to the `rs-help` subagent (runs on Haiku — renders the plugin's README.md to a self-contained, themed HTML user guide and opens it; read-only, never loads the HTML into context) via the Agent tool. Pass in the prompt: `workspace` (the session cwd) and `plugin_root` (normalize the path you were given for this command — if it ends in `\skills\<x>`, go up two levels — and verify with Glob that it contains `hooks\` and `runner\`; ⛔ never `${CLAUDE_PLUGIN_ROOT}`, it is not expanded in markdown). Relay the subagent's output verbatim — do not reformat or summarize it.
