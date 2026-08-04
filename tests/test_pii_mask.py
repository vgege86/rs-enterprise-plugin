"""Tests del motor de enmascarado (scripts/pii_mask.py).

La clave se inyecta como parametro para que los tests sean deterministas y no
escriban en el perfil del usuario que ejecuta la suite.
"""
import importlib.util
from pathlib import Path

_RAIZ = Path(__file__).resolve().parent.parent


def _cargar(nombre):
    spec = importlib.util.spec_from_file_location(nombre, _RAIZ / "scripts" / f"{nombre}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mk = _cargar("pii_mask")

CLAVE = b"clave-fija-para-tests-no-usar-en-real"

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

SQL = "SELECT IDDEUDOR, NOMBRE, SALDO FROM RDEUDORES"
COLS = ["IDDEUDOR", "NOMBRE", "SALDO"]
FILAS = [["1024", "Ana Lopez", "1250.00"],
         ["1025", "Luis Gil",  "340.50"],
         ["1026", "Ana Lopez", "980.00"]]


def test_enmascara_solo_la_columna_de_texto():
    _, filas, meta = mk.mask_resultset(COLS, FILAS, SQL, MODELO, clave=CLAVE)
    assert filas[0][0] == "1024"          # pk intacta
    assert filas[0][2] == "1250.00"       # numerico intacto
    assert filas[0][1].startswith("pii:")
    assert meta["masked"] == ["NOMBRE"]


def test_seudonimo_determinista_para_el_mismo_valor():
    _, filas, _ = mk.mask_resultset(COLS, FILAS, SQL, MODELO, clave=CLAVE)
    assert filas[0][1] == filas[2][1]     # "Ana Lopez" en ambas
    assert filas[0][1] != filas[1][1]


def test_seudonimo_no_contiene_el_valor_original():
    _, filas, _ = mk.mask_resultset(COLS, FILAS, SQL, MODELO, clave=CLAVE)
    assert "Ana" not in filas[0][1]
    assert len(filas[0][1]) == len("pii:") + 12


def test_clave_distinta_produce_seudonimo_distinto():
    _, a, _ = mk.mask_resultset(COLS, FILAS, SQL, MODELO, clave=CLAVE)
    _, b, _ = mk.mask_resultset(COLS, FILAS, SQL, MODELO, clave=b"otra-clave")
    assert a[0][1] != b[0][1]


def test_normaliza_relleno_de_char_entre_motores():
    # Oracle rellena CHAR con espacios; SQL Server no. Mismo dato, mismo seudonimo.
    _, a, _ = mk.mask_resultset(["NOMBRE"], [["Ana Lopez   "]], "SELECT NOMBRE FROM RDEUDORES", MODELO, clave=CLAVE)
    _, b, _ = mk.mask_resultset(["NOMBRE"], [["Ana Lopez"]],    "SELECT NOMBRE FROM RDEUDORES", MODELO, clave=CLAVE)
    assert a[0][0] == b[0][0]


def test_modo_off_no_toca_nada():
    modelo = dict(MODELO, pii_policy={"mode": "off"})
    _, filas, meta = mk.mask_resultset(COLS, FILAS, SQL, modelo, clave=CLAVE)
    assert filas[0][1] == "Ana Lopez"
    assert meta["mode"] == "off"


def test_modo_audit_devuelve_en_claro_pero_informa():
    modelo = dict(MODELO, pii_policy={"mode": "audit"})
    _, filas, meta = mk.mask_resultset(COLS, FILAS, SQL, modelo, clave=CLAVE)
    assert filas[0][1] == "Ana Lopez"
    assert meta["masked"] == ["NOMBRE"]     # lo que se HABRIA enmascarado


def test_transform_suppress():
    modelo = dict(MODELO, pii_policy={"mode": "enforce", "transform": "suppress"})
    _, filas, _ = mk.mask_resultset(COLS, FILAS, SQL, modelo, clave=CLAVE)
    assert filas[0][1] == "[PII]"


def test_parametrica_intacta():
    sql = "SELECT IDTEXTO, TEXTO FROM RIDIOMA"
    _, filas, meta = mk.mask_resultset(["IDTEXTO", "TEXTO"], [["e0001", "Aceptar"]], sql, MODELO, clave=CLAVE)
    assert filas[0] == ["e0001", "Aceptar"]
    assert meta["masked"] == []


def test_count_alias_sale_en_claro():
    sql = "SELECT COUNT(*) AS TOTAL FROM RDEUDORES"
    _, filas, meta = mk.mask_resultset(["TOTAL"], [["200"]], sql, MODELO, clave=CLAVE)
    assert filas[0][0] == "200"
    assert "TOTAL" in meta["unresolved"]


def test_alias_sobre_texto_se_enmascara():
    sql = "SELECT NOMBRE || ' ' || APELLIDO AS COMPLETO FROM RDEUDORES"
    _, filas, _ = mk.mask_resultset(["COMPLETO"], [["Ana Lopez"]], sql, MODELO, clave=CLAVE)
    assert filas[0][0].startswith("pii:")


def test_detecta_sospecha_en_columna_declarada_segura():
    modelo = dict(MODELO)
    modelo["tables"] = dict(MODELO["tables"])
    modelo["tables"]["RDEUDORES"] = {"columns": {"NUM1": {"type": "NUMBER(9)"}}}
    sql = "SELECT NUM1 FROM RDEUDORES"
    _, filas, meta = mk.mask_resultset(["NUM1"], [["612345678"], ["699887766"]], sql, modelo, clave=CLAVE)
    assert meta["suspect"] == ["NUM1"]
    assert filas[0][0].startswith("pii:")   # en enforce, la sospecha se enmascara


def test_avisa_de_predicado_sobre_columna_pii():
    sql = "SELECT COUNT(*) AS TOTAL FROM RDEUDORES WHERE NOMBRE = 'Ana Lopez'"
    _, _, meta = mk.mask_resultset(["TOTAL"], [["1"]], sql, MODELO, clave=CLAVE)
    assert "NOMBRE" in meta["predicate_warning"]


def test_fila_mas_corta_que_las_columnas_no_revienta():
    _, filas, _ = mk.mask_resultset(COLS, [["1024", "Ana Lopez"]], SQL, MODELO, clave=CLAVE)
    assert len(filas[0]) == 2


def test_red_de_seguridad_no_se_salta_en_columna_parametrica():
    # Fija que la red de seguridad (escanear_columna sobre un veredicto CLARO) se
    # dispara tambien cuando el CLARO llega por la via "parametrica" (regla 3), no
    # solo por la via "tipo" (regla 4, ya cubierta por
    # test_detecta_sospecha_en_columna_declarada_segura). El gate en el codigo es un
    # unico "if veredicto == CLARO" que no distingue el motivo, y asi debe seguir:
    # un refactor que separe las ramas y solo escanee la via "tipo" dejaria pasar en
    # claro una parametrica con forma personal sin que ningun test lo note.
    sql = "SELECT TEXTO FROM RIDIOMA"
    valor_con_forma_personal = "usuario.prueba@ejemplo-ficticio.com"
    _, filas, meta = mk.mask_resultset(["TEXTO"], [[valor_con_forma_personal]], sql, MODELO, clave=CLAVE)
    assert meta["masked"] == ["TEXTO"]
    assert meta["suspect"] == ["TEXTO"]
    assert filas[0][0].startswith("pii:")


def test_red_de_seguridad_no_se_salta_en_columna_marcada_safe():
    # Fija que una marca explicita "safe": true en el modelo NO exime de la red de
    # seguridad. Confiar ciegamente en la marca es justo lo que la red existe para
    # cuestionar: si un futuro cambio la salta con el razonamiento de "la columna ya
    # esta declarada segura, no hace falta escanear", reintroduce una fuga en claro
    # de forma silenciosa, sin que ningun test falle.
    modelo = dict(MODELO)
    modelo["tables"] = dict(MODELO["tables"])
    modelo["tables"]["RDEUDORES"] = {"columns": {"OBS": {"type": "VARCHAR2(50)", "safe": True}}}
    sql = "SELECT OBS FROM RDEUDORES"
    _, filas, meta = mk.mask_resultset(["OBS"], [["12345678Z"]], sql, modelo, clave=CLAVE)
    assert meta["masked"] == ["OBS"]
    assert meta["suspect"] == ["OBS"]
    assert filas[0][0].startswith("pii:")


def test_celdas_none_y_en_blanco_no_generan_seudonimo():
    # Fija que una celda vacia (None, "" o solo espacios) nunca se transforma en un
    # seudonimo. Un seudonimo de la cadena vacia seria un token estable y adivinable
    # que revelaria cuales celdas estan en blanco -- justo lo que la guarda del bucle
    # de transformacion evita al comprobar "str(valor).strip()" antes de enmascarar.
    sql = "SELECT NOMBRE FROM RDEUDORES"
    filas_entrada = [["Ana Lopez"], [None], [""], ["   "]]
    _, filas, _ = mk.mask_resultset(["NOMBRE"], filas_entrada, sql, MODELO, clave=CLAVE)
    assert filas[0][0].startswith("pii:")
    assert filas[1][0] is None
    assert filas[2][0] == ""
    assert filas[3][0] == "   "


# --- Modelo en forma de LISTA -------------------------------------------------
# mcp/rs-workspace-server.py admite las dos formas de modelo (tables como dict y como
# lista de objetos con "name") en seis sitios. El enmascarado asumia solo la de dict y
# reventaba con AttributeError ante la otra: la tool MCP se caia (sin datos) y el hook
# caia por su rama de fallo abierto (todos los datos en claro). Una misma forma de
# modelo producia resultados OPUESTOS en los dos caminos.

MODELO_LISTA = {
    "pii_policy": {"mode": "enforce"},
    "subviews": {"Parametricas": ["RIDIOMA"]},
    "tables": [
        {"name": "RDEUDORES", "columns": [
            {"name": "IDDEUDOR", "type": "NUMBER(10)", "pk": True},
            {"name": "NOMBRE",   "type": "VARCHAR2(60)"},
            {"name": "SALDO",    "type": "NUMBER(12,2)"},
        ]},
        {"name": "RIDIOMA", "columns": [
            {"name": "IDTEXTO", "type": "VARCHAR2(20)"},
            {"name": "TEXTO",   "type": "VARCHAR2(200)"},
        ]},
    ],
}


def test_modelo_en_lista_enmascara_igual_que_en_dict():
    cols, filas, meta = mk.mask_resultset(
        COLS, [["1024", "Ana Lopez", "1250.00"]], SQL, MODELO_LISTA, clave=CLAVE)
    assert cols == COLS
    assert filas[0][0] == "1024"
    assert filas[0][1].startswith("pii:")
    assert filas[0][2] == "1250.00"
    assert meta["masked"] == ["NOMBRE"]
    assert meta["unresolved"] == []


def test_modelo_en_lista_respeta_las_parametricas():
    sql = "SELECT IDTEXTO, TEXTO FROM RIDIOMA"
    _, filas, meta = mk.mask_resultset(
        ["IDTEXTO", "TEXTO"], [["SALUDO", "Hola"]], sql, MODELO_LISTA, clave=CLAVE)
    assert filas[0] == ["SALUDO", "Hola"]
    assert meta["masked"] == []


def test_modelo_en_lista_y_en_dict_dan_el_mismo_resultado():
    a = mk.mask_resultset(COLS, [["1024", "Ana Lopez", "1250.00"]], SQL, MODELO, clave=CLAVE)
    b = mk.mask_resultset(COLS, [["1024", "Ana Lopez", "1250.00"]], SQL, MODELO_LISTA, clave=CLAVE)
    assert a == b
