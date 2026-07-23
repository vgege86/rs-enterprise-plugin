---
description: "Detecta doc funcional obsoleta respecto a cambios recientes del código. Uso: /rs-doc-drift <Solution>.sln [--rev <revisiones>]"
argument-hint: "<Solution>.sln [--rev <revisiones>]"
---

Invoke the `rs-enterprise-agent` skill in doc-drift mode.

Usage: /rs-doc-drift <Solution>.sln [--rev <revisiones>]
Example: /rs-doc-drift RSProcIN.sln
Example: /rs-doc-drift AgendaWeb.sln --rev 1234

First call `detect_vcs(workspace)` so the subagent branches correctly (SVN/Git). Then dispatch to the `rs-doc-drift` subagent (runs on Sonnet — crosses recent code changes against the functional docs to flag outdated/incomplete/missing sections; read-only, advisory, doesn't rewrite docs) via the Agent tool. Pass in the prompt: `sln_path`/`workspace` (resolved per SKILL.md "Resolución de solución"), `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), plus any `--rev`. Relay the subagent's output verbatim — do not reformat or summarize it.
