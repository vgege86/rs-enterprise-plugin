---
description: Detecta drift entre BD/<proyecto>-model.json y el esquema real en BD. Uso: /rs-comparar-modelo
---

Invoke the `rs-enterprise-agent` skill in model-comparison mode.

Usage: /rs-comparar-modelo [workspace]
Example: /rs-comparar-modelo

Dispatch to the `rs-comparar-modelo` subagent (runs on Haiku — 1 tool call + deterministic diff table) via the Agent tool. Pass in the prompt: `workspace` = cwd of this session (see SKILL.md "Workspace y Rutas"). Relay the subagent's output verbatim — do not reformat or summarize it.
