---
description: Analiza todas las referencias a una clase, método o tabla dentro del scope. Uso: /rs-impacto <símbolo> en <Solution>.sln
---

Invoke the `rs-enterprise-agent` skill in impact-analysis mode.

Usage: /rs-impacto <clase|método|tabla> en <Solution>.sln
Example: /rs-impacto RCLIENTES en RSProcIN.sln

Dispatch to the `rs-impacto` subagent (runs on Sonnet — pure read-only analysis) via the Agent tool. Pass in the prompt: `sln_path` (resolved per SKILL.md "Resolución de solución") and the target element (class/method/table/column). Relay the subagent's output verbatim — do not reformat or summarize it.
