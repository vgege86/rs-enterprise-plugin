"""Los DOS caminos de enmascarado tienen que dar exactamente el mismo resultado.

La tool MCP db_query llama a mask_resultset directamente; hooks/db-query.ps1 llama al
mismo motor a traves de scripts/pii_cli.py. Que sea un solo motor es toda la arquitectura:
la guarda de solo-lectura ya esta duplicada entre ambos, y una divergencia en la politica
PII no seria un error visible sino una fuga silenciosa por uno de los dos lados.

Nada lo comprobaba. Los tres hallazgos criticos de la revision final -- modelo en forma de
lista, resolucion del modelo por glob, y conexion= sin su modelo -- vivian justo en ese
hueco: cada camino estaba probado por separado y ninguno contra el otro.

Alcance de la comparacion: mask_resultset (lo que usa el MCP) contra pii_cli.py (lo que
invoca el hook), con el MISMO (modelo, sql, columns, rows). No cubre el tramo de
PowerShell de hooks/db-query.ps1 -- parseo CSV de sqlplus, construccion de la matriz,
ramas de fallo -- porque requeriria una BD; ese tramo lo cubre tests/PiiGuard.Tests.ps1
con sqlplus mockeado.
"""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

_RAIZ = Path(__file__).resolve().parent.parent
_CLI = _RAIZ / "scripts" / "pii_cli.py"


def _cargar(nombre):
    spec = importlib.util.spec_from_file_location(nombre, _RAIZ / "scripts" / f"{nombre}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mk = _cargar("pii_mask")


MODELO = {
    "pii_policy": {"mode": "enforce"},
    "subviews": {"Parametricas": ["RIDIOMA"]},
    "tables": {
        "RDEUDORES": {"columns": {
            "IDDEUDOR": {"type": "NUMBER(10)", "pk": True},
            "NOMBRE":   {"type": "VARCHAR2(60)"},
            "SALDO":    {"type": "NUMBER(12,2)"},
        }},
        "RIDIOMA": {"columns": {
            "IDTEXTO": {"type": "VARCHAR2(20)"},
            "TEXTO":   {"type": "VARCHAR2(200)"},
        }},
    },
}

MODELO_OFF = dict(MODELO, pii_policy={"mode": "off"})

# tables en forma de lista: la otra forma real de modelo del codebase.
MODELO_LISTA = {
    "pii_policy": {"mode": "enforce"},
    "subviews": {"Parametricas": ["RIDIOMA"]},
    "tables": [
        {"name": "RDEUDORES", "columns": [
            {"name": "IDDEUDOR", "type": "NUMBER(10)", "pk": True},
            {"name": "NOMBRE",   "type": "VARCHAR2(60)"},
            {"name": "SALDO",    "type": "NUMBER(12,2)"},
        ]},
    ],
}


# (id, modelo, sql, columns, rows)
CASOS = [
    (
        "columna_texto_enmascarada",
        MODELO,
        "SELECT IDDEUDOR, NOMBRE, SALDO FROM RDEUDORES",
        ["IDDEUDOR", "NOMBRE", "SALDO"],
        [["1024", "Ana Lopez", "1250.00"], ["1025", "Luis Gomez", "340.50"]],
    ),
    (
        "tabla_parametrica_en_claro",
        MODELO,
        "SELECT IDTEXTO, TEXTO FROM RIDIOMA",
        ["IDTEXTO", "TEXTO"],
        [["SALUDO", "Hola"], ["ADIOS", "Adios"]],
    ),
    (
        "alias_no_resuelto_decidido_por_forma",
        MODELO,
        "SELECT SUBSTR(DNI,1,8) AS X, COUNT(*) AS TOTAL FROM RDEUDORES GROUP BY SUBSTR(DNI,1,8)",
        ["X", "TOTAL"],
        [["12345678", "3"], ["87654321", "1"]],
    ),
    (
        "modo_off_no_toca_nada",
        MODELO_OFF,
        "SELECT IDDEUDOR, NOMBRE FROM RDEUDORES",
        ["IDDEUDOR", "NOMBRE"],
        [["1024", "Ana Lopez"]],
    ),
    (
        "aviso_de_predicado_sobre_columna_pii",
        MODELO,
        "SELECT COUNT(*) AS TOTAL FROM RDEUDORES WHERE DNI LIKE '1234%'",
        ["TOTAL"],
        [["3"]],
    ),
    (
        "modelo_en_forma_de_lista",
        MODELO_LISTA,
        "SELECT IDDEUDOR, NOMBRE FROM RDEUDORES",
        ["IDDEUDOR", "NOMBRE"],
        [["1024", "Ana Lopez"]],
    ),
    (
        "join_antiguo_por_comas",
        MODELO,
        "SELECT d.NOMBRE, i.TEXTO FROM RDEUDORES d, RIDIOMA i WHERE d.IDDEUDOR = 1",
        ["NOMBRE", "TEXTO"],
        [["Ana Lopez", "Hola"]],
    ),
    (
        "celdas_vacias_y_nulas",
        MODELO,
        "SELECT NOMBRE FROM RDEUDORES",
        ["NOMBRE"],
        [["Ana Lopez"], [None], [""], ["   "]],
    ),
]


def _por_el_cli(tmp_path, modelo, sql, columns, rows, entorno):
    """Lo que devuelve el camino del hook: scripts/pii_cli.py con el modelo en disco."""
    ruta_modelo = tmp_path / "Proyecto-model.json"
    ruta_modelo.write_text(json.dumps(modelo, ensure_ascii=False), encoding="utf-8")
    entrada = json.dumps({"columns": columns, "rows": rows, "sql": sql}, ensure_ascii=False)
    proc = subprocess.run(
        [sys.executable, str(_CLI), str(tmp_path), str(ruta_modelo)],
        input=entrada, capture_output=True, text=True, encoding="utf-8", env=entorno,
    )
    assert proc.returncode == 0, proc.stderr
    return json.loads(proc.stdout)


def _por_mask_resultset(modelo, sql, columns, rows):
    """Lo que devuelve el camino MCP, normalizado a JSON para comparar peras con peras."""
    cols, filas, meta = mk.mask_resultset(columns, rows, sql, modelo)
    return json.loads(json.dumps({"columns": cols, "rows": filas, "pii": meta},
                                 ensure_ascii=False))


@pytest.mark.parametrize("caso", CASOS, ids=[c[0] for c in CASOS])
def test_los_dos_caminos_dan_el_mismo_resultado(caso, tmp_path, monkeypatch):
    _, modelo, sql, columns, rows = caso

    # Misma clave HMAC en los dos caminos, y en tmp_path: sin esto los seudonimos no
    # coincidirian (no es una divergencia de politica) y ademas se tocaria el perfil del
    # usuario que ejecuta la suite. pii_mask.ruta_clave() lee LOCALAPPDATA en cada llamada,
    # asi que basta con fijarlo aqui; el subproceso lo hereda.
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "appdata"))
    import os
    entorno = dict(os.environ)

    a = _por_mask_resultset(modelo, sql, columns, rows)
    b = _por_el_cli(tmp_path, modelo, sql, columns, rows, entorno)

    assert a["columns"] == b["columns"]
    assert a["rows"] == b["rows"]
    assert a["pii"] == b["pii"]


def test_el_caso_de_columna_enmascarada_realmente_enmascara():
    # Guarda contra un falso verde: si mask_resultset dejara de enmascarar, los dos
    # caminos seguirian coincidiendo y la comparacion de arriba pasaria igual.
    _, filas, meta = mk.mask_resultset(
        ["IDDEUDOR", "NOMBRE", "SALDO"],
        [["1024", "Ana Lopez", "1250.00"]],
        "SELECT IDDEUDOR, NOMBRE, SALDO FROM RDEUDORES",
        MODELO,
    )
    assert meta["masked"] == ["NOMBRE"]
    assert filas[0][1].startswith(mk.PREFIJO)


def test_el_caso_de_predicado_realmente_avisa():
    _, _, meta = mk.mask_resultset(
        ["TOTAL"], [["3"]],
        "SELECT COUNT(*) AS TOTAL FROM RDEUDORES WHERE DNI LIKE '1234%'",
        MODELO,
    )
    assert meta["predicate_warning"] == ["DNI"]


# --- Modelo declarado y ausente: los dos caminos tienen que decir lo mismo ---
# El MCP lo resuelve en _cargar_modelo (config["model_declarado"]) y el hook pasandole
# --convenio a este CLI. Si divergen vuelve el agujero: un camino error, el otro mode=off
# con las filas en claro.

def _ejecutar_cli(argumentos, entrada, entorno=None):
    return subprocess.run([sys.executable, str(_CLI)] + argumentos, input=entrada,
                          capture_output=True, text=True, encoding="utf-8", env=entorno)


_ENTRADA = json.dumps({"columns": ["NOMBRE"], "rows": [["Ana Lopez"]],
                       "sql": "SELECT NOMBRE FROM RDEUDORES"})


def test_cli_modelo_declarado_ausente_es_error(tmp_path):
    ausente = tmp_path / "declarado-model.json"
    proc = _ejecutar_cli([str(tmp_path), str(ausente)], _ENTRADA)
    assert proc.returncode != 0
    assert proc.stdout == ""                      # ni una fila sale por stdout
    assert ausente.name in proc.stderr
    assert "/rs-init" in proc.stderr and "/rs-erd" in proc.stderr


def test_cli_modelo_por_convenio_ausente_es_mode_off(tmp_path):
    ausente = tmp_path / "BD" / "Proyecto-model.json"
    proc = _ejecutar_cli([str(tmp_path), str(ausente), "--convenio"], _ENTRADA)
    assert proc.returncode == 0
    salida = json.loads(proc.stdout)
    assert salida["pii"]["mode"] == "off"
    assert salida["rows"] == [["Ana Lopez"]]


def test_cli_modelo_corrupto_es_error_aunque_venga_del_convenio(tmp_path):
    # --convenio solo excusa la AUSENCIA del fichero. Uno que existe y no se puede parsear
    # es un workspace roto venga la ruta de donde venga, igual que en _cargar_modelo.
    roto = tmp_path / "Proyecto-model.json"
    roto.write_text("{ esto no es json", encoding="utf-8")
    proc = _ejecutar_cli([str(tmp_path), str(roto), "--convenio"], _ENTRADA)
    assert proc.returncode != 0
    assert proc.stdout == ""
