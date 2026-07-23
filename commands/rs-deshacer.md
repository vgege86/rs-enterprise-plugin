---
description: "Deshace los cambios pendientes del último cambio del pipeline (revert SVN/Git), previa confirmación. Uso: /rs-deshacer <Solution>.sln"
argument-hint: "<Solution>.sln"
---

Invoke the `rs-enterprise-agent` skill in undo mode.

Usage: /rs-deshacer <Solution>.sln
Example: /rs-deshacer RSProcIN.sln

First call `detect_vcs(workspace)` so the subagent branches correctly (SVN/Git). Then dispatch to the `rs-deshacer` subagent (runs on Sonnet — reverts the last pipeline's pending working-copy changes to their versioned state, with a mandatory human confirmation gate before writing) via the Agent tool. Pass in the prompt: `sln_path` (resolved per SKILL.md "Resolución de solución"), `workspace`, `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\). Relay the subagent's output verbatim — do not reformat or summarize it. The subagent will stop and ask for explicit confirmation before reverting anything.
