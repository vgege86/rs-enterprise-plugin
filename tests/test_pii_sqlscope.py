"""Tests de la extraccion de tablas y predicados del SQL (scripts/pii_sqlscope.py).

No es un parser de SQL y no pretende serlo: reconoce las formas que aparecen en las
consultas que generan los agentes. Lo que no reconoce degrada a "no resuelta", que
acaba enmascarado — falla cerrada por construccion.
"""
import importlib.util
from pathlib import Path

_MOD = Path(__file__).resolve().parent.parent / "scripts" / "pii_sqlscope.py"
_spec = importlib.util.spec_from_file_location("pii_sqlscope", _MOD)
sc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sc)


def test_from_simple():
    assert sc.tablas("SELECT * FROM RDEUDORES") == ["RDEUDORES"]


def test_minusculas_a_mayusculas():
    assert sc.tablas("select * from rdeudores") == ["RDEUDORES"]


def test_quita_prefijo_de_esquema():
    assert sc.tablas("SELECT * FROM UCOLLECT.RDEUDORES") == ["RDEUDORES"]


def test_ignora_alias():
    assert sc.tablas("SELECT d.NOMBRE FROM RDEUDORES d") == ["RDEUDORES"]


def test_join():
    sql = "SELECT * FROM RDEUDORES d JOIN REXPEDIENTES e ON e.ID = d.IDEXP"
    assert sc.tablas(sql) == ["RDEUDORES", "REXPEDIENTES"]


def test_dual_no_cuenta():
    assert sc.tablas("SELECT 1 FROM dual") == []


def test_sin_duplicados_preservando_orden():
    sql = "SELECT * FROM RDEUDORES a JOIN RDEUDORES b ON a.ID = b.PADRE JOIN RPAGOS p ON p.ID = a.ID"
    assert sc.tablas(sql) == ["RDEUDORES", "RPAGOS"]


def test_subconsulta_en_from_no_rompe():
    # El parentesis no casa como nombre de tabla; se recoge la tabla interior.
    assert sc.tablas("SELECT * FROM (SELECT * FROM RDEUDORES) x") == ["RDEUDORES"]


def test_predicados_igualdad_y_like():
    sql = "SELECT COUNT(*) FROM RDEUDORES WHERE DNI LIKE '1234%' AND d.NOMBRE = 'X'"
    assert sc.predicados(sql) == ["DNI", "NOMBRE"]


def test_predicados_sin_where():
    assert sc.predicados("SELECT * FROM RDEUDORES") == []


def test_tablas_ignora_linea_comentada_con_tabla():
    # Un comentario de linea no debe inyectar una tabla
    sql = "SELECT NOMBRE -- FROM TABLASEGURA\nFROM RDEUDORES WHERE DNI = '1'"
    assert sc.tablas(sql) == ["RDEUDORES"]


def test_tablas_ignora_bloque_comentado_con_tabla():
    # Un bloque comentado no debe inyectar una tabla
    sql = "SELECT * /* FROM FAKETABLE */ FROM RDEUDORES"
    assert sc.tablas(sql) == ["RDEUDORES"]


def test_tablas_ignora_bloque_comentado_multilinea():
    # Un bloque comentado en multiples lineas no debe inyectar una tabla
    sql = """SELECT *
    /* FROM FAKETABLE
       JOIN OTRATABLA ON ...
    */ FROM RDEUDORES"""
    assert sc.tablas(sql) == ["RDEUDORES"]


def test_guion_dentro_de_string_no_es_comentario():
    # Una secuencia -- dentro de un string literal no es comentario
    sql = "SELECT * FROM RDEUDORES WHERE COD = 'A--B'"
    assert sc.tablas(sql) == ["RDEUDORES"]
    assert sc.predicados(sql) == ["COD"]


def test_barra_asterisco_dentro_de_string_no_rompe():
    # Una secuencia /* dentro de un string literal no es comentario
    sql = "SELECT * FROM RDEUDORES WHERE NOTA = 'a/*b'"
    assert sc.tablas(sql) == ["RDEUDORES"]
    assert sc.predicados(sql) == ["NOTA"]


def test_predicados_ignora_columna_en_comentario():
    # Una columna mencionada solo dentro de un comentario no se reporta
    sql = "SELECT COL FROM RDEUDORES WHERE -- OLD_COL = 'X' AND\nCOL = 'Y'"
    assert sc.predicados(sql) == ["COL"]


def test_tablas_falla_seguro_con_literal_no_cerrado_linea_comentada():
    # SQL malformado con string no cerrado y comentario despu­es.
    # Alcance indeterminable: retorna [] (ni la tabla real ni ninguna falsa).
    sql = "SELECT * FROM RDEUDORES WHERE X = 'abc -- FROM FAKETABLE"
    assert sc.tablas(sql) == []


def test_tablas_falla_seguro_con_literal_no_cerrado_bloque_comentado():
    # SQL malformado con string no cerrado y bloque comentado despu­es.
    # Alcance indeterminable: retorna [] (ni la tabla real ni ninguna falsa).
    sql = "SELECT * FROM RDEUDORES WHERE X = 'abc /* FROM FAKETABLE */ AND Y=1"
    assert sc.tablas(sql) == []


def test_predicados_falla_seguro_con_literal_no_cerrado():
    # SQL malformado con string no cerrado.
    # Alcance indeterminable: retorna [] (ninguna columna).
    sql = "SELECT * FROM RDEUDORES WHERE X = 'abc -- FROM FAKETABLE"
    assert sc.predicados(sql) == []


def test_regresion_literal_bien_formado_seguido_de_comentario():
    # Regression: un literal bien formado seguido de comentario debe funcionar.
    # No confundir el early-out de unterminated con "any quote disables stripping".
    sql = "SELECT * FROM RDEUDORES WHERE COD = 'A--B' -- FROM FAKETABLE"
    assert sc.tablas(sql) == ["RDEUDORES"]
    assert sc.predicados(sql) == ["COD"]


# --- Join antiguo por comas (SQL heredado de uCollect) ---
# Solo se recogia la PRIMERA tabla; todas las columnas de las demas caian a "no resuelta"
# y las decidia la forma de sus valores, que es donde un identificador numerico largo
# podia colarse en claro.

def test_tablas_join_por_comas_con_alias():
    assert sc.tablas("SELECT * FROM RDEUDORES d, REXPEDIENTES e WHERE d.ID = e.ID") == \
        ["RDEUDORES", "REXPEDIENTES"]


def test_tablas_join_por_comas_sin_alias():
    assert sc.tablas("SELECT * FROM RDEUDORES, REXPEDIENTES") == ["RDEUDORES", "REXPEDIENTES"]


def test_tablas_join_por_comas_tres_tablas():
    assert sc.tablas("SELECT * FROM A a, B b, C c") == ["A", "B", "C"]


def test_tablas_join_por_comas_con_esquema():
    assert sc.tablas("SELECT * FROM ESQ.RDEUDORES d, ESQ.REXPEDIENTES e") == \
        ["RDEUDORES", "REXPEDIENTES"]


def test_tablas_join_por_comas_con_as_explicito():
    assert sc.tablas("SELECT * FROM RDEUDORES AS d, REXPEDIENTES AS e") == \
        ["RDEUDORES", "REXPEDIENTES"]


def test_tablas_order_by_con_comas_no_cuela_columnas_como_tablas():
    assert sc.tablas("SELECT a, b FROM T ORDER BY a, b") == ["T"]


def test_tablas_group_by_con_comas_no_cuela_columnas_como_tablas():
    assert sc.tablas("SELECT a FROM T GROUP BY a, b") == ["T"]


def test_tablas_in_con_lista_de_valores_no_cuela_nada():
    assert sc.tablas("SELECT * FROM T WHERE x IN (1,2)") == ["T"]
