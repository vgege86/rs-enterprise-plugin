"""Reconoce formas de dato personal en un VALOR, no en el nombre de la columna.

Se usa en dos sitios:
  1. Decidir sobre columnas que no resuelven contra el modelo (alias, expresiones).
  2. Red de seguridad sobre columnas declaradas seguras — si aqui salta algo, la lista
     de patrones de nombre esta incompleta y hay que revisarla.

Sin dependencias: solo `re`. Todas las funciones son puras y no registran los valores
que inspeccionan.
"""
import re

# Formas FUERTES: la estructura es tan especifica que un solo acierto delata la columna.
_FUERTES = {
    "dni":   re.compile(r"^\d{8}[A-HJ-NP-TV-Z]$", re.I),
    "nie":   re.compile(r"^[XYZ]\d{7}[A-HJ-NP-TV-Z]$", re.I),
    "iban":  re.compile(r"^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$", re.I),
    "email": re.compile(r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"),
}

# Formas DEBILES: son solo digitos, asi que un importe puede parecerlas por casualidad.
# Exigen mayoria en la columna para no disparar por un valor suelto.
_DEBILES = {
    "telefono": re.compile(r"^(?:\+34)?[6789]\d{8}$"),
    "tarjeta":  re.compile(r"^\d{13,19}$"),
    "dni_num":  re.compile(r"^\d{8}$"),
}

# Fraccion minima de valores no vacios que deben casar para aceptar una forma debil.
_UMBRAL_DEBIL = 0.50


def detectar(valor):
    """Forma detectada en un valor suelto, o None. Las fuertes tienen prioridad."""
    if valor is None:
        return None
    v = str(valor).strip()
    if not v:
        return None
    for nombre, rx in _FUERTES.items():
        if rx.match(v):
            return nombre
    for nombre, rx in _DEBILES.items():
        if rx.match(v):
            return nombre
    return None


def escanear_columna(valores):
    """Forma dominante de una columna, o None.

    Fuerte -> basta un acierto. Debil -> hace falta superar _UMBRAL_DEBIL sobre los
    valores no vacios. Los vacios no cuentan ni arriba ni abajo.
    """
    no_vacios = [str(v).strip() for v in valores if v is not None and str(v).strip()]
    if not no_vacios:
        return None

    conteo = {}
    for v in no_vacios:
        forma = detectar(v)
        if forma:
            conteo[forma] = conteo.get(forma, 0) + 1

    for nombre in _FUERTES:
        if conteo.get(nombre):
            return nombre

    total = len(no_vacios)
    mejor, mejor_n = None, 0
    for nombre in _DEBILES:
        n = conteo.get(nombre, 0)
        if n / total >= _UMBRAL_DEBIL and n > mejor_n:
            mejor, mejor_n = nombre, n
    return mejor
