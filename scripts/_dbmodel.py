"""
Lectura de `BD/<proyecto>-model.json` compartida por los dos generadores de DDL
(`installer-ddl.py` y `generate-sql.py`).

⛔ Por qué es un módulo aparte y no una función en cada uno. Ya pasó con el mapeo de tipos
entre motores: estaba duplicado en los dos ficheros, las copias divergieron en `RAW` y hubo
que unificarlas en `_dbtypes.py`. `pk_columns` es peor candidato aún a divergir, porque su
sutileza (el `bool` es subclase de `int`) no se ve leyendo el código de al lado.

Equivalente Python de `hooks/lib-dbmodel.ps1`, que es quien ESCRIBE estos mismos campos.
"""


def pk_columns(table_def: dict) -> list:
    """Columnas de la PK en su orden real.

    `pk` admite dos formas en el modelo: booleano (orden = el de declaración de las
    columnas) o entero con la posición dentro de la PK (1, 2, 3...). El orden importa:
    es el del índice que respalda la PK, y con el orden cambiado se pierden los accesos
    por prefijo de clave.

    ⛔ El modelo tiene que ser coherente DENTRO de una tabla: o todas las columnas de la PK
    llevan ordinal o ninguna. Mezclarlas ordena mal — una columna con `pk: true` cuenta como
    ordinal 0 y se va al final, aunque fuera la primera de la clave. Por eso
    `hooks/lib-dbmodel.ps1` escribe siempre el ordinal, también cuando la PK es de una sola
    columna: uniforme es lo único que es correcto.
    """
    cols = [(c, d.get('pk')) for c, d in table_def.get('columns', {}).items() if d.get('pk')]

    def pos(v):
        # bool es subclase de int: hay que descartarlo antes de tratarlo como ordinal
        return v if isinstance(v, int) and not isinstance(v, bool) else 0

    if any(pos(v) for _, v in cols):
        # sort estable: las que no declaran ordinal mantienen su orden relativo al final
        cols.sort(key=lambda cv: (pos(cv[1]) == 0, pos(cv[1])))
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
