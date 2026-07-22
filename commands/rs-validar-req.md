---
description: "Verifica que el diff SVN implementa correctamente un requerimiento."
argument-hint: "\"<req>\" --rev <rev>"
---

Invoke the `rs-enterprise-agent` skill in requirement-validation mode.

Usage:
  /rs-validar-req "<requirement>" --rev <revisions> [--sln <solution.sln>] [--session]

Arguments:
  <requirement>   Free text or path to a .md/.txt file with the specification
  --rev           SVN revision(s), comma-separated (e.g. 1234 or 1234,1235)
  --sln           Solution file (optional — inferred from diff if omitted)
  --session       Also search Claude Code session transcript for richer analysis

Examples:
  /rs-validar-req "validate that amount is positive and below limit" --rev 1234
  /rs-validar-req "reqs/req-001.md" --rev 1234,1235 --sln RSProcIN.sln
  /rs-validar-req "add audit log on every process" --rev 1240 --session

Dispatch to the `rs-validar-req` subagent (runs on Opus — final compliance gate, a false "cumple" lets bad code ship) via the Agent tool. Pass in the prompt: `workspace` and the requirement text/path, revisions, optional `sln_path` and `--session` flag as given by the user. Relay the subagent's output verbatim — do not reformat or summarize it.
