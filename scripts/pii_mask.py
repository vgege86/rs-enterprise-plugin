"""Aplica la politica PII a un resultset antes de que entre en el contexto.

Punto unico de transformacion: lo consumen la tool MCP db_query y, via pii_cli.py,
el hook hooks/db-query.ps1. Que sea uno solo es deliberado - la guarda de solo-lectura
esta duplicada entre ambos caminos y una divergencia aqui seria una fuga silenciosa.

La clave HMAC vive en el perfil local del usuario, NUNCA en el repositorio.
"""
import hashlib
import hmac
import importlib.util
import os
import secrets
from pathlib import Path

_RAIZ = Path(__file__).resolve().parent


def _cargar_modulo(nombre):
    spec = importlib.util.spec_from_file_location(nombre, _RAIZ / f"{nombre}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_pol = _cargar_modulo("pii_policy")
_scope = _cargar_modulo("pii_sqlscope")
_det = _cargar_modulo("pii_detect")

PREFIJO = "pii:"
LONGITUD_HEX = 12
MARCA_SUPRESION = "[PII]"


def ruta_clave():
    """%LOCALAPPDATA%\\rs-enterprise-agent\\pii.key, con fallback a ~ fuera de Windows."""
    base = os.environ.get("LOCALAPPDATA")
    raiz = Path(base) if base else Path.home()
    return raiz / "rs-enterprise-agent" / "pii.key"


def cargar_clave():
    """Lee la clave; la crea con 32 bytes aleatorios si no existe.

    Rotarla invalida los seudonimos anteriores: dejan de correlacionar con los nuevos.
    Es aceptable - no hay nada que descifrar, solo se pierde comparabilidad historica.
    """
    ruta = ruta_clave()
    if ruta.exists():
        return ruta.read_bytes()
    ruta.parent.mkdir(parents=True, exist_ok=True)
    clave = secrets.token_bytes(32)
    ruta.write_bytes(clave)
    return clave


def _normalizar(valor):
    """Colapsa espacios para que Oracle (CHAR con relleno) y SQL Server coincidan.

    Sin esto, /rs-comparar-entornos reportaria como divergentes dos filas identicas.
    """
    return " ".join(str(valor).split())


def seudonimo(valor, dominio, clave):
    """HMAC-SHA256(clave, dominio + valor normalizado), truncado.

    El dominio es el nombre de columna: el mismo DNI en RDEUDORES y RCONTACTOS da el
    mismo seudonimo si la columna se llama igual, que es lo que permite correlacionar.
    """
    mensaje = ("%s|%s" % (dominio.upper(), _normalizar(valor))).encode("utf-8")
    return PREFIJO + hmac.new(clave, mensaje, hashlib.sha256).hexdigest()[:LONGITUD_HEX]


def _columna(filas, i):
    return [f[i] for f in filas if i < len(f)]


def mask_resultset(columns, rows, sql, modelo, clave=None):
    """(columns, rows, meta). No muta las listas de entrada.

    meta = {mode, masked, unresolved, suspect, predicate_warning, tables}
      masked            columnas enmascaradas (en audit: las que se HABRIAN enmascarado)
      unresolved        columnas que no resuelven contra el modelo
      suspect           columnas en claro cuyos VALORES tienen forma personal -> revisar
      predicate_warning columnas PII usadas como filtro (ver #5.2c del documento)
    """
    politica = _pol.cargar_politica(modelo)
    modo = politica["mode"]
    tablas = _scope.tablas(sql)

    meta = {
        "mode": modo,
        "masked": [],
        "unresolved": [],
        "suspect": [],
        "predicate_warning": [],
        "tables": tablas,
    }

    if modo == "off":
        return list(columns), [list(f) for f in rows], meta

    a_enmascarar = []
    for i, col in enumerate(columns):
        veredicto, motivo = _pol.clasificar(col, tablas, modelo, politica)

        if veredicto == _pol.NO_RESUELTA:
            meta["unresolved"].append(col)
            veredicto, motivo = _pol.resolver_no_resuelta(_columna(rows, i))

        if veredicto == _pol.CLARO:
            # Red de seguridad: si lo que sale en claro TIENE forma personal, la lista
            # de patrones esta incompleta. Se avisa y, en enforce, se tapa igualmente.
            if _det.escanear_columna(_columna(rows, i)):
                meta["suspect"].append(col)
                veredicto = _pol.MASCARA

        if veredicto == _pol.MASCARA:
            meta["masked"].append(col)
            a_enmascarar.append(i)

    # Aviso de predicado: filtrar por una columna PII permite inferir su valor aunque
    # la salida vaya enmascarada. Se avisa, no se bloquea (rompe el filtrado legitimo).
    # Se clasifica el predicado CONTRA LA POLITICA, no contra meta["masked"]: el caso
    # peligroso es justo "SELECT COUNT(*) ... WHERE DNI LIKE '1234%'", donde la unica
    # columna devuelta es numerica y masked va vacio.
    meta["predicate_warning"] = [
        c for c in _scope.predicados(sql)
        if _pol.clasificar(c, tablas, modelo, politica)[0] == _pol.MASCARA
    ]

    if modo == "audit":
        return list(columns), [list(f) for f in rows], meta

    if clave is None:
        clave = cargar_clave()
    suprimir = politica["transform"] == "suppress"

    salida = []
    for fila in rows:
        nueva = list(fila)
        for i in a_enmascarar:
            if i < len(nueva) and nueva[i] is not None and str(nueva[i]).strip():
                nueva[i] = MARCA_SUPRESION if suprimir else seudonimo(nueva[i], columns[i], clave)
        salida.append(nueva)

    return list(columns), salida, meta
