---
description: "Sincroniza índices Oracle (ALL_INDEXES) al modelo BD JSON. Preserva índices manuales."
argument-hint: "[workspace]"
---

Invoke the `rs-enterprise-agent` skill in BD-modeler mode to sync indexes from database.

Usage: /rs-sync-indexes [workspace]
Example: /rs-sync-indexes

Dispatches Task subagent `rs-editor-db-modeler` (`agents/rs-editor-db-modeler.md`) — runs `hooks/sync-indexes.ps1` to pull ALL_INDEXES from Oracle
into `BD/<proyecto>-model.json`. Replaces source="db" indexes; preserves source="manual".
Only Oracle supported. After sync, re-run `/rs-erd` to refresh the ERD viewer.
