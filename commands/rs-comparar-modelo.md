---
description: "Detecta drift entre BD/<proyecto>-model.json y el esquema real en BD."
---

⛔ Self-contained — do NOT invoke the `rs-enterprise-agent` skill. Everything this mode needs is
below; loading the skill costs ~7k tokens and adds nothing to a read-only dispatch.

Usage: /rs-comparar-modelo [workspace]
Example: /rs-comparar-modelo

Dispatch to the `rs-comparar-modelo` subagent (runs on Haiku — 1 tool call + deterministic diff table) via the Agent tool. Pass in the prompt: `workspace` = cwd of this session (the "Primary working directory"). Relay the subagent's output verbatim — do not reformat or summarize it.
