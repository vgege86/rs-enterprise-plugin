---
description: "Actualiza la documentación canónica de RSValidador (funcional, técnica y release notes) sin tocar código. Uso: /rsv-doc <qué actualizar>"
argument-hint: "<qué actualizar>"
---

Invoke the `rs-validador` skill — main mode with `Tipo: documentación` fixed in the PLAN.

Usage: /rsv-doc <qué actualizar>
Example: /rsv-doc documenta los endpoints de grupos de estructuras
Example: /rsv-doc aplica los hallazgos del último /rsv-doc-drift

This runs in the **main thread** — do not dispatch to a subagent. It is the writing counterpart of
`/rsv-doc-drift`, which only audits: run the audit first when the drift is not already known.

1. Resolve `validador_root` and `plugin_root` per SKILL.md (never hardcode a path; ask if ambiguous).
2. Read the sections to be rewritten and verify each claim against the real code before touching a
   word — the point of this command is that the docs match the code, so an unverified sentence is
   worse than a missing one.
3. ⛔ **Stop at the PLAN gate.** Present the `## PLAN` block with `Tipo: documentación`, listing the
   exact sections to change and what each one gets, then end the turn. Write nothing until the user
   approves — the gate applies to documentation exactly as it does to code.

Scope after approval, limited to these files under `validador_root`:
- `docs/documentacion-funcional.md` — what the user sees and can do.
- `docs/documentacion-tecnica.md` — architecture, data model, endpoints, risks.
- `RELEASE_NOTES_<AAAA-MM-DD>.md` — the delivery entry, when the change belongs to one.

⛔ Edit only the affected section, respecting the existing tone and structure — never rewrite a whole
document. ⛔ Never touch `CONTEXTO_CODEX.md`: it is historical, not canonical; if it contradicts
`docs/`, `docs/` wins and stays as the thing to correct. ⛔ No production code in this mode — if the
docs are right and the code is wrong, say so and stop; that is a `/rsv-bug`.

⛔ Not for C#/`.sln` uCollect/RS solutions — that is the `rs-enterprise-agent` plugin.
