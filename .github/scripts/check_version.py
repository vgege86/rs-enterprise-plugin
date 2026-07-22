#!/usr/bin/env python
"""Verifica invariantes de publicación del plugin (referencia: docs/plugin-architecture.md §10):

1. La versión de .claude-plugin/plugin.json y la de .claude-plugin/marketplace.json coinciden.
2. CHANGELOG.md tiene una entrada '## <version>' para esa versión.

Sale con código != 0 si algo falla, listando todos los problemas. Ejecutable en local:
    python .github/scripts/check_version.py
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def _load(path: pathlib.Path) -> dict:
    # utf-8-sig: los JSON del plugin pueden llevar BOM (los escriben hooks PowerShell).
    return json.loads(path.read_text(encoding="utf-8-sig"))


def main() -> int:
    errores = []

    plugin = _load(ROOT / ".claude-plugin" / "plugin.json")
    market = _load(ROOT / ".claude-plugin" / "marketplace.json")

    pv = str(plugin.get("version", ""))
    plugins = market.get("plugins") or [{}]
    mv = str(plugins[0].get("version", ""))

    if not pv:
        errores.append("plugin.json no declara 'version'")
    if not mv:
        errores.append("marketplace.json no declara plugins[0].version")
    if pv and mv and pv != mv:
        errores.append(f"versiones divergentes: plugin.json={pv} vs marketplace.json={mv}")

    if pv:
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        # Cabecera de entrada: '## <version>' (permite sufijo como ' — fecha').
        if not re.search(rf"^##\s+{re.escape(pv)}\b", changelog, re.MULTILINE):
            errores.append(f"CHANGELOG.md sin entrada '## {pv}'")

    if errores:
        for e in errores:
            print(f"ERROR: {e}", file=sys.stderr)
        return 1

    print(f"OK: version {pv} consistente (plugin.json == marketplace.json) y con entrada en CHANGELOG.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
