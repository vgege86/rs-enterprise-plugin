"""
⛔ RETIRADO. El DDL de tablas del instalador ya NO se genera desde `BD/<proyecto>-model.json`.

Lo genera `scripts/installer-tablas.py`, leyendo la BD viva.

POR QUÉ ESTE FICHERO SIGUE AQUÍ EN VEZ DE BORRARSE

    Para que nada vuelva a generar el DDL desde el modelo EN SILENCIO. Si se borrara, un
    llamante antiguo daría "no such file" —un error de infraestructura, que se arregla
    restaurando el fichero— en vez de decir qué ha cambiado y por qué. Aquí el error explica
    la decisión, y eso es lo que hay que leer antes de "arreglarlo".

QUÉ PASÓ

    La traducción BD -> model.json es lossy y el modelo se queda desfasado. Medido en una
    entrega real: 12 FK -> 0, 3 CHECK -> 0, 1 IDENTITY -> columna NUMBER pelada, 22 DEFAULT ->
    21, columnas con el tamaño de hace meses, y RAW sin longitud (ORA-00906: el DDL entregado
    no compilaba). Ninguna de esas pérdidas daba error al generar; todas lo daban en el
    servidor del cliente.

    El modelo se sigue manteniendo, pero su papel es DOCUMENTACIÓN y POLÍTICA PII
    (descripciones, marcas pii/safe), y nada de eso viaja al cliente.

Ver CHANGELOG 3.26.0 y `references/bd.md`.
"""

import sys

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# El mensaje va en main() y no a nivel de módulo: un `sys.exit(1)` durante el import haría este
# fichero INIMPORTABLE, y entonces ni los tests pueden comprobar que el shim se niega. Lo que
# tiene que fallar es EJECUTARLO, no cargarlo.
MOTIVO = "installer-ddl.py está retirado — el DDL del instalador ya no sale del modelo."


def main():
    print(f"ERROR: {MOTIVO}")
    print("")
    print("       El origen del DDL y del inventario de objetos es SIEMPRE la BD. El model.json")
    print("       puede estar desfasado, y en la BD puede haber objetos que el modelo no contempla.")
    print("")
    print("       Usa en su lugar:")
    print("         python scripts/installer-tablas.py <workspace> <proyecto> <out.sql> [--conexion <id>]")
    print("")
    print("       Esa ruta necesita conexión a BD; el DDL ya no se puede generar sin ella. Si algo")
    print("       llamó aquí, es que quedó cableado a la versión anterior: corrígelo, no restaures")
    print("       este generador. Ver CHANGELOG 3.26.0.")
    sys.exit(1)


if __name__ == "__main__":
    main()
