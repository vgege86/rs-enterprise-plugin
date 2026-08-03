"""Envoltorio CLI de pii_mask para hooks/db-query.ps1.

    echo '{"columns":[],"rows":[[]],"sql":"..."}' | python pii_cli.py <workspace>

Sale por stdout con {"columns":[],"rows":[[]],"pii":{}}. Ante cualquier error escribe
el diagnostico en stderr y sale con codigo != 0 SIN emitir datos: el hook decide.
Existe porque PowerShell no puede importar el modulo, y duplicar la logica en PS seria
una fuente garantizada de divergencia con la tool MCP.

Nunca se escribe en stderr (ni en ningun otro sitio) un valor de dato personal: los
mensajes de diagnostico solo describen el problema (nombre de fichero, tipo de error),
nunca el contenido de las filas.
"""
import importlib.util
import json
import sys
from pathlib import Path

_RAIZ = Path(__file__).resolve().parent


def _cargar(nombre):
    spec = importlib.util.spec_from_file_location(nombre, _RAIZ / f"{nombre}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _modelo(workspace):
    """(modelo, error) del primer BD/*-model.json del workspace.

    Dos situaciones bien distintas, que NO deben confundirse:

    1. No hay modelo en absoluto (no existe la carpeta BD, o no hay ningun
       fichero *-model.json dentro). Caso normal de un workspace que nunca
       declaro politica PII. Silencioso: ({}, None), mode=off aguas abajo.

    2. Hay un fichero *-model.json pero no se puede usar: JSON invalido,
       fichero ilegible, o su raiz no es un objeto (p.ej. una lista). Esto
       es un workspace ROTO, no la ausencia de politica, y no puede tratarse
       igual que el caso 1: si se tragara en silencio, un modelo corrupto o
       a medio escribir (merge sin terminar, disco lleno) apagaria el
       enmascarado sin ningun aviso, justo la fuga silenciosa que este CLI
       existe para evitar. Ademas, pasar una raiz que no es dict a
       mask_resultset revienta con AttributeError (visto en la revision de
       la Tarea 5: pii_policy.cargar_politica hace `(modelo or {}).get(...)`
       sobre lo que le llegue). Por eso aqui se devuelve un motivo y el
       caller hace fallar el CLI (exit != 0) en vez de seguir con datos a
       medio procesar.
    """
    bd = Path(workspace) / "BD"
    if not bd.is_dir():
        return {}, None
    ficheros = sorted(bd.glob("*-model.json"))
    if not ficheros:
        return {}, None

    ruta = ficheros[0]
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
        sys.stderr.write("uso: pii_cli.py <workspace>\n")
        return 2
    try:
        entrada = json.loads(sys.stdin.read())
    except Exception as exc:
        sys.stderr.write("entrada JSON invalida: %s\n" % exc.__class__.__name__)
        return 2

    modelo, error_modelo = _modelo(sys.argv[1])
    if error_modelo:
        sys.stderr.write(error_modelo + "\n")
        return 1

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
    sys.exit(main())
