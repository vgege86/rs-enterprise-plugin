---
description: "Genera notas de versión funcionales desde el historial de commits (SVN/Git). Uso: /rs-release-notes [Solution] [N] [--desde YYYY-MM-DD]"
argument-hint: "[Solution] [N] [--desde YYYY-MM-DD]"
---

Invoke the `rs-enterprise-agent` skill in release-notes mode.

Usage: /rs-release-notes [Solution] [N] [--desde YYYY-MM-DD]
Example: /rs-release-notes RSProcIN 30
Example: /rs-release-notes --desde 2026-07-01

First call `detect_vcs(workspace)` so the subagent branches correctly (SVN/Git). Then dispatch to the `rs-release-notes` subagent (runs on Sonnet — turns raw commit history into grouped functional release notes) via the Agent tool. Pass in the prompt: `workspace`, `plugin_root` (resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains hooks\ and runner\), plus any solution filter / commit count / `--desde` the user gave. Relay the subagent's output verbatim — do not reformat or summarize it.
