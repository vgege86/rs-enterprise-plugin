---
description: "Mapa de capas y dependencias de la solución, detecta referencias circulares."
argument-hint: "<Solution>.sln"
---

Invoke the `rs-enterprise-agent` skill in structure mode.

Usage: /rs-estructura <Solution>.sln
Example: /rs-estructura RSProcIN.sln

Dispatch to the `rs-estructura` subagent (runs on Haiku — read-only, mechanical, no need for the chat's model) via the Agent tool. Pass in the prompt: `workspace` = cwd of this session (see SKILL.md "Workspace y Rutas") and the solution name. Relay the subagent's output verbatim — do not reformat or summarize it.
