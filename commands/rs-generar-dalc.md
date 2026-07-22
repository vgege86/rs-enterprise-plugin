---
description: "Genera clases DALC completas desde el modelo BD para una tabla."
argument-hint: "<Tabla> en <Solution>.sln"
---

Invoke the `rs-enterprise-agent` skill in DALC-generation mode.

Usage: /rs-generar-dalc <NombreTabla> en <Solution>.sln
Example: /rs-generar-dalc RCLIENTES en RSProcIN.sln

Dispatch to the `rs-generar-dalc` subagent (runs on Sonnet — code generation from a fixed template, human confirms before file creation) via the Agent tool. Pass in the prompt: `sln_path`, `workspace`, `plugin_root` (all resolved per SKILL.md rules) and the target table name. Relay the subagent's output verbatim — do not reformat or summarize it.
