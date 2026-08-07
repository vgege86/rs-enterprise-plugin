"""
Lectura de `BD/<proyecto>-model.json` compartida por los dos generadores de DDL
(`installer-ddl.py` y `generate-sql.py`).

⛔ Por qué es un módulo aparte y no una función en cada uno. Ya pasó con el mapeo de tipos
entre motores: estaba duplicado en los dos ficheros, las copias divergieron en `RAW` y hubo
que unificarlas en `_dbtypes.py`. `pk_columns` es peor candidato aún a divergir, porque su
sutileza (el `bool` es subclase de `int`) no se ve leyendo el código de al lado.

Equivalente Python de `hooks/lib-dbmodel.ps1`, que es quien ESCRIBE estos mismos campos.
"""


def _pos(v) -> int:
    """Ordinal declarado en `pk`, o 0 si no lo declara.

    bool es subclase de int en Python: `True` pasaría por ordinal 1 si no se descarta antes.
    """
    return v if isinstance(v, int) and not isinstance(v, bool) else 0


def _pk_pares(table_def: dict) -> tuple:
    """([(columna, valor_pk)], mixto) — `mixto` = la tabla usa las DOS formas a la vez."""
    cols = [(c, d.get('pk')) for c, d in table_def.get('columns', {}).items() if d.get('pk')]
    con_ordinal = [c for c, v in cols if _pos(v)]
    mixto = bool(con_ordinal) and len(con_ordinal) != len(cols)
    return cols, mixto


def pk_orden_ambiguo(table_def: dict) -> bool:
    """True si la PK de la tabla mezcla ordinales y booleanos.

    El llamante debe AVISAR: con la mezcla no se puede saber el orden real de la clave, así
    que `pk_columns` cae al orden de declaración — que puede no ser el de la PK.
    """
    return _pk_pares(table_def)[1]


def pk_columns(table_def: dict) -> list:
    """Columnas de la PK en su orden real.

    `pk` admite dos formas en el modelo: booleano (orden = el de declaración de las
    columnas) o entero con la posición dentro de la PK (1, 2, 3...). El orden importa:
    es el del índice que respalda la PK, y con el orden cambiado se pierden los accesos
    por prefijo de clave.

    ⛔ Con la tabla en estado MIXTO —unas columnas con ordinal y otras con `true`— no se
    ordena. Antes sí se ordenaba, y era peor que no hacer nada: `true` contaba como ordinal 0
    y se iba al final, así que una PK (A=true, B=2) salía como (B, A), justo invertida. Como
    del `true` no se puede deducir ninguna posición, la única salida honesta es el orden de
    declaración; `pk_orden_ambiguo` está para que el llamante lo diga en voz alta en vez de
    entregar un DDL con la clave reordenada en silencio.

    Quién produce mezclas: `hooks/lib-dbmodel.ps1` escribe siempre el ordinal, también con PK
    de una sola columna. Pero el `model.json` se edita a mano y `references/json-schema.md`
    documenta las dos formas como válidas, así que el consumidor no puede confiar en ello.
    """
    cols, mixto = _pk_pares(table_def)
    if mixto:
        return [c for c, _ in cols]
    if any(_pos(v) for _, v in cols):
        cols.sort(key=lambda cv: _pos(cv[1]))
    return [c for c, _ in cols]


def column_default(col_def: dict) -> str:
    """Expresión DEFAULT de la columna, tal cual la leyó de la BD `hooks/lib-dbmodel.ps1`.

    Cadena vacía = la columna no tiene default. `0` y `'N'` sí son defaults reales, así que la
    comprobación va contra la cadena vacía y nunca contra la falsedad del valor.
    """
    d = col_def.get('default')
    if d is None:
        return ""
    return str(d).strip()
