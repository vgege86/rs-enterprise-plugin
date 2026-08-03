"""Extrae de un SQL las tablas consultadas y las columnas usadas como filtro.

No es un parser de SQL. Reconoce las formas habituales en las consultas que generan
los agentes. Lo que no reconoce hace que la columna quede "no resuelta", y una columna
no resuelta se enmascara: la imprecision degrada hacia el lado seguro, nunca al reves.
"""
import re

# FROM/JOIN seguido del nombre, admitiendo "ESQUEMA . TABLA". El parentesis de una
# subconsulta no casa (no esta en la clase de caracteres), asi que se ignora y se
# recoge la tabla de dentro en la siguiente coincidencia.
_RE_TABLA = re.compile(
    r"\b(?:FROM|JOIN)\s+([A-Za-z_][\w$#]*(?:\s*\.\s*[A-Za-z_][\w$#]*)?)",
    re.I,
)

# Columna a la izquierda de un comparador dentro del WHERE. Admite el alias delante
# ("d.NOMBRE"), del que solo interesa la parte de la columna.
_RE_PREDICADO = re.compile(
    r"\b(?:[A-Za-z_][\w$#]*\s*\.\s*)?([A-Za-z_][\w$#]*)\s*"
    r"(?:=|<>|!=|<|>|<=|>=|\bLIKE\b|\bIN\b|\bBETWEEN\b)",
    re.I,
)

# Tablas que nunca aportan datos y ensucian el ambito.
_IGNORADAS = {"DUAL"}


def _normalizar(bruto):
    nombre = re.sub(r"\s+", "", bruto)
    if "." in nombre:
        nombre = nombre.rsplit(".", 1)[1]
    return nombre.upper()


def _unicos(seq):
    vistos, salida = set(), []
    for x in seq:
        if x not in vistos:
            vistos.add(x)
            salida.append(x)
    return salida


def tablas(sql):
    """Tablas del FROM/JOIN, en mayusculas, sin esquema, sin duplicados, en orden."""
    if not sql:
        return []
    encontradas = [_normalizar(m.group(1)) for m in _RE_TABLA.finditer(sql)]
    return _unicos(t for t in encontradas if t and t not in _IGNORADAS)


def predicados(sql):
    """Columnas usadas como filtro en el WHERE, en mayusculas, sin duplicados.

    Alimenta el aviso pii_predicate_warning: filtrar por una columna PII permite
    inferir su valor aunque la salida vaya enmascarada (ver seccion 5.2c del documento
    docs/proteccion-pii-consultas-bd.md). Se avisa, no se bloquea.
    """
    if not sql:
        return []
    partes = re.split(r"\bWHERE\b", sql, maxsplit=1, flags=re.I)
    if len(partes) < 2:
        return []
    return _unicos(m.group(1).upper() for m in _RE_PREDICADO.finditer(partes[1]))
