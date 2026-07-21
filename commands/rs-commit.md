---
description: Muestra diff (SVN o Git, autodetectado), sugiere mensaje de commit y confirma antes de ejecutar. Uso: /rs-commit <Solution>.sln
---

Invoke the `rs-enterprise-agent` skill in commit mode (SVN or Git, auto-detected).

Usage: /rs-commit <Solution>.sln
Example: /rs-commit RSProcIN.sln

1. Call `mcp__plugin_rs-enterprise-agent_rs-workspace__detect_vcs(workspace)` first (`workspace` = cwd of this session, see SKILL.md "Workspace y Rutas"). If `vcs == "none"` → inform the user no VCS was detected under the workspace, don't guess.
2. Dispatch via the Agent tool to the `rs-commit` subagent (Sonnet — shared repo action; in Git it does commit + push with separate confirmations). It branches internally on the motor.
3. Pass in the prompt: `sln_path`, `workspace` (resolved per SKILL.md rules) and the detected `vcs`. Relay the subagent's output verbatim — do not reformat or summarize it.
