"""
El ÚNICO escritor de `BD/<proyecto>-model.json`. Todo hook y todo script que toque el modelo
pasa por aquí — desde PowerShell vía `hooks/lib-modeljson.ps1`, desde Python importando este
módulo.

⛔ POR QUÉ UNO SOLO, Y POR QUÉ ES UN PROBLEMA DE VERDAD

El modelo vive en el repositorio del proyecto y se revisa por diff. Había dos escritores y los
dos lo rompían, cada uno a su manera:

  - Los scripts Python serializaban con `ensure_ascii=False` y escribían en UTF-8 SIN BOM. El
    fichero seguía siendo JSON válido, pero cambiaba de codificación cada vez que lo tocaba el
    otro escritor: el diff salía entero, con los acentos como bytes crudos (medido en una
    instalación de cliente: BOM ausente y 12 bytes no-ASCII).
  - Los hooks PowerShell usaban `ConvertTo-Json`. El de PS 5.1 no indenta con dos espacios por
    nivel: ALINEA cada valor a la columna de la clave padre. Un modelo de 1,1 MB pasa a 3,5 MB
    (x3,2) y CADA línea cambia de sangrado, así que el diff queda inservible aunque el BOM y los
    CRLF sean correctos. Es peor que el caso anterior porque no se nota: el JSON es válido, el
    contenido es el mismo, y solo se ve al abrir el diff.

El formato canónico —el que ya tenía el modelo en el repositorio— es:

    json.dump(indent=2, separators=(',', ': '), ensure_ascii=True)  +  CRLF  +  UTF-8 CON BOM

`ensure_ascii=True` no es cosmético: garantiza que el fichero es ASCII puro, así que ninguna
herramienta puede reinterpretar su codificación y provocar un diff completo. El BOM es lo que
hace que PowerShell y las herramientas de Windows lo lean como UTF-8 sin adivinar.

VERIFICACIÓN POST-ESCRITURA

Escribir bien no basta: hay que comprobar que se escribió bien, porque el modo de fallo de todo
esto es silencioso. `verificar()` comprueba las cuatro cosas que se rompieron alguna vez —BOM
presente, ningún LF suelto, ningún byte no-ASCII, y que el fichero vuelve a parsearse al MISMO
objeto que se pretendía escribir— y `guardar()` la ejecuta sobre el temporal ANTES de sustituir
al modelo bueno. Si algo no cuadra, el modelo anterior no se toca.

Uso desde línea de comandos (es lo que hace `hooks/lib-modeljson.ps1`):

    python _modeljson.py escribir <destino.json> <origen.json>
    python _modeljson.py verificar <fichero.json>

En los dos casos imprime un JSON con el veredicto y sale 0 si `ok`, 1 si no.
"""

import json
import os
import sys
from pathlib import Path

BOM = b"\xef\xbb\xbf"

# El separador de items va sin espacio a la derecha porque `indent` ya mete el salto de línea:
# con (', ', ': ') cada línea quedaría con un espacio final. Es exactamente el par que usa
# `json.dump(indent=2)` por defecto en Python 3, escrito aquí para que no dependa de la versión.
SEPARADORES = (",", ": ")
INDENT = 2


def cargar(path) -> dict:
    """Lee un modelo. `utf-8-sig` para que el BOM no acabe dentro de la primera clave."""
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def serializar(model: dict) -> bytes:
    """El modelo en su forma canónica, lista para escribir a disco.

    El `replace` de saltos es seguro porque `ensure_ascii=True` ya ha escapado como `\\n`
    cualquier salto que estuviera DENTRO de una cadena: los únicos `\\n` que quedan en el texto
    son los que separa el indentado.
    """
    texto = json.dumps(model, indent=INDENT, separators=SEPARADORES, ensure_ascii=True)
    return BOM + texto.replace("\n", "\r\n").encode("ascii")


def verificar(path, esperado: dict = None) -> dict:
    """Comprueba que el fichero de `path` cumple el formato canónico.

    Devuelve `{ok, path, bytes, bom, lf_sueltos, no_ascii, reparse, coincide, error}`. Nunca
    lanza: el llamante decide qué hacer con un `ok=False` (el escritor deshace, un chequeo
    suelto solo avisa).
    """
    res = {"ok": False, "path": str(path), "bytes": 0, "bom": False,
           "lf_sueltos": 0, "no_ascii": 0, "reparse": False, "coincide": None, "error": ""}
    try:
        datos = Path(path).read_bytes()
    except OSError as e:
        res["error"] = f"no se puede leer: {e}"
        return res

    res["bytes"] = len(datos)
    res["bom"] = datos.startswith(BOM)
    cuerpo = datos[len(BOM):] if res["bom"] else datos

    # LF suelto = un \n que no viene precedido de \r. Es lo que convierte el fichero en "todo
    # modificado" para un cliente de VCS configurado en CRLF.
    res["lf_sueltos"] = sum(1 for i, b in enumerate(cuerpo)
                            if b == 0x0A and (i == 0 or cuerpo[i - 1] != 0x0D))
    res["no_ascii"] = sum(1 for b in cuerpo if b > 0x7F)

    try:
        releido = json.loads(cuerpo.decode("ascii" if not res["no_ascii"] else "utf-8"))
        res["reparse"] = True
    except (ValueError, UnicodeDecodeError) as e:
        res["error"] = f"no vuelve a parsearse: {e}"
        return res

    if esperado is not None:
        # La única garantía que importa de verdad: lo que hay en disco es lo que se quería
        # escribir. Un fallo aquí significa pérdida de datos, no un problema de formato.
        res["coincide"] = (releido == esperado)
        if not res["coincide"]:
            res["error"] = "el fichero releído no coincide con el modelo que se quería escribir"
            return res

    problemas = []
    if not res["bom"]:
        problemas.append("falta el BOM UTF-8")
    if res["lf_sueltos"]:
        problemas.append(f"{res['lf_sueltos']} salto(s) LF sin CR")
    if res["no_ascii"]:
        problemas.append(f"{res['no_ascii']} byte(s) no-ASCII (debería ir todo escapado)")
    if problemas:
        res["error"] = "; ".join(problemas)
        return res

    res["ok"] = True
    return res


def guardar(model: dict, path) -> dict:
    """Escribe el modelo en forma canónica. Atómico y verificado.

    ⛔ El temporal se verifica ANTES del `os.replace`. Si la verificación falla, el modelo
    anterior queda intacto y se lanza `ValueError`: entregar un modelo corrupto es peor que no
    actualizarlo, porque a partir de ahí todo lo que lo consume (DDL del instalador, ERD,
    política PII) trabaja sobre datos rotos sin saberlo.
    """
    destino = Path(path)
    tmp = destino.with_name(destino.name + ".tmp")
    tmp.write_bytes(serializar(model))

    res = verificar(tmp, esperado=model)
    if not res["ok"]:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise ValueError(f"escritura canónica rechazada para {destino}: {res['error']}")

    os.replace(tmp, destino)
    res["path"] = str(destino)
    return res


# ---------------------------------------------------------------- CLI (lo usa PowerShell)
def _main(argv) -> int:
    if len(argv) < 3:
        print(json.dumps({"ok": False, "error": "Uso: _modeljson.py escribir <destino> <origen>"
                                                " | _modeljson.py verificar <fichero>"}))
        return 1

    accion = argv[1].lower()
    try:
        if accion == "escribir":
            if len(argv) < 4:
                print(json.dumps({"ok": False, "error": "falta el fichero de origen"}))
                return 1
            # El origen lo produce PowerShell con ConvertTo-Json -Compress: sirve para transportar
            # la estructura, no para escribirla. La forma canónica la impone `guardar`.
            res = guardar(cargar(argv[3]), argv[2])
        elif accion == "verificar":
            res = verificar(argv[2])
        else:
            print(json.dumps({"ok": False, "error": f"acción desconocida: {accion}"}))
            return 1
    except Exception as e:
        print(json.dumps({"ok": False, "error": f"{type(e).__name__}: {e}"}, ensure_ascii=False))
        return 1

    print(json.dumps(res, ensure_ascii=False))
    return 0 if res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
