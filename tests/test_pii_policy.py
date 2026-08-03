"""Tests de la clasificacion de columnas (scripts/pii_policy.py).

Modelo de BD simulado en memoria: ni ficheros ni BD. Cubre la tabla de precedencia
documentada en docs/proteccion-pii-consultas-bd.md §4.2.
"""
import importlib.util
from pathlib import Path

import pytest

_RAIZ = Path(__file__).resolve().parent.parent


def _cargar(nombre):
    ruta = _RAIZ / "scripts" / f"{nombre}.py"
    spec = importlib.util.spec_from_file_location(nombre, ruta)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


pol = _cargar("pii_policy")


MODELO = {
    "subviews": {"Parametricas": ["RIDIOMA", "RCONTROLES", "RVERSIONES", "RMODULOS"]},
    "tables": {
        "RDEUDORES": {"columns": {
            "IDDEUDOR":  {"type": "NUMBER(10)", "pk": True},
            "NOMBRE":    {"type": "VARCHAR2(60)"},
            "DNI":       {"type": "VARCHAR2(9)"},
            "TELEFONO":  {"type": "NUMBER(9)"},
            "SALDO":     {"type": "NUMBER(12,2)"},
            "FECHA_ALTA": {"type": "DATE"},
            "OBSERVACIONES": {"type": "VARCHAR2(4000)"},
            "CUENTA_CONTABLE": {"type": "VARCHAR2(20)"},
            "COD_POSTAL": {"type": "VARCHAR2(5)", "safe": True},
            "REFERENCIA": {"type": "NUMBER(10)", "pii": True},
        }},
        "RIDIOMA": {"columns": {
            "IDTEXTO": {"type": "VARCHAR2(20)"},
            "TEXTO":   {"type": "VARCHAR2(200)"},
        }},
    },
}

POL = pol.cargar_politica(MODELO)


@pytest.mark.parametrize("columna,esperado,motivo", [
    ("SALDO",           pol.CLARO,   "tipo"),            # numerico
    ("FECHA_ALTA",      pol.CLARO,   "tipo"),            # fecha
    ("IDDEUDOR",        pol.CLARO,   "tipo"),            # pk
    ("OBSERVACIONES",   pol.MASCARA, "texto"),           # texto sin marca ni patron
    ("NOMBRE",          pol.MASCARA, "patron_nombre"),   # NOMBRE* esta en la lista base
    ("DNI",             pol.MASCARA, "patron_nombre"),   # patron gana al tipo
    ("TELEFONO",        pol.MASCARA, "patron_nombre"),   # NUMBER pero es telefono
    ("COD_POSTAL",      pol.CLARO,   "marca_columna"),   # safe:true sobre texto
    ("REFERENCIA",      pol.MASCARA, "marca_columna"),   # pii:true sobre numerico
])
def test_precedencia(columna, esperado, motivo):
    v, m = pol.clasificar(columna, ["RDEUDORES"], MODELO, POL)
    assert (v, m) == (esperado, motivo)


def test_parametrica_sale_en_claro_aunque_sea_texto():
    v, m = pol.clasificar("TEXTO", ["RIDIOMA"], MODELO, POL)
    assert (v, m) == (pol.CLARO, "parametrica")


def test_columna_desconocida_no_resuelve():
    v, m = pol.clasificar("TOTAL", ["RDEUDORES"], MODELO, POL)
    assert v == pol.NO_RESUELTA


def test_tabla_desconocida_no_resuelve():
    v, _ = pol.clasificar("LO_QUE_SEA", ["RTABLA_NUEVA"], MODELO, POL)
    assert v == pol.NO_RESUELTA


def test_patron_aplica_sin_definicion_en_el_modelo():
    # Alias que se llama EMAIL_CONTACTO: no esta en el modelo, pero el nombre canta.
    v, m = pol.clasificar("EMAIL_CONTACTO", ["RTABLA_NUEVA"], MODELO, POL)
    assert (v, m) == (pol.MASCARA, "patron_nombre")


def test_colision_entre_tablas_gana_lo_restrictivo():
    # DATO no casa ningun patron: obliga a que decida la comparacion de tipos entre
    # las dos definiciones, que es justo lo que se quiere probar.
    modelo = {
        "subviews": {"Parametricas": []},
        "tables": {
            "T1": {"columns": {"DATO": {"type": "NUMBER(5)"}}},
            "T2": {"columns": {"DATO": {"type": "VARCHAR2(60)"}}},
        },
    }
    p = pol.cargar_politica(modelo)
    v, m = pol.clasificar("DATO", ["T1", "T2"], modelo, p)
    assert (v, m) == (pol.MASCARA, "texto")


def test_patterns_remove_libera_cuenta_contable():
    modelo = dict(MODELO, pii_policy={"patterns_remove": ["*CUENTA*"]})
    p = pol.cargar_politica(modelo)
    v, m = pol.clasificar("CUENTA_CONTABLE", ["RDEUDORES"], modelo, p)
    assert (v, m) == (pol.MASCARA, "texto")   # sigue tapada por ser texto, no por el patron


def test_patterns_add_del_workspace():
    modelo = dict(MODELO, pii_policy={"patterns_add": ["SALDO*"]})
    p = pol.cargar_politica(modelo)
    v, m = pol.clasificar("SALDO", ["RDEUDORES"], modelo, p)
    assert (v, m) == (pol.MASCARA, "patron_nombre")


def test_no_resuelta_numerica_sale_en_claro():
    v, m = pol.resolver_no_resuelta(["200", "1250.00", "3"])
    assert (v, m) == (pol.CLARO, "valores_numericos")


def test_no_resuelta_con_forma_de_telefono_se_enmascara():
    v, m = pol.resolver_no_resuelta(["612345678", "699887766"])
    assert (v, m) == (pol.MASCARA, "forma_telefono")


def test_no_resuelta_de_texto_se_enmascara():
    v, m = pol.resolver_no_resuelta(["Madrid", "Sevilla"])
    assert (v, m) == (pol.MASCARA, "valores_no_numericos")


def test_modo_por_defecto_es_off():
    assert pol.cargar_politica({})["mode"] == "off"


def test_transform_por_defecto_es_hash():
    assert pol.cargar_politica({})["transform"] == "hash"


# --- Fix round 1: formas numericas estrictas en resolver_no_resuelta ---

@pytest.mark.parametrize("valores", [
    ["+441234567", "+447911123456"],   # movil internacional, no es la forma ES
    ["nan", "NaN", "inf"],             # grammar de float() de Python, no una cantidad
    ["1_000", "2_000"],                # separador de miles, no una cantidad plana
])
def test_no_resuelta_formas_rechazadas_se_enmascaran(valores):
    v, m = pol.resolver_no_resuelta(valores)
    assert v == pol.MASCARA


def test_no_resuelta_negativo_sale_en_claro():
    # Un saldo negativo es una cantidad legitima: el signo '-' se mantiene permitido.
    v, m = pol.resolver_no_resuelta(["-1250.00"])
    assert (v, m) == (pol.CLARO, "valores_numericos")


def test_no_resuelta_entero_largo_sin_decimales_se_enmascara():
    # 9+ digitos sin parte decimal es la forma de un identificador (telefono, cuenta,
    # contrato, tarjeta), no de una cantidad o un conteo.
    v, m = pol.resolver_no_resuelta(["123456789"])
    assert (v, m) == (pol.MASCARA, "valores_no_numericos")


def test_no_resuelta_entero_de_8_digitos_lo_decide_la_forma_dni():
    # 8 digitos exactos es la forma dni_num del detector de valores: se enmascara,
    # pero por un motivo distinto al de un entero largo sin forma reconocida. Se
    # afirma el motivo para mantener los dos caminos distinguibles.
    v, m = pol.resolver_no_resuelta(["12345678"])
    assert (v, m) == (pol.MASCARA, "forma_dni_num")


def test_no_resuelta_agregados_ordinarios_no_se_ven_afectados():
    assert pol.resolver_no_resuelta(["1250.00"]) == (pol.CLARO, "valores_numericos")
    assert pol.resolver_no_resuelta(["200"]) == (pol.CLARO, "valores_numericos")


def test_no_resuelta_todo_vacio_se_enmascara():
    # Cero informacion no debe producir la respuesta permisiva.
    v, m = pol.resolver_no_resuelta(["", None, "   "])
    assert (v, m) == (pol.MASCARA, "vacia")


def test_patrones_base_falla_cerrado_si_falta_el_fichero(monkeypatch, tmp_path):
    ruta_falsa = tmp_path / "no_existe.json"
    monkeypatch.setattr(pol, "_PATRONES_BASE", ruta_falsa)
    p = pol.cargar_politica({})
    assert p["patrones"] == ["*"]
    modelo = {"tables": {"CUALQUIER_TABLA": {"columns": {
        "CUALQUIER_COLUMNA": {"type": "VARCHAR2(10)"},
    }}}}
    v, m = pol.clasificar("CUALQUIER_COLUMNA", ["CUALQUIER_TABLA"], modelo, p)
    assert (v, m) == (pol.MASCARA, "patron_nombre")


def test_patrones_base_falla_cerrado_si_el_fichero_es_json_invalido(monkeypatch, tmp_path):
    ruta_mala = tmp_path / "roto.json"
    ruta_mala.write_text("{ no es json valido", encoding="utf-8")
    monkeypatch.setattr(pol, "_PATRONES_BASE", ruta_mala)
    p = pol.cargar_politica({})
    assert p["patrones"] == ["*"]


def test_patterns_remove_libera_columna_numerica_telefono_a_proposito():
    # Comportamiento deliberado, no un bug: si el workspace quita el patron, la
    # valvula de escape gana y la columna sale por tipo. La red de seguridad por
    # forma de valor sobre columnas que salen en claro la anade la Tarea 4.
    modelo = dict(MODELO, pii_policy={"patterns_remove": ["TELEFON*"]})
    p = pol.cargar_politica(modelo)
    v, m = pol.clasificar("TELEFONO", ["RDEUDORES"], modelo, p)
    assert (v, m) == (pol.CLARO, "tipo")
