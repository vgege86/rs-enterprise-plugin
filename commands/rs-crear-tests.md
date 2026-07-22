---
description: "Crea proyecto de tests si no existe y genera tests unitarios para la solución."
argument-hint: "<Solution>.sln"
---

Invoke the `rs-enterprise-agent` skill in test-creation mode.

Usage: /rs-crear-tests <Solution>.sln
Example: /rs-crear-tests RSProcIN.sln

Dispatch to the `rs-crear-tests` subagent (runs on Sonnet — test generation needs real understanding of the code's logic) via the Agent tool. Pass in the prompt: `sln_path`, `plugin_root` (resolved per SKILL.md rules) and the scope of the change (target classes, or an SVN revision to diff against). Relay the subagent's output verbatim — do not reformat or summarize it.

Note: this covers the direct `/rs-crear-tests` invocation. The pipeline's automatic trigger (`rs-editor-tester`, step 8, when `STATUS: NEEDS_TESTS`) dispatches this same subagent with `FILES_CHANGED` as scope instead of an SVN revision — whether the test project is missing or already exists but the new code lacks coverage.
