---
description: "Renderiza la guía de usuario del plugin (README) a un HTML navegable con formato y lo abre en el navegador. Uso: /rs-help"
argument-hint: ""
---

Invoke the `rs-enterprise-agent` skill in help mode.

Usage: /rs-help
Example: /rs-help

Dispatch to the `rs-help` subagent (runs on Haiku — renders the plugin's README.md to a self-contained, themed HTML user guide and opens it; read-only, never loads the HTML into context) via the Agent tool. Pass in the prompt: `workspace` (the session cwd) and `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\). Relay the subagent's output verbatim — do not reformat or summarize it.
