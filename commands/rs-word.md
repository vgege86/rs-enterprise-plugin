---
description: "Convierte documentación Markdown del agentic_manual a Word (.docx) con la plantilla corporativa .dotx. Uso: /rs-word <ficheros|carpeta> [--plantilla <x.dotx>]"
argument-hint: "<ficheros|carpeta> [--plantilla <x.dotx>]"
---

⛔ Self-contained — do NOT invoke the `rs-enterprise-agent` skill. Everything this mode needs is
below; loading the skill costs ~7k tokens and adds nothing to a read-only dispatch.

Usage: /rs-word <ficheros|carpeta> [--plantilla <x.dotx>]
Example: /rs-word docs\agentic_manual\funcional\OPERACION

Dispatch to the `rs-word` subagent (runs on Haiku — converts Markdown to a .docx over the client's .dotx template via Word COM; read-only on the sources, never loads the document into context) via the Agent tool. Pass in the prompt: `workspace` (the session cwd), `plugin_root` (normalize the path you were given for this command — if it ends in `\skills\<x>`, go up two levels — and verify with Glob that it contains `hooks\` and `runner\`; ⛔ never `${CLAUDE_PLUGIN_ROOT}`, it is not expanded in markdown), and the sources/template taken from the user's arguments. Relay the subagent's output verbatim — do not reformat or summarize it.

Requires Microsoft Word installed (COM automation) — there is no pandoc/python-docx fallback. If the subagent reports that Word is unavailable, relay it as-is; do not propose alternatives that do not exist.
