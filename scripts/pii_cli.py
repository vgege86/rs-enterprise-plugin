"""Envoltorio CLI de pii_mask para hooks/db-query.ps1.

    echo '{"columns":[],"rows":[[]],"sql":"..."}' | python pii_cli.py <workspace> [<model_path>]

Sale por stdout con {"columns":[],"rows":[[]],"pii":{}}. Ante cualquier error escribe
el diagnostico en stderr y sale con codigo != 0 SIN emitir datos: el hook decide.
Existe porque PowerShell no puede importar el modulo, y duplicar la logica en PS seria
una fuente garantizada de divergencia con la tool MCP.

<model_path> lo resuelve el llamante (hooks/lib-dbconfig.ps1 Get-RsModelPath, el mismo
camino que alimenta config["model_path"] de la tool MCP). Este CLI NO busca el modelo por
su cuenta: hacerlo con un glob de BD/*-model.json ignoraba el campo "model" de la conexion
y bastaba un nombre de fichero fuera del patron, o dos ficheros en BD/, para que el hook
devolviera mode=off -- indistinguible de un workspace sin politica -- mientras la tool MCP
enmascaraba con la politica declarada.

Codigos de salida. TODOS los != 0 significan "el CLI corrio y NO pudo aplicar la politica
a unos datos que ya tenia": el hook debe fallar CERRADO (sin filas). El unico fallo abierto
legitimo es que este CLI no se pueda ni ejecutar (sin python, sin fichero), y eso lo
comprueba el hook antes de invocarlo.

Nunca se escribe en stderr (ni en ningun otro sitio) un valor de dato personal: los
mensajes de diagnostico solo describen el problema (nombre de fichero, tipo de error),
nunca el contenido de las filas.
"""
import importlib.util
import json
import sys
from pathlib import Path

_RAIZ = Path(__file__).resolve().parent

E_USO = 2       # invocacion o entrada JSON invalida
E_MODELO = 3    # modelo BD configurado pero inutilizable (no existe, ilegible, corrupto)
E_INTERNO = 10  # fallo interno del enmascarado (bug, modelo con forma inesperada)


def _cargar(nombre):
    spec = importlib.util.spec_from_file_location(nombre, _RAIZ / f"{nombre}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _modelo(model_path):
    """(modelo, error) del modelo BD configurado.

    Tres situaciones bien distintas, que NO deben confundirse:

    1. No hay modelo configurado (model_path vacio). Caso normal de un workspace
       que nunca declaro politica PII. Silencioso: ({}, None), mode=off aguas
       abajo. Es tambien lo que hace _cargar_modelo() de la tool MCP.

    2. Hay una ruta configurada pero el fichero no existe. NO es el caso 1: alguien
       declaro una politica y no se esta aplicando. Tratarlo como ausencia de modelo
       devolveria mode=off, que es exactamente la fuga silenciosa que este CLI existe
       para evitar. Error.

    3. El fichero existe pero no se puede usar: JSON invalido, ilegible, o su raiz no
       es un objeto (p.ej. una lista). Workspace ROTO -- un modelo a medio escribir
       (merge sin terminar, disco lleno) apagaria el enmascarado sin ningun aviso.
       Ademas, pasar una raiz que no es dict a mask_resultset revienta con
       AttributeError. Error tambien.
    """
    if not model_path:
        return {}, None

    ruta = Path(model_path)
    if not ruta.is_file():
        return {}, "modelo BD configurado pero no encontrado: %s" % ruta.name
    try:
        texto = ruta.read_text(encoding="utf-8-sig")
    except Exception as exc:
        return {}, "modelo BD ilegible (%s): %s" % (ruta.name, exc.__class__.__name__)
    try:
        datos = json.loads(texto)
    except Exception as exc:
        return {}, "modelo BD invalido (%s): %s" % (ruta.name, exc.__class__.__name__)
    if not isinstance(datos, dict):
        return {}, "modelo BD invalido (%s): la raiz del JSON no es un objeto" % ruta.name
    return datos, None


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("uso: pii_cli.py <workspace> [<model_path>]\n")
        return E_USO
    model_path = sys.argv[2] if len(sys.argv) > 2 else ""
    try:
        # utf-8-sig, y por bytes: hooks/db-query.ps1 fija
        # $OutputEncoding = [Text.Encoding]::UTF8, que en PowerShell 5.1 antepone el BOM a
        # TODO lo que se canaliza hacia un comando nativo. Con sys.stdin.read() ese BOM
        # llegaba dentro del texto, json.loads fallaba SIEMPRE y el hook caia por su rama de
        # fallo (antes, abierto): el enmascarado del camino de hook no llego a aplicarse
        # nunca sobre un resultset con filas. Mismo encoding que se usa para el modelo BD.
        entrada = json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))
    except Exception as exc:
        sys.stderr.write("entrada JSON invalida: %s\n" % exc.__class__.__name__)
        return E_USO

    modelo, error_modelo = _modelo(model_path)
    if error_modelo:
        sys.stderr.write(error_modelo + "\n")
        return E_MODELO

    mk = _cargar("pii_mask")
    columns, rows, meta = mk.mask_resultset(
        entrada.get("columns") or [],
        entrada.get("rows") or [],
        entrada.get("sql") or "",
        modelo,
    )
    json.dump({"columns": columns, "rows": rows, "pii": meta},
              sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    try:
        _codigo = main()
    except SystemExit:
        raise
    except BaseException as _exc:  # noqa: BLE001 - nada puede escapar sin codigo propio
        # Un traceback sin control saldria con codigo 1, que el hook no distingue de
        # "python no encontro el fichero". Se fuerza E_INTERNO para que el hook falle
        # CERRADO: el CLI ya tenia las filas en la mano y no ha podido enmascararlas.
        sys.stderr.write("fallo interno del enmascarado: %s\n" % _exc.__class__.__name__)
        _codigo = E_INTERNO
    sys.exit(_codigo)
