"""
Genera un fichero HTML autónomo con el ERD del modelo JSON.
El HTML interactivo (CSS/JS) vive en erd-template.html; este script solo inyecta datos.

Uso: python render-erd.py <workspace> <proyecto>
"""

import sys
import json
from pathlib import Path
from datetime import datetime, timezone

TEMPLATE_PATH = Path(__file__).parent / "erd-template.html"


def main():
    if len(sys.argv) < 3:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto>")
        sys.exit(1)

    workspace  = sys.argv[1]
    proyecto   = sys.argv[2]
    model_path = Path(workspace) / "BD" / f"{proyecto}-model.json"

    if not model_path.exists():
        print(f"ERROR: Modelo no encontrado: {model_path}")
        sys.exit(1)

    if not TEMPLATE_PATH.exists():
        print(f"ERROR: Plantilla no encontrada: {TEMPLATE_PATH}")
        sys.exit(1)

    # utf-8-sig: los hooks PowerShell (PS5.1) escriben model.json con Set-Content -Encoding
    # UTF8, que SIEMPRE antepone BOM — utf-8-sig lo tolera (y funciona igual sin BOM).
    with open(model_path, encoding="utf-8-sig") as f:
        model = json.load(f)

    tables    = model.get("tables", {})
    n         = len(tables)
    rel_count = sum(len(t.get("relations", [])) for t in tables.values())
    model_json = json.dumps(model, ensure_ascii=False, separators=(",", ":"))

    # El tamaño de lienzo y el modo compacto los calcula ahora resizeCanvas() en el cliente:
    # el HTML puede cargar otro modelo en caliente ("Abrir modelo…") y debe redimensionarse solo.
    html = TEMPLATE_PATH.read_text(encoding="utf-8")
    for placeholder, value in [
        ("{proyecto}",    proyecto),
        ("{table_count}", str(n)),
        ("{rel_count}",   str(rel_count)),
        ("{model_json}",  model_json),
        ("{render_ts}",   datetime.now(timezone.utc).isoformat(timespec="seconds")),
    ]:
        html = html.replace(placeholder, value)

    out_path = Path(workspace) / "BD" / f"{proyecto}-erd.html"
    out_path.write_text(html, encoding="utf-8")

    print(f"OK — ERD generado: {out_path}")
    print(f"     {n} tablas | {rel_count} relaciones")
    if model.get("subviews"):
        print(f"     Subvistas: {', '.join(model['subviews'].keys())}")


if __name__ == "__main__":
    main()
