---
description: "Revisión de un cambio (diff/PR) con veredicto APRUEBA/CAMBIOS/BLOQUEA. Uso: /rs-review <Solution>.sln [--rev <revisiones>] [--pr <n> [owner/repo]]"
argument-hint: "<Solution>.sln [--rev <revisiones>] [--pr <n>]"
---

Invoke the `rs-enterprise-agent` skill in review mode.

Usage: /rs-review <Solution>.sln [--rev <revisiones>] [--pr <n> [owner/repo]]
Example: /rs-review RSProcIN.sln --rev 1234
Example: /rs-review AgendaWeb.sln --pr 42 vgege86/agendaweb

First call `detect_vcs(workspace)` so the subagent branches correctly (SVN/Git). Then dispatch to the `rs-review` subagent (runs on Opus — blocking review verdict combining static risk + security + DB compatibility over the delta) via the Agent tool. Pass in the prompt: `sln_path` (resolved per SKILL.md "Resolución de solución"), `workspace`, `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), plus any `--rev`/`--pr` arguments the user gave. Relay the subagent's output verbatim — do not reformat or summarize it.
