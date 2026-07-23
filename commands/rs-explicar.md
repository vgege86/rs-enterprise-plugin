---
description: "Explica en lenguaje natural qué hace una clase/método/proceso y su flujo de datos. Uso: /rs-explicar <Solution>.sln <clase|método|proceso>"
argument-hint: "<Solution>.sln <clase|método|proceso>"
---

Invoke the `rs-enterprise-agent` skill in explain mode.

Usage: /rs-explicar <Solution>.sln <clase|método|proceso>
Example: /rs-explicar RSProcIN.sln CobrosDalc

Dispatch to the `rs-explicar` subagent (runs on Sonnet — explains in natural language what a class/method/process does, its data flow and side effects; read-only, for onboarding) via the Agent tool. Pass in the prompt: `sln_path`/`workspace` (resolved per SKILL.md "Resolución de solución"), `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), and the element to explain. Relay the subagent's output verbatim — do not reformat or summarize it.
