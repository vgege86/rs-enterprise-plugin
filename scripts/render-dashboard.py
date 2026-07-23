"""
Genera un dashboard HTML autónomo con las estadísticas de ejecución del pipeline.
El HTML (CSS/JS inline, sin dependencias externas) vive en dashboard-template.html; este script
solo calcula las métricas desde executions/history.json e inyecta los datos.

Mismas métricas que /rs-stats (agents/rs-stats.md): total, tasa de éxito, distribución por estado,
top soluciones, agentes más usados y tendencia de 7 días.

Uso: python render-dashboard.py <workspace>
"""

import sys
import json
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path

TEMPLATE_PATH = Path(__file__).parent / "dashboard-template.html"


def _proyecto(workspace: Path) -> str:
    # Carpeta anterior a trunk (igual que el resto del plugin). Si no hay padre claro, cadena vacía.
    p = workspace.parent.name
    return p if p and p != workspace.name else ""


def _load_history(workspace: Path) -> list:
    path = workspace / "executions" / "history.json"
    if not path.exists():
        return []
    try:
        # utf-8-sig: los hooks PowerShell escriben con BOM.
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception:
        return []
    return data if isinstance(data, list) else []


def _day(ts: str) -> str:
    # timestamp "yyyy-MM-ddTHH:mm:ss" → "yyyy-MM-dd" (tolerante a formatos raros).
    return (ts or "")[:10]


def _metrics(history: list) -> dict:
    total = len(history)
    by_status = Counter((e.get("status") or "").lower() for e in history)
    success = by_status.get("success", 0)
    fail = by_status.get("fail", 0)
    partial = by_status.get("partial", 0)

    # Soluciones: total y éxitos por nombre.
    sol_total = Counter()
    sol_ok = Counter()
    for e in history:
        name = e.get("solution") or "(sin nombre)"
        sol_total[name] += 1
        if (e.get("status") or "").lower() == "success":
            sol_ok[name] += 1
    solutions = sorted(
        ({"name": n, "total": t, "success": sol_ok.get(n, 0)} for n, t in sol_total.items()),
        key=lambda s: (-s["total"], s["name"]),
    )

    # Agentes: contar apariciones en el campo agents (lista).
    agent_count = Counter()
    for e in history:
        for a in (e.get("agents") or []):
            agent_count[a] += 1
    agents = sorted(
        ({"name": n, "count": c} for n, c in agent_count.items()),
        key=lambda a: (-a["count"], a["name"]),
    )

    # Tendencia últimos 7 días (calendario, incluyendo hoy). Días sin ejecuciones → ceros.
    today = datetime.now().date()
    days = [today - timedelta(days=i) for i in range(6, -1, -1)]
    per_day = {d.isoformat(): {"total": 0, "success": 0, "fail": 0, "partial": 0} for d in days}
    for e in history:
        d = _day(e.get("timestamp", ""))
        if d in per_day:
            st = (e.get("status") or "").lower()
            per_day[d]["total"] += 1
            if st in ("success", "fail", "partial"):
                per_day[d][st] += 1
    trend = [{"date": d, **per_day[d]} for d in per_day]

    timestamps = sorted(_day(e.get("timestamp", "")) for e in history if e.get("timestamp"))
    return {
        "total": total,
        "success": success,
        "fail": fail,
        "partial": partial,
        "solutions": solutions,
        "agents": agents,
        "trend": trend,
        "period_from": timestamps[0] if timestamps else "",
        "period_to": timestamps[-1] if timestamps else "",
    }


def main():
    if len(sys.argv) < 2:
        print("Uso: render-dashboard.py <workspace>")
        sys.exit(1)

    workspace = Path(sys.argv[1])
    if not TEMPLATE_PATH.exists():
        print(f"ERROR: Plantilla no encontrada: {TEMPLATE_PATH}")
        sys.exit(1)

    proyecto = _proyecto(workspace)
    data = _metrics(_load_history(workspace))
    data["proyecto"] = proyecto

    html = TEMPLATE_PATH.read_text(encoding="utf-8")
    for placeholder, value in [
        ("{proyecto}", proyecto or "workspace"),
        ("{generated_ts}", datetime.now().isoformat(timespec="seconds")),
        ("{data_json}", json.dumps(data, ensure_ascii=False, separators=(",", ":"))),
    ]:
        html = html.replace(placeholder, value)

    out_dir = workspace / "executions"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "dashboard.html"
    out_path.write_text(html, encoding="utf-8")

    print(f"OK — dashboard generado: {out_path}")
    print(f"     {data['total']} ejecuciones | {data['success']} success | "
          f"{len(data['solutions'])} soluciones")


if __name__ == "__main__":
    main()
