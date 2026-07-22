---
description: "Muestra cambios pendientes (SVN o Git, autodetectado) agrupados por solución y proyecto."
argument-hint: "[Solution.sln]"
---

Invoke the `rs-enterprise-agent` skill in diff mode (SVN or Git, auto-detected).

Usage: /rs-diff [Solution.sln]
Example: /rs-diff RSProcIN.sln

1. Call `mcp__plugin_rs-enterprise-agent_rs-workspace__detect_vcs(workspace)` first (`workspace` = cwd of this session, see SKILL.md "Workspace y Rutas"). If `vcs == "none"` → inform the user no VCS was detected, don't guess.
2. Dispatch via the Agent tool to the `rs-diff` subagent (Haiku — read-only, mechanical, no need for the chat's model). It branches internally on the motor.
3. Pass in the prompt: `workspace`, the detected `vcs`, plus the solution filter if the user gave one. Relay the subagent's output verbatim — do not reformat or summarize it.
