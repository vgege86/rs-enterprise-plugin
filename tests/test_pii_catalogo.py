"""Excepcion de catalogo del enmascarado (scripts/pii_catalogo.py + pii_mask.mask_resultset).

POR QUE EXISTE. Con mode=enforce, una consulta a ALL_TAB_COLUMNS / ALL_TRIGGERS / ALL_SOURCE
devolvia nombres de columna y cuerpos de trigger como `pii:xxxx`, y el agente acababa
sorteando el filtro (CASE -> numeros). Desde 3.28.0 lo que SOLO lee estructura sale en claro.
Aqui se fijan las dos mitades: que la estructura sale en claro, y que por la excepcion no se
cuela nada de negocio (funciones en el SELECT, tablas mezcladas, LOW_VALUE/HIGH_VALUE...).
"""
import importlib.util
from pathlib import Path

import pytest

_RAIZ = Path(__file__).resolve().parent.parent


def _cargar(nombre):
    spec = importlib.util.spec_from_file_location(nombre, _RAIZ / "scripts" / f"{nombre}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mk = _cargar("pii_mask")
cat = _cargar("pii_catalogo")
scope = _cargar("pii_sqlscope")

CLAVE = b"clave-fija-para-tests-no-usar-en-real"
MODELO = {
    "pii_policy": {"mode": "enforce"},
    "tables": {
        "RDEUDORES": {"columns": {
            "IDDEUDOR": {"type": "NUMBER(10)", "pk": True},
            "NIF":      {"type": "VARCHAR2(12)"},
        }},
    },
}


def _es(sql, modelo=MODELO):
    return cat.es_consulta_catalogo(sql, modelo, scope._strip_comments)


# ---------------------------------------------------------------------------------------------
# Lo que SI es consulta de catalogo
# ---------------------------------------------------------------------------------------------
@pytest.mark.parametrize("sql", [
    "SELECT COLUMN_NAME, DATA_TYPE, NULLABLE FROM ALL_TAB_COLUMNS WHERE TABLE_NAME = 'RCARTERA' ORDER BY COLUMN_ID",
    "SELECT c.COLUMN_NAME, c.DATA_TYPE FROM SYS.ALL_TAB_COLUMNS c WHERE c.OWNER = 'RS'",
    "SELECT TRIGGER_NAME, TRIGGER_BODY FROM USER_TRIGGERS WHERE TABLE_NAME = 'RCARTERA'",
    "SELECT NAME, LINE, TEXT FROM ALL_SOURCE WHERE NAME = 'TRG_RCARTERA_DEL' ORDER BY LINE",
    "SELECT NAME, LINE, TEXT FROM ALL_SOURCE WHERE UPPER(TEXT) LIKE '%FROM RCARTERA%'",
    "SELECT * FROM ALL_TAB_COLUMNS WHERE TABLE_NAME = 'RCARTERA'",
    "SELECT t.TABLE_NAME, c.COLUMN_NAME FROM ALL_TABLES t JOIN ALL_TAB_COLUMNS c ON c.TABLE_NAME = t.TABLE_NAME",
    "SELECT COLUMN_NAME AS COL FROM USER_TAB_COLUMNS",
    "SELECT TABLE_NAME, COLUMN_NAME, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS",
    "SELECT name, type_desc FROM sys.objects WHERE type = 'TR'",
    "SELECT definition FROM sys.sql_modules WHERE object_id = 123",
    "-- columnas\nSELECT COLUMN_NAME FROM ALL_TAB_COLUMNS /* x */ WHERE TABLE_NAME = 'A'",
])
def test_si_es_catalogo(sql):
    assert _es(sql) is True


# ---------------------------------------------------------------------------------------------
# Lo que NO: cualquier via para sacar datos de negocio
# ---------------------------------------------------------------------------------------------
@pytest.mark.parametrize("sql", [
    # Tabla de negocio en el ambito (join, coma, subconsulta)
    "SELECT c.COLUMN_NAME, d.NIF FROM ALL_TAB_COLUMNS c JOIN RDEUDORES d ON 1 = 1",
    "SELECT COLUMN_NAME FROM ALL_TAB_COLUMNS, RDEUDORES",
    "SELECT COLUMN_NAME FROM ALL_TAB_COLUMNS WHERE EXISTS (SELECT 1 FROM RDEUDORES WHERE NIF LIKE '1%')",
    # Funciones, expresiones, literales y subconsultas escalares en el SELECT
    "SELECT PKG_DEUDOR.GET_NIF(1) FROM ALL_TABLES",
    "SELECT GET_NIF FROM ALL_TABLES",  # funcion sin parentesis (Oracle lo admite)
    "SELECT (SELECT NIF FROM RDEUDORES WHERE ROWNUM = 1) AS TABLE_NAME FROM ALL_TABLES",
    "SELECT DBMS_XMLGEN.GETXML('SELECT NIF FROM RDEUDORES') FROM ALL_TABLES",
    "SELECT TABLE_NAME || 'x' FROM ALL_TABLES",
    "SELECT CASE WHEN 1 = 1 THEN TABLE_NAME END FROM ALL_TABLES",
    # Conjuntos y CTE
    "SELECT TABLE_NAME FROM ALL_TABLES UNION SELECT NIF FROM RDEUDORES",
    "WITH x AS (SELECT NIF FROM RDEUDORES) SELECT * FROM x",
    # Vistas de catalogo que contienen datos reales, fuera de la lista
    "SELECT ENDPOINT_ACTUAL_VALUE FROM ALL_TAB_HISTOGRAMS",
    "SELECT SQL_TEXT FROM V$SQL",
    # SQL Server sin calificar: "COLUMNS" puede ser una tabla de negocio
    "SELECT COLUMN_NAME FROM COLUMNS",
    # SQL malformado
    "SELECT COLUMN_NAME FROM ALL_TAB_COLUMNS WHERE TABLE_NAME = 'sin cerrar",
    "",
])
def test_no_es_catalogo(sql):
    assert _es(sql) is False


def test_gana_el_modelo_si_una_tabla_propia_se_llama_como_una_vista():
    modelo = {"pii_policy": {"mode": "enforce"},
              "tables": {"USER_OBJECTS": {"columns": {"NAME": {"type": "VARCHAR2(60)"}}}}}
    assert _es("SELECT NAME FROM USER_OBJECTS", modelo) is False


# ---------------------------------------------------------------------------------------------
# Extremo a extremo por mask_resultset
# ---------------------------------------------------------------------------------------------
def test_nombres_de_columna_salen_en_claro():
    sql = "SELECT COLUMN_ID, COLUMN_NAME, DATA_TYPE FROM ALL_TAB_COLUMNS WHERE TABLE_NAME = 'RCARTERA'"
    cols = ["COLUMN_ID", "COLUMN_NAME", "DATA_TYPE"]
    filas = [["35", "CAAPORTEXPERIAN", "VARCHAR2"], ["34", "CAOTRA", "NUMBER"]]
    _, salida, meta = mk.mask_resultset(cols, filas, sql, MODELO, clave=CLAVE)
    assert salida == filas
    assert meta["catalog"] is True
    assert meta["masked"] == []


def test_cuerpo_de_trigger_sale_en_claro():
    sql = "SELECT TRIGGER_NAME, TRIGGER_BODY FROM USER_TRIGGERS WHERE TABLE_NAME = 'RCARTERA'"
    cuerpo = "BEGIN INSERT INTO RCARTERA_DEL (ID, CAAPORTEXPERIAN) VALUES (:OLD.ID, :OLD.CAAPORTEXPERIAN); END;"
    _, salida, meta = mk.mask_resultset(["TRIGGER_NAME", "TRIGGER_BODY"], [["TRG_DEL", cuerpo]], sql, MODELO, clave=CLAVE)
    assert salida == [["TRG_DEL", cuerpo]]
    assert meta["masked"] == []


def test_low_value_high_value_siguen_enmascarados_con_select_estrella():
    sql = "SELECT * FROM ALL_TAB_COLUMNS WHERE TABLE_NAME = 'RDEUDORES'"
    cols = ["TABLE_NAME", "COLUMN_NAME", "LOW_VALUE", "HIGH_VALUE"]
    filas = [["RDEUDORES", "NIF", "3030303030303031", "3939393939393939"]]
    _, salida, meta = mk.mask_resultset(cols, filas, sql, MODELO, clave=CLAVE)
    assert salida[0][:2] == ["RDEUDORES", "NIF"]
    assert salida[0][2].startswith("pii:") and salida[0][3].startswith("pii:")
    assert set(meta["masked"]) == {"LOW_VALUE", "HIGH_VALUE"}


def test_dato_personal_dentro_del_codigo_se_sustituye_solo_el_trozo():
    # Un trigger con un DNI y un correo escritos a mano: el codigo sigue legible, el dato no.
    sql = "SELECT NAME, LINE, TEXT FROM ALL_SOURCE WHERE NAME = 'TRG_X'"
    filas = [["TRG_X", "1", "IF :NEW.NIF = '12345678Z' THEN"],
             ["TRG_X", "2", "  v_mail := 'ana.perez@empresa.es';"],
             ["TRG_X", "3", "END IF;"]]
    _, salida, meta = mk.mask_resultset(["NAME", "LINE", "TEXT"], filas, sql, MODELO, clave=CLAVE)
    assert salida[0][2].startswith("IF :NEW.NIF = 'pii:") and salida[0][2].endswith("' THEN")
    assert "12345678Z" not in salida[0][2]
    assert "ana.perez@empresa.es" not in salida[1][2] and salida[1][2].startswith("  v_mail := 'pii:")
    assert salida[2][2] == "END IF;"
    assert meta["redacted"] == ["TEXT"] and "TEXT" in meta["suspect"]
    assert "TEXT" not in meta["masked"]


def test_en_audit_se_informa_pero_no_se_sustituye():
    modelo = {**MODELO, "pii_policy": {"mode": "audit"}}
    sql = "SELECT TEXT FROM ALL_SOURCE"
    _, salida, meta = mk.mask_resultset(["TEXT"], [["x := '12345678Z';"]], sql, modelo, clave=CLAVE)
    assert salida == [["x := '12345678Z';"]]
    assert meta["redacted"] == ["TEXT"]


@pytest.mark.parametrize("texto,esperado", [
    ("v := '12345678Z';", 1),           # DNI con letra correcta
    ("v := '12345678A';", 0),           # letra incorrecta: no es un DNI
    ("carpeta PROD_20260803A", 0),      # convencion de entregas: pegado a '_' no cuenta
    ("nie X1234567L", 1),
    ("cuenta ES91 2100 0418 4502 0005 1332", 1),
    ("ES9121000418450200051332", 1),
    ("aviso a soporte@empresa.com hoy", 1),
    ("WHERE CAMPO = 600123456", 0),     # 9 digitos: forma debil, no se busca en codigo
    (":OLD.CAAPORTEXPERIAN", 0),
])
def test_buscar_en_texto(texto, esperado):
    assert len(cat.buscar_en_texto(texto)) == esperado


def test_consulta_mixta_sigue_las_reglas_normales():
    sql = "SELECT c.COLUMN_NAME, d.NIF FROM ALL_TAB_COLUMNS c JOIN RDEUDORES d ON 1 = 1"
    _, salida, meta = mk.mask_resultset(["COLUMN_NAME", "NIF"], [["NIF", "12345678Z"]], sql, MODELO, clave=CLAVE)
    assert meta["catalog"] is False
    assert salida[0][1].startswith("pii:")
    assert salida[0][0].startswith("pii:")  # no resuelta + texto -> enmascarada, como antes


def test_en_off_no_cambia_nada():
    modelo = {"pii_policy": {"mode": "off"}}
    sql = "SELECT COLUMN_NAME FROM ALL_TAB_COLUMNS"
    _, salida, meta = mk.mask_resultset(["COLUMN_NAME"], [["X"]], sql, modelo, clave=CLAVE)
    assert salida == [["X"]] and meta["catalog"] is False
