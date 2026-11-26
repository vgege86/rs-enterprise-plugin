"""
Lectura del historial de ejecuciones repartido por desarrollador (`scripts/render-dashboard.py`).

⛔ Por qué existe. Hasta la 3.26.x había un único `executions/history.json` y cada ejecución se
insertaba al PRINCIPIO del array: con varios desarrolladores sobre el mismo trunk, todos tocaban
las mismas líneas del mismo fichero y SVN daba conflicto en cada update. Desde 3.27.0 cada uno
escribe en `executions/history/<dev>.json` y los lectores juntan. Lo que se fija aquí es que
juntar no pierda ni duplique nada:

  1. Se leen todos los ficheros vivos de desarrollador + el `history.json` antiguo.
  2. Los `<dev>-archive-AAAAMM.json` NO se leen (igual que antes no se leía history-archive-*).
  3. Una entrada copiada entre ficheros (mismo `id`) cuenta una vez.
  4. Un fichero con UN solo objeto (no array), como los escribía ConvertTo-Json por pipeline,
     se lee igual.
  5. Si falta `developer`, se toma del nombre del fichero; en el `history.json` antiguo, vacío.
"""
import importlib.util
import json
from pathlib import Path

_RAIZ = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("render_dashboard", _RAIZ / "scripts" / "render-dashboard.py")
rd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rd)


def _escribir(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Con BOM, como lo escribe Set-Content -Encoding UTF8 en Windows PowerShell 5.1.
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8-sig")


def _ws(tmp_path: Path) -> Path:
    ws = tmp_path / "Proyecto" / "trunk"
    h = ws / "executions" / "history"
    _escribir(h / "ana.json", [
        {"id": "a1", "timestamp": "2026-11-25T10:00:00", "developer": "ana", "solution": "RSProcIN", "status": "success"},
        {"id": "a2", "timestamp": "2026-11-20T10:00:00", "developer": "ana", "solution": "AgendaWeb", "status": "fail"},
    ])
    _escribir(h / "luis.json", {"id": "b1", "timestamp": "2026-11-26T09:00:00", "solution": "RSProcIN", "status": "success"})
    _escribir(h / "luis-archive-202601.json", [{"id": "x9", "timestamp": "2026-01-01T00:00:00", "status": "success"}])
    _escribir(ws / "executions" / "history.json", [
        {"id": "a1", "timestamp": "2026-11-25T10:00:00", "solution": "RSProcIN", "status": "success"},
        {"id": "z0", "timestamp": "2026-10-01T10:00:00", "solution": "Viejo", "status": "partial"},
    ])
    return ws


def test_junta_ficheros_sin_archivo_ni_duplicados(tmp_path):
    entradas = rd._load_history(_ws(tmp_path))
    assert [e["id"] for e in entradas] == ["b1", "a1", "a2", "z0"]  # más reciente primero


def test_developer_del_nombre_de_fichero_y_vacio_en_el_antiguo(tmp_path):
    por_id = {e["id"]: e for e in rd._load_history(_ws(tmp_path))}
    assert por_id["b1"]["developer"] == "luis"
    assert por_id["a1"]["developer"] == "ana"
    assert not por_id["z0"].get("developer")


def test_metrica_por_desarrollador(tmp_path):
    devs = {d["name"]: d for d in rd._metrics(rd._load_history(_ws(tmp_path)))["developers"]}
    assert devs["ana"] == {"name": "ana", "total": 2, "success": 1}
    assert devs["luis"]["total"] == 1
    assert devs["(sin registrar)"]["total"] == 1


def test_sin_historial(tmp_path):
    assert rd._load_history(tmp_path) == []
    assert rd._metrics([])["developers"] == []
