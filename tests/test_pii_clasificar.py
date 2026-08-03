"""Modo clasificacion de scripts/pii_cli.py (lo que consume /rs-pii bootstrap).

El inventario del #6 del documento es lo que Sistemas usara para decidir que columnas se
redactan en BD. Si lo produce un clasificador escrito a mano en el prompt del agente, deriva
del real en cuanto uno de los dos cambia y el inventario deja de coincidir con lo que el
plugin enmascara. Estos tests fijan que el veredicto sale del mismo motor que db_query.
"""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

_RAIZ = Path(__file__).resolve().parent.parent
_CLI = _RAIZ / "scripts" / "pii_cli.py"


def _cargar(nombre):
    spec = importlib.util.spec_from_file_location(nombre, _RAIZ / "scripts" / f"{nombre}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mk = _cargar("pii_mask")

MODELO = {
    "pii_policy": {"mode": "audit"},
    "subviews": {"Parametricas": ["RIDIOMA"]},
    "tables": {
        "RDEUDORES": {"columns": {
            "IDDEUDOR": {"type": "NUMBER(10)", "pk": True},
            "NOMBRE":   {"type": "VARCHAR2(60)"},
            "TELEFONO": {"type": "NUMBER(9)"},
            "NUM1":     {"type": "NUMBER(9)"},
            "OBS":      {"type": "VARCHAR2(50)", "safe": True},
        }},
        "RIDIOMA": {"columns": {
            "IDTEXTO": {"type": "VARCHAR2(20)"},
            "TEXTO":   {"type": "VARCHAR2(200)"},
        }},
    },
}


def _clasificar(tmp_path, modelo=MODELO, extra=(), entrada=None):
    ruta = tmp_path / "Proyecto-model.json"
    ruta.write_text(json.dumps(modelo, ensure_ascii=False), encoding="utf-8")
    proc = subprocess.run(
        [sys.executable, str(_CLI), "--clasificar", str(ruta), *extra],
        input=entrada if entrada is not None else "",
        capture_output=True, text=True, encoding="utf-8",
    )
    assert proc.returncode == 0, proc.stderr
    return json.loads(proc.stdout)


def _por_columna(salida, tabla):
    return {c["columna"]: c for c in salida["tablas"].get(tabla, [])}


def test_devuelve_el_modo_y_los_totales(tmp_path):
    out = _clasificar(tmp_path)
    assert out["mode"] == "audit"
    assert out["totales"]["columnas"] == 7
    assert out["totales"]["tablas_analizadas"] == 2


def test_motivos_deterministas_por_columna(tmp_path):
    out = _clasificar(tmp_path, extra=["--todo"])
    rd = _por_columna(out, "RDEUDORES")
    assert rd["IDDEUDOR"] == {"columna": "IDDEUDOR", "veredicto": "claro", "motivo": "tipo"}
    assert rd["NOMBRE"]["veredicto"] == "mascara" and rd["NOMBRE"]["motivo"] == "patron_nombre"
    assert rd["TELEFONO"]["motivo"] == "patron_nombre"
    assert rd["OBS"]["motivo"] == "marca_columna"
    ri = _por_columna(out, "RIDIOMA")
    assert ri["TEXTO"]["veredicto"] == "claro" and ri["TEXTO"]["motivo"] == "parametrica"


def test_por_defecto_solo_devuelve_la_superficie_en_claro(tmp_path):
    out = _clasificar(tmp_path)
    assert "NOMBRE" not in _por_columna(out, "RDEUDORES")     # ya enmascarada
    assert "IDDEUDOR" in _por_columna(out, "RDEUDORES")       # sale en claro


def test_las_muestras_reclasifican_la_columna_y_dan_conteos(tmp_path):
    muestras = {"muestras": {"RDEUDORES": {"NUM1": [
        "600123456", "611222333", "622333444", "1250.00"]}}}
    out = _clasificar(tmp_path, extra=["--tablas", "RDEUDORES"],
                      entrada=json.dumps(muestras))
    num1 = _por_columna(out, "RDEUDORES")["NUM1"]
    assert num1["veredicto"] == "mascara"
    assert num1["sospechosa"] is True
    assert num1["forma"] == "telefono"
    assert num1["coincidencias"] == 3
    assert num1["muestra"] == 4
    assert out["totales"]["sospechosas"] == 1


def test_la_salida_no_contiene_ningun_valor_muestreado(tmp_path):
    # Razon de ser de bootstrap: los valores entran por stdin y no vuelven a salir.
    muestras = {"muestras": {"RDEUDORES": {"NUM1": ["600123456", "611222333"]}}}
    ruta = tmp_path / "Proyecto-model.json"
    ruta.write_text(json.dumps(MODELO, ensure_ascii=False), encoding="utf-8")
    proc = subprocess.run(
        [sys.executable, str(_CLI), "--clasificar", str(ruta)],
        input=json.dumps(muestras), capture_output=True, text=True, encoding="utf-8",
    )
    assert "600123456" not in proc.stdout
    assert "600123456" not in proc.stderr


def test_la_marca_safe_no_exime_de_la_red_de_seguridad(tmp_path):
    # Mismo comportamiento que mask_resultset: la forma de valor puede revertir la marca.
    muestras = {"muestras": {"RDEUDORES": {"OBS": ["12345678Z", "87654321X"]}}}
    out = _clasificar(tmp_path, extra=["--tablas", "RDEUDORES"], entrada=json.dumps(muestras))
    obs = _por_columna(out, "RDEUDORES")["OBS"]
    assert obs["veredicto"] == "mascara"
    assert obs["sospechosa"] is True


def test_el_veredicto_coincide_con_el_que_aplica_mask_resultset(tmp_path):
    # Anclaje del motivo de existir de este modo: mismo motor, mismo veredicto.
    out = _clasificar(tmp_path, extra=["--todo", "--tablas", "RDEUDORES"])
    estatico = {c["columna"]: c["veredicto"] for c in out["tablas"]["RDEUDORES"]}

    columnas = sorted(estatico)
    modelo_enforce = dict(MODELO, pii_policy={"mode": "enforce"})
    _, _, meta = mk.mask_resultset(
        columnas, [["x"] * len(columnas)], "SELECT * FROM RDEUDORES", modelo_enforce,
        clave=b"clave-de-test")
    # meta["masked"] puede incluir columnas tapadas por la red de valor ("x" no dispara
    # ninguna forma, asi que aqui no ocurre): la comparacion es exacta.
    assert sorted(meta["masked"]) == sorted(c for c, v in estatico.items() if v == "mascara")


def test_modelo_inutilizable_sale_con_error(tmp_path):
    ruta = tmp_path / "roto.json"
    ruta.write_text("{ esto no es json", encoding="utf-8")
    proc = subprocess.run(
        [sys.executable, str(_CLI), "--clasificar", str(ruta)],
        input="", capture_output=True, text=True, encoding="utf-8",
    )
    assert proc.returncode != 0
    assert proc.stdout.strip() == ""
