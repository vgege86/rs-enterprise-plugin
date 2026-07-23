---
description: "Mapa de cobertura de tests: qué clases/métodos públicos no tienen test. Uso: /rs-cobertura <Solution>.sln"
argument-hint: "<Solution>.sln"
---

Invoke the `rs-enterprise-agent` skill in coverage mode.

Usage: /rs-cobertura <Solution>.sln
Example: /rs-cobertura RSProcIN.sln

Dispatch to the `rs-cobertura` subagent (runs on Sonnet — cross-checks the solution's public surface against existing test projects and reports what is uncovered; advisory, doesn't generate or run tests) via the Agent tool. Pass in the prompt: `sln_path` (resolved per SKILL.md "Resolución de solución"), `workspace`, `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\). Relay the subagent's output verbatim — do not reformat or summarize it.
