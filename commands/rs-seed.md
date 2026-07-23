---
description: "Genera datos de prueba sintéticos (INSERTs) para una tabla, respetando el esquema real. Uso: /rs-seed <Solution>.sln <tabla> [N]"
argument-hint: "<Solution>.sln <tabla> [N]"
---

Invoke the `rs-enterprise-agent` skill in seed mode.

Usage: /rs-seed <Solution>.sln <tabla> [N]
Example: /rs-seed RSProcIN.sln RCLIENTES 20

Dispatch to the `rs-seed` subagent (runs on Sonnet — generates synthetic test-data INSERTs honoring the model's types, lengths, nullability and FKs; writes a .sql file, never runs it against the DB) via the Agent tool. Pass in the prompt: `sln_path`/`workspace` (resolved per SKILL.md "Resolución de solución"), `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), the target table and optional row count. Relay the subagent's output verbatim — do not reformat or summarize it.
