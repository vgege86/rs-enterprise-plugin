---
description: "Valida código C# (DALC/clase/tabla) contra la BD real — tipos, longitudes, nullabilidad, motor."
argument-hint: "<Solution>.sln <DALC|clase|tabla>"
---

Invoke the `rs-enterprise-agent` skill in BD-validation mode.

Usage: /rs-validar-bd <Solution>.sln <DALC|clase|tabla>
Example: /rs-validar-bd RSProcIN.sln CobrosDalc.cs

Dispatch to the `rs-validacion-bd` subagent (runs on Sonnet — read-only BD validation of code against the real schema, advisory, doesn't write code or run DDL/DML) via the Agent tool. Pass in the prompt: `sln_path` and `workspace` (resolved per SKILL.md "Resolución de solución"), `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), and the element to validate (DALC file, class, or table). Relay the subagent's output verbatim — do not reformat or summarize it.
