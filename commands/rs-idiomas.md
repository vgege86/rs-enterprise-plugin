---
description: "Genera scripts INSERT para RIDIOMA y RCONTROLES de controles AIS en .aspx."
argument-hint: "<Solution>.sln"
---

Invoke the `rs-enterprise-agent` skill in idiomas-standalone mode.

Usage: /rs-idiomas <Solution>.sln
Example: /rs-idiomas AgendaWeb.sln

Dispatch to the `rs-idiomas-standalone` subagent (runs on Opus — this area has a real history of bugs, see CHANGELOG 1.5.0; not worth the risk on a weaker model) via the Agent tool. Pass in the prompt: `sln_path` and `workspace` (resolved per SKILL.md rules). Relay the subagent's output verbatim — do not reformat or summarize it.
