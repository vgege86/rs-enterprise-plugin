"""Envoltorio CLI de pii_mask para hooks/db-query.ps1.

    echo '{"columns":[],"rows":[[]],"sql":"..."}' | python pii_cli.py <workspace> [<model_path>] [--convenio]

Segundo modo, para /rs-pii (no lo usa el hook):

    python pii_cli.py --clasificar <model_path> [--tablas T1,T2] [--todo] [--max N]

que devuelve el veredicto y el motivo deterministas por columna. Ver _clasificar().

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

--convenio dice que <model_path> NO esta declarado en .rs-databases.json sino derivado del
convenio BD/<proyecto>-model.json (lo pasa hooks/db-query.ps1 segun Test-RsModelDeclarado).
Sin el, una ruta cuyo fichero no existe se trata como DECLARADA, es decir como error: la
imprecision tiene que degradar hacia mas enmascarado, nunca hacia menos. Ver _modelo().

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


_AYUDA_MODELO = ("Generar el modelo con /rs-init (workspace nuevo) o sincronizarlo desde la "
                 "BD con /rs-erd. Mientras tanto la consulta no devuelve filas: sin modelo no "
                 "se puede aplicar la politica de datos personales del workspace.")


def _modelo(model_path, por_convenio=False):
    """(modelo, error) del modelo BD configurado.

    Tres situaciones bien distintas, que NO deben confundirse. Son las MISMAS que
    distingue _cargar_modelo() de mcp/rs-workspace-server.py en el camino de la tool MCP
    (⛔ PARIDAD: si cambia una, cambia la otra):

    1. No hay modelo configurado (model_path vacio), o la ruta viene del CONVENIO
       BD/<proyecto>-model.json y el fichero no existe (por_convenio=True). Caso normal
       de un workspace que nunca declaro politica PII. Silencioso: ({}, None), mode=off
       aguas abajo. Es lo que garantiza que un workspace que actualiza no cambie de
       comportamiento.

    2. Hay una ruta DECLARADA en .rs-databases.json y el fichero no existe. NO es el
       caso 1: alguien declaro una politica y no se esta aplicando. Tratarlo como
       ausencia de modelo devolveria mode=off, que es exactamente la fuga silenciosa que
       este CLI existe para evitar. Error.

       El llamante marca el caso 1 con --convenio; sin esa marca la ruta se asume
       declarada, porque la imprecision debe degradar hacia mas enmascarado.

    3. El fichero existe pero no se puede usar: JSON invalido, ilegible, o su raiz no
       es un objeto (p.ej. una lista). Workspace ROTO -- un modelo a medio escribir
       (merge sin terminar, disco lleno) apagaria el enmascarado sin ningun aviso.
       Ademas, pasar una raiz que no es dict a mask_resultset revienta con
       AttributeError. Error tambien, venga de donde venga la ruta.
    """
    if not model_path:
        return {}, None

    ruta = Path(model_path)
    if not ruta.is_file():
        if por_convenio:
            return {}, None
        return {}, ("modelo BD declarado en docs/.rs-databases.json pero no encontrado: %s. %s"
                    % (ruta.name, _AYUDA_MODELO))
    try:
        texto = ruta.read_text(encoding="utf-8-sig")
    except Exception as exc:
        return {}, "modelo BD ilegible (%s): %s. %s" % (ruta.name, exc.__class__.__name__, _AYUDA_MODELO)
    try:
        datos = json.loads(texto)
    except Exception as exc:
        return {}, "modelo BD invalido (%s): %s. %s" % (ruta.name, exc.__class__.__name__, _AYUDA_MODELO)
    if not isinstance(datos, dict):
        return {}, ("modelo BD invalido (%s): la raiz del JSON no es un objeto. %s"
                    % (ruta.name, _AYUDA_MODELO))
    return datos, None


def _clasificar(argv):
    """Modo clasificacion: veredicto y motivo DETERMINISTAS por columna.

        python pii_cli.py --clasificar <model_path> [--tablas T1,T2] [--todo] [--max N]
        (opcional por stdin) {"muestras": {"TABLA": {"COLUMNA": ["v1", "v2", ...]}}}

    Existe para que /rs-pii bootstrap no rehaga a mano la precedencia del #4.2 ni ojee las
    formas de dato personal: el inventario que produce es el que Sistemas usara para decidir
    que columnas se redactan en BD, asi que tiene que coincidir con lo que el plugin
    enmascara de verdad. Un clasificador escrito en un prompt deriva del real en cuanto uno
    de los dos cambia, y el sintoma es un inventario que no cuadra con la herramienta.

    Reutiliza pii_policy.clasificar (mismas reglas y mismo orden que mask_resultset) y, si
    se le pasan muestras, la misma red de seguridad por forma de valor de pii_mask sobre las
    columnas que saldrian en claro.

    ⛔ La salida NUNCA contiene un valor muestreado: solo nombre de columna, veredicto,
    motivo, forma detectada y conteos.
    """
    if len(argv) < 1:
        sys.stderr.write("uso: pii_cli.py --clasificar <model_path> [--tablas T1,T2] [--todo] [--max N]\n")
        return E_USO

    model_path = argv[0]
    filtro, todo, maximo = set(), False, 500
    i = 1
    while i < len(argv):
        if argv[i] == "--tablas" and i + 1 < len(argv):
            filtro = {t.strip().upper() for t in argv[i + 1].split(",") if t.strip()}
            i += 2
        elif argv[i] == "--todo":
            todo = True
            i += 1
        elif argv[i] == "--max" and i + 1 < len(argv):
            try:
                maximo = int(argv[i + 1])
            except ValueError:
                sys.stderr.write("--max necesita un entero\n")
                return E_USO
            i += 2
        else:
            sys.stderr.write("argumento no reconocido: %s\n" % argv[i])
            return E_USO

    modelo, error_modelo = _modelo(model_path)
    if error_modelo:
        sys.stderr.write(error_modelo + "\n")
        return E_MODELO

    muestras = {}
    if not sys.stdin.isatty():
        bruto = sys.stdin.buffer.read().decode("utf-8-sig").strip()
        if bruto:
            try:
                muestras = (json.loads(bruto) or {}).get("muestras") or {}
            except Exception as exc:
                sys.stderr.write("muestras JSON invalidas: %s\n" % exc.__class__.__name__)
                return E_USO
    muestras = {str(t).upper(): {str(c).upper(): v for c, v in (cols or {}).items()}
                for t, cols in muestras.items()}

    pol = _cargar("pii_policy")
    det = _cargar("pii_detect")
    politica = pol.cargar_politica(modelo)
    indice = pol.indice_tablas(modelo)

    salida, truncado = {}, False
    total = claro = mascara = sospechosas = 0
    for tabla in sorted(indice):
        if filtro and tabla not in filtro:
            continue
        filas = []
        for columna in sorted(pol.indice_columnas(indice[tabla])):
            veredicto, motivo = pol.clasificar(columna, [tabla], modelo, politica)
            entrada = {"columna": columna, "veredicto": veredicto, "motivo": motivo}

            valores = (muestras.get(tabla) or {}).get(columna)
            if veredicto == pol.CLARO and valores:
                # Misma red de seguridad que mask_resultset sobre lo que sale en claro.
                forma = det.escanear_columna(valores)
                if forma:
                    no_vacios = [v for v in valores if v is not None and str(v).strip()]
                    entrada.update({
                        "veredicto": pol.MASCARA,
                        "motivo": "forma_%s" % forma,
                        "sospechosa": True,
                        "forma": forma,
                        "coincidencias": sum(1 for v in no_vacios if det.detectar(v) == forma),
                        "muestra": len(no_vacios),
                    })

            total += 1
            if entrada["veredicto"] == pol.CLARO:
                claro += 1
            else:
                mascara += 1
            if entrada.get("sospechosa"):
                sospechosas += 1

            if todo or entrada["veredicto"] == pol.CLARO or entrada.get("sospechosa"):
                if sum(len(v) for v in salida.values()) >= maximo:
                    truncado = True
                else:
                    filas.append(entrada)
        if filas:
            salida[tabla] = filas

    json.dump({
        "mode": politica["mode"],
        "tablas": salida,
        "truncado": truncado,
        "totales": {
            "tablas_analizadas": len(indice) if not filtro else len(filtro & set(indice)),
            "columnas": total, "claro": claro, "mascara": mascara, "sospechosas": sospechosas,
        },
    }, sys.stdout, ensure_ascii=False)
    return 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--clasificar":
        return _clasificar(sys.argv[2:])

    # Parseo a mano y no argparse: --convenio es la unica opcion y el resto son
    # posicionales que ya estaban; argparse cambiaria mensajes y codigos de salida, y
    # todos los != 0 de este CLI tienen significado para el hook.
    argv = [a for a in sys.argv[1:] if a != "--convenio"]
    por_convenio = "--convenio" in sys.argv[1:]
    if len(argv) < 1:
        sys.stderr.write("uso: pii_cli.py <workspace> [<model_path>] [--convenio]\n")
        return E_USO
    model_path = argv[1] if len(argv) > 1 else ""
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

    modelo, error_modelo = _modelo(model_path, por_convenio)
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
