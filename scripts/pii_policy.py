"""Clasifica cada columna de un resultset como en claro, enmascarada o no resuelta.

Precedencia (documentada en docs/proteccion-pii-consultas-bd.md #4.2):

  1. Marca explicita en la columna del modelo ("pii": true / "safe": true)
  2. Patron de nombre sensible                  -> enmascarar
  3. Tabla parametrica (subviews.Parametricas)  -> en claro
  4. Tipo numerico, fecha, PK o FK              -> en claro
  5. Resto de texto                             -> enmascarar
  6. Columna que no resuelve                    -> NO_RESUELTA (decide el valor)

La marca explicita va primero a proposito: es la valvula de escape para cuando las
reglas automaticas se equivocan, y tiene que ganar siempre.
"""
import fnmatch
import json
from pathlib import Path

import importlib.util

CLARO = "claro"
MASCARA = "mascara"
NO_RESUELTA = "no_resuelta"

_RAIZ = Path(__file__).resolve().parent
_PATRONES_BASE = _RAIZ / "pii_patterns.json"


def _cargar_modulo(nombre):
    spec = importlib.util.spec_from_file_location(nombre, _RAIZ / f"{nombre}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_det = _cargar_modulo("pii_detect")

# Prefijos de tipo que salen en claro sin mas comprobaciones.
_TIPOS_CLARO = (
    "NUMBER", "NUMERIC", "INT", "BIGINT", "SMALLINT", "TINYINT",
    "DECIMAL", "DEC", "FLOAT", "REAL", "DOUBLE", "MONEY", "BIT",
    "DATE", "TIMESTAMP", "DATETIME", "SMALLDATETIME", "TIME",
)


def _patrones_base():
    try:
        datos = json.loads(_PATRONES_BASE.read_text(encoding="utf-8"))
        return list(datos.get("patrones") or [])
    except Exception:
        # Sin lista base seguimos funcionando: el default de texto sigue tapando lo
        # textual. Solo se pierde la deteccion por nombre sobre columnas numericas.
        return []


def cargar_politica(modelo):
    """Combina los patrones base con los ajustes del workspace.

    modelo["pii_policy"] admite: mode (off|audit|enforce), transform (hash|suppress),
    patterns_add (list), patterns_remove (list).
    """
    cfg = (modelo or {}).get("pii_policy") or {}
    patrones = _patrones_base()
    patrones += list(cfg.get("patterns_add") or [])
    quitar = {p.upper() for p in (cfg.get("patterns_remove") or [])}
    patrones = [p for p in patrones if p.upper() not in quitar]

    subviews = (modelo or {}).get("subviews") or {}
    parametricas = {t.upper() for t in (subviews.get("Parametricas") or [])}

    return {
        "mode": cfg.get("mode", "off"),
        "transform": cfg.get("transform", "hash"),
        "patrones": [p.upper() for p in patrones],
        "parametricas": parametricas,
    }


def _definiciones(columna, tablas, modelo):
    """[(tabla, coldef)] de la columna en las tablas del ambito."""
    salida = []
    tablas_modelo = (modelo or {}).get("tables") or {}
    for t in tablas:
        tdef = tablas_modelo.get(t) or tablas_modelo.get(t.upper())
        if not tdef:
            continue
        cols = tdef.get("columns") or {}
        cdef = cols.get(columna) or cols.get(columna.upper())
        if cdef is not None:
            salida.append((t.upper(), cdef))
    return salida


def _casa_patron(columna, politica):
    return any(fnmatch.fnmatch(columna, p) for p in politica["patrones"])


def _claro_por_tipo(coldef):
    if coldef.get("pk") or coldef.get("fk"):
        return True
    tipo = str(coldef.get("type", "")).upper().strip()
    return tipo.startswith(_TIPOS_CLARO)


def clasificar(columna, tablas, modelo, politica):
    """(veredicto, motivo) para una columna del resultset."""
    col = str(columna).upper().strip()
    defs = _definiciones(col, tablas, modelo)

    # 1. Marca explicita. Ante tablas en conflicto gana la mas restrictiva.
    marcas = [d.get("pii") is True or d.get("safe") is False for _, d in defs]
    if any(marcas):
        return MASCARA, "marca_columna"
    if defs and all(d.get("safe") is True for _, d in defs):
        return CLARO, "marca_columna"

    # 2. Patron de nombre. Aplica aunque la columna no este en el modelo.
    if _casa_patron(col, politica):
        return MASCARA, "patron_nombre"

    if not defs:
        return NO_RESUELTA, "sin_definicion"

    # 3. Parametrica: en claro solo si TODAS las tablas del ambito lo son.
    if all(t in politica["parametricas"] for t, _ in defs):
        return CLARO, "parametrica"

    # 4. Tipo: en claro solo si TODAS las definiciones lo permiten.
    if all(_claro_por_tipo(d) for _, d in defs):
        return CLARO, "tipo"

    # 5. Resto.
    return MASCARA, "texto"


def resolver_no_resuelta(valores):
    """Decide una columna NO_RESUELTA por la forma de sus valores.

    Mantiene util `SELECT COUNT(*) AS TOTAL` sin dejar pasar `SUBSTR(DNI,1,8) AS X`:
    numerico limpio -> claro; cualquier forma personal o cualquier texto -> mascara.
    """
    forma = _det.escanear_columna(valores)
    if forma:
        return MASCARA, "forma_%s" % forma

    no_vacios = [str(v).strip() for v in valores if v is not None and str(v).strip()]
    if not no_vacios:
        return CLARO, "vacia"

    def _es_numero(v):
        try:
            float(v.replace(",", "."))
            return True
        except ValueError:
            return False

    if all(_es_numero(v) for v in no_vacios):
        return CLARO, "valores_numericos"
    return MASCARA, "valores_no_numericos"
