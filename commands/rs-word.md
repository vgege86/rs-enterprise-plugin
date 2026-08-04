---
description: "Convierte documentación Markdown del agentic_manual a Word (.docx) con la plantilla corporativa .dotx. Uso: /rs-word <ficheros|carpeta> [--plantilla <x.dotx>]"
argument-hint: "<ficheros|carpeta> [--plantilla <x.dotx>]"
---

Invoke the `rs-enterprise-agent` skill in word mode.

Usage: /rs-word <ficheros|carpeta> [--plantilla <x.dotx>]
Example: /rs-word docs\agentic_manual\funcional\OPERACION

Dispatch to the `rs-word` subagent (runs on Haiku — converts Markdown to a .docx over the client's .dotx template via Word COM; read-only on the sources, never loads the document into context) via the Agent tool. Pass in the prompt: `workspace` (the session cwd), `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), and the sources/template taken from the user's arguments. Relay the subagent's output verbatim — do not reformat or summarize it.

Requires Microsoft Word installed (COM automation) — there is no pandoc/python-docx fallback. If the subagent reports that Word is unavailable, relay it as-is; do not propose alternatives that do not exist.
