---
description: "Pipeline completo de desarrollo automatizado para una solución RS: planificación, análisis, validación, testing y build."
argument-hint: "<Solución>.sln - <cambio a realizar>"
---

Invoke the `rs-enterprise-agent` skill — full pipeline mode (planning → analysis → validation → testing → build).

Trigger: message matches `<Solution>.sln - <change description>` (e.g. "AgendaWeb.sln - FrmBusqueda.aspx - cambia X").
Not for the direct modes (audit/diff/ERD/idiomas/commit/etc.) — those have their own `/rs-*` command and dispatch to a single subagent instead of running this pipeline.

⛔ The pipeline itself — stage list, handoff contract per stage, flow control, the Gate A plan
approval and the safety nets — is defined **only** in `skills/rs-enterprise-agent/SKILL.md`
§ "PIPELINE OBLIGATORIO". Follow it there; do not work from a copy.

This file used to restate all of it, and the copy went stale: the `plan-check` stage shipped in
2.18.0 and never reached it, so until 3.14.0 the two documents described different pipelines in
the same context. One spec, one owner.
