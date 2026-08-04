"""Tests del detector de formas de dato personal (scripts/pii_detect.py).

Puro: sin BD, sin ficheros, sin red. Todos los valores son inventados —
NUNCA meter datos reales de cliente en un test.
"""
import importlib.util
from pathlib import Path

import pytest

_MOD = Path(__file__).resolve().parent.parent / "scripts" / "pii_detect.py"
_spec = importlib.util.spec_from_file_location("pii_detect", _MOD)
det = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(det)


@pytest.mark.parametrize("valor,esperado", [
    ("12345678Z",          "dni"),
    ("X1234567L",          "nie"),
    ("612345678",          "telefono"),
    ("+34612345678",       "telefono"),
    ("ES9121000418450200051332", "iban"),
    ("nadie@ejemplo.test", "email"),
    ("4111111111111111",   "tarjeta"),
    ("12345678",           "dni_num"),
])
def test_detecta_formas(valor, esperado):
    assert det.detectar(valor) == esperado


@pytest.mark.parametrize("valor", ["", "   ", "200", "1250.00", "Madrid", "ES", None])
def test_no_detecta_valores_inocuos(valor):
    assert det.detectar(valor) is None


def test_forma_fuerte_basta_un_valor():
    # Un solo email en 200 filas ya delata la columna.
    valores = ["x"] * 199 + ["nadie@ejemplo.test"]
    assert det.escanear_columna(valores) == "email"


def test_forma_debil_exige_mayoria():
    # Un unico numero de 9 digitos puede ser un importe: no basta.
    assert det.escanear_columna(["1", "2", "612345678"]) is None


def test_forma_debil_supera_umbral():
    assert det.escanear_columna(["612345678", "699887766", "1"]) == "telefono"


def test_ignora_vacios_al_calcular_el_umbral():
    assert det.escanear_columna(["612345678", "", None, "   "]) == "telefono"
