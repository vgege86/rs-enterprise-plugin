---
description: "Aplica correcciones de convención (naming/usings/formato), previa confirmación. No toca lógica. Uso: /rs-format <Solution>.sln [fichero]"
argument-hint: "<Solution>.sln [fichero]"
---

Invoke the `rs-enterprise-agent` skill in format mode.

Usage: /rs-format <Solution>.sln [fichero]
Example: /rs-format RSProcIN.sln
Example: /rs-format RSProcIN.sln CobrosDalc.cs

Dispatch to the `rs-format` subagent (runs on Opus — the auto-fix counterpart of /rs-audit: applies safe, mechanical convention fixes (naming, usings, formatting) only; never touches logic; writes code only after an explicit human confirmation gate) via the Agent tool. Pass in the prompt: `sln_path` (resolved per SKILL.md "Resolución de solución"), `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), and any file/folder to scope. Relay the subagent's output verbatim — do not reformat or summarize it. The subagent will stop and ask for explicit confirmation before rewriting any file.
