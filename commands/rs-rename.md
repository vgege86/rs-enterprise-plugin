---
description: "Renombra un símbolo (clase/método/propiedad/tabla) y todas sus referencias, previa confirmación. Uso: /rs-rename <Solution>.sln <viejo> a <nuevo>"
argument-hint: "<Solution>.sln <viejo> a <nuevo>"
---

Invoke the `rs-enterprise-agent` skill in rename mode.

Usage: /rs-rename <Solution>.sln <viejo> a <nuevo>
Example: /rs-rename RSProcIN.sln GrabarCobro a RegistrarCobro

Dispatch to the `rs-rename` subagent (runs on Opus — locates all references like impact analysis, then rewrites them safely; writes source code only after an explicit human confirmation gate) via the Agent tool. Pass in the prompt: `sln_path` (resolved per SKILL.md "Resolución de solución"), `workspace`, `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), and the old/new symbol names. Relay the subagent's output verbatim — do not reformat or summarize it. The subagent will stop and ask for explicit confirmation before rewriting any file.
