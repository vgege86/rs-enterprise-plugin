---
description: "Corrige un bug de RSValidador (el validador de ficheros) reproduciéndolo antes de tocar código. Uso: /rsv-bug <síntoma>"
argument-hint: "<síntoma del bug>"
---

Invoke the `rs-validador` skill — main mode with `Tipo: bug` fixed in the PLAN.

Usage: /rsv-bug <síntoma>
Example: /rsv-bug la validación masiva falla con ficheros entrecomillados
Example: /rsv-bug al guardar una estructura se pierde el campo `longitud_maxima`

This runs in the **main thread** — do not dispatch to a subagent. Follow SKILL.md end to end, with
step 2 (Análisis) reinforced:

1. Resolve `validador_root` and `plugin_root` per SKILL.md (never hardcode a path; ask if ambiguous).
2. ⛔ **Reproduce before diagnosing.** Do not propose a cause from reading alone. Pin down the exact
   endpoint, the payload that triggers it, the failing line, or the entry in `data/rsvalidador.log`.
   A bug whose reproduction is not understood is not fixed — it is investigated, and that is what the
   PLAN says.
3. State the blast radius explicitly (Pydantic `Schema`, SQL generator, ORM/DDL, HTML screen) and,
   because the store holds the configuration of several uCollect clients at once, whether existing
   configuration is affected.
4. ⛔ **Stop at the PLAN gate.** Present the `## PLAN` block with `Tipo: bug` and the reproduction in
   the `Reproducción / motivo` field, then end the turn. Write nothing until the user approves.

After approval, continue with steps 4 to 9. The fix is minimal — ⛔ no refactoring along the way. The
functional verification must exercise the exact route that was failing and report its real output.

⛔ Not for C#/`.sln` uCollect/RS solutions — that is the `rs-enterprise-agent` plugin.
