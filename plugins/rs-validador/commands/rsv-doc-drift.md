---
description: "Audita si la documentación funcional y técnica de RSValidador sigue coherente con el código. Uso: /rsv-doc-drift [ruta del validador]"
argument-hint: "[ruta del validador]"
---

Invoke the `rs-validador` skill in doc-drift mode.

Usage: /rsv-doc-drift [ruta del validador]
Example: /rsv-doc-drift
Example: /rsv-doc-drift N:\SVN\...\Utils\validador_ficheros

Resolve `validador_root` first (per SKILL.md "Resolución del workspace de RSValidador": the folder
containing `estructura.py`, `validator_service.py` and `docs\` — never hardcode a path; ask if
ambiguous). Then dispatch to the `rsv-doc-drift` subagent (runs on Opus — walks every verifiable claim
in the canonical docs against the real code and classifies the mismatches; read-only, advisory, never
rewrites the docs) via the Agent tool. Pass in the prompt: `validador_root` and `plugin_root`
(resolved per SKILL.md "Raíz del plugin": normalize the received path, verify it contains
`references\` and `.claude-plugin\`). Relay the subagent's output verbatim — do not reformat or
summarize it.
