---
description: Migra DALCs y SQL entre motores SQL Server y Oracle. Uso: /rs-migrar <Solution>.sln a <ORACLE|SQLSERVER>
---

Invoke the `rs-enterprise-agent` skill in motor-migration mode.

Usage: /rs-migrar <Solution>.sln a <ORACLE|SQLSERVER>
Example: /rs-migrar RSProcIN.sln a ORACLE

Dispatch to the `rs-migracion-motor` subagent (runs on Opus — rewrites production SQL across the whole scope, high blast radius, requires confirmation before applying) via the Agent tool. Pass in the prompt: `sln_path`, `workspace`, `plugin_root` (all resolved per SKILL.md rules) and the target engine. Relay the subagent's output verbatim — do not reformat or summarize it.
