"""
Devuelve el DDL de UN objeto de BD leyéndolo de la base de datos viva.

POR QUÉ HACE FALTA
    El `model.json` guarda de cada objeto su ficha y una firma, **nunca el cuerpo** (el motivo
    está en `_dbobjetos.py`: el instalador tiene que seguir extrayendo de la BD viva o un modelo
    desactualizado entregaría código viejo, y un package de miles de líneas no cabe razonablemente
    dentro del HTML del ERD, que embebe el modelo entero).

    Eso deja al desarrollo con el inventario pero sin el código: se sabe que `P_ALTA_CLIENTE`
    existe, cuántas líneas tiene y qué tablas toca, pero para leerlo había que abrir un cliente
    de BD. Esto lo resuelve sin renunciar a la decisión de no guardar cuerpos: se lee cuando se
    pide, y no se guarda.

    Es el mismo texto que entregaría el instalador —los mismos extractores, el mismo maquetado—,
    así que lo que se lee aquí es exactamente lo que viajaría al cliente.

DERIVA
    Si el objeto está en el inventario, se compara la firma de lo que hay AHORA en la BD con la
    que guardó el modelo y se dice si coinciden. Un "no coinciden" significa que alguien tocó el
    objeto en la BD después de la última sincronización.

Uso: python object-ddl.py <workspace> <proyecto> <NOMBRE> [--seccion <sec>] [--out <fichero>]
"""

import sys
import json
import importlib.util
from pathlib import Path

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

_AQUI = Path(__file__).resolve().parent
if str(_AQUI) not in sys.path:
    sys.path.insert(0, str(_AQUI))

import _dbobjetos as obj


def _por_ruta(nombre, fichero):
    spec = importlib.util.spec_from_file_location(nombre, _AQUI / fichero)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_io = _por_ruta("_installer_objects", "installer-objects.py")
_mo = _por_ruta("_model_objects", "model-objects.py")


def localizar(inventario: dict, nombre: str) -> list:
    """[(sección, nombre real), ...] del inventario que casan con `nombre`, sin distinguir
    mayúsculas. Puede haber más de uno: una vista y un sinónimo pueden llamarse igual."""
    n = (nombre or "").strip().upper()
    hits = []
    for sec in obj.SECCIONES:
        for real in (inventario.get(sec) or {}):
            if real.upper() == n:
                hits.append((sec, real))
    return hits


def main():
    if len(sys.argv) < 4:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto> <NOMBRE> [--seccion <sec>] [--out <fichero>]")
        sys.exit(1)

    workspace, proyecto, nombre = sys.argv[1], sys.argv[2], sys.argv[3]
    resto = sys.argv[4:]

    def _opt(bandera, defecto=""):
        i = resto.index(bandera) if bandera in resto else -1
        return resto[i + 1] if 0 <= i < len(resto) - 1 else defecto

    seccion_pedida = _opt("--seccion").strip().lower()
    salida = _opt("--out")

    model_path = Path(workspace) / "BD" / f"{proyecto}-model.json"
    if not model_path.exists():
        print(f"ERROR: Modelo no encontrado: {model_path}")
        sys.exit(1)
    with open(model_path, encoding="utf-8-sig") as f:
        model = json.load(f)

    inventario = model.get("objetos") or {}
    if seccion_pedida and seccion_pedida not in obj.SECCIONES:
        print(f"ERROR: sección desconocida '{seccion_pedida}'. Válidas: {', '.join(obj.SECCIONES)}")
        sys.exit(1)

    hits = localizar(inventario, nombre) if inventario else []
    if seccion_pedida:
        secciones = [seccion_pedida]
    elif hits:
        secciones = sorted({s for s, _ in hits})
    else:
        # Sin inventario (o con un objeto que no está en él, p.ej. creado después de la última
        # sincronización) se barren todos los tipos. Cuesta más sesiones, pero la alternativa es
        # no responder a una pregunta que tiene respuesta.
        secciones = list(obj.SECCIONES)
        if not inventario:
            print("AVISO: el modelo no trae inventario de objetos; se buscan los siete tipos.")
        else:
            print(f"AVISO: '{nombre}' no está en el inventario del modelo; se buscan los siete tipos.")

    cfg = _io._ins.read_db_config(workspace, model)
    if cfg["motor"] not in ("ORACLE", "SQLSERVER"):
        print(f"ERROR: motor no soportado: {cfg['motor']}")
        sys.exit(1)

    salidas, errores = _mo.extraer(cfg, _io._ins.read_max_paralelo(workspace, proyecto),
                                   solo=secciones)
    for _f, titulo, err in errores:
        print(f"ERROR en {titulo}: {err}")

    idx = {}
    for etapa, sec in obj.ETAPA_A_SECCION.items():
        res = salidas.get(etapa)
        if not res:
            continue
        deshabilitados = set(res.get("disabled") or [])
        for visible, cuerpo in (res.get("bloques") or {}).items():
            destino, limpio = (obj.clasificar_plsql(visible)
                               if sec == "procedimientos" else (sec, visible))
            if limpio.upper() != nombre.strip().upper():
                continue
            e = idx.setdefault(destino, {"bloques": [], "disabled": False, "real": limpio})
            e["bloques"].append((visible, cuerpo))
            if visible in deshabilitados:
                e["disabled"] = True

    if not idx:
        print(f"\nNo se encontró '{nombre}' en la BD"
              f"{' (secciones: ' + ', '.join(secciones) + ')' if seccion_pedida else ''}.")
        sys.exit(1)

    lineas = []
    for destino, e in idx.items():
        ficha_modelo = (inventario.get(destino) or {}).get(e["real"]) or {}
        # La especificación y el cuerpo de un package firman juntos y en ese orden, igual que en
        # el inventario; si no, la comparación de deriva daría siempre distinto.
        acumulado = "\n".join(obj.normalizar(c) for _v, c in e["bloques"])
        viva = obj.firma_objeto(acumulado if destino == "paquetes" else e["bloques"][0][1], destino)

        print(f"\n== {destino} / {e['real']} ==")
        print(f"   Motor: {cfg['motor']} | schema/BD: {cfg['schema']}"
              f"{' | DISABLED en origen' if e['disabled'] else ''}")
        if ficha_modelo:
            coincide = ficha_modelo.get("firma") == viva
            print(f"   Firma BD {viva} · modelo {ficha_modelo.get('firma')} — "
                  f"{'coinciden' if coincide else '⛔ NO coinciden: la BD cambió desde el último sync'}")
            if ficha_modelo.get("tablas_usadas"):
                print(f"   Tablas que usa (según el modelo): {', '.join(ficha_modelo['tablas_usadas'])}")
        else:
            print(f"   Firma BD {viva} — sin ficha en el modelo (no sincronizado todavía)")

        for visible, cuerpo in e["bloques"]:
            lineas += _io.render_objeto(destino, visible, cuerpo, cfg["motor"], e["disabled"])

    texto = "\n".join(lineas).rstrip() + "\n"
    if salida:
        Path(salida).parent.mkdir(parents=True, exist_ok=True)
        Path(salida).write_text(texto, encoding="utf-8")
        print(f"\nOK — DDL escrito en {salida}")
    else:
        print("\n" + "-" * 60)
        print(texto)

    if errores:
        sys.exit(2)


if __name__ == "__main__":
    main()
