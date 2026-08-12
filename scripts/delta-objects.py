"""
Genera el .sql de los objetos de BD que han cambiado desde la última entrega, para que viaje en
el paquete de `/rs-actualizador`.

EL AGUJERO QUE CIERRA
    El delta de una entrega incremental se calcula por VCS (`FECHA_CORTE` + `vcs_delta` sobre
    ficheros del repo). Un procedimiento, una vista o un trigger modificados en BD **no están en
    el repo**: hasta la 3.10.0 no se detectaban siquiera, y desde la 3.10.0 se detectan —el
    inventario del `model.json` guarda una firma de cada objeto— pero el script había que
    escribirlo a mano. Aquí se escribe solo, con el mismo texto que entregaría el instalador.

QUÉ ES "LA ÚLTIMA ENTREGA"
    El inventario `objetos` del `model.json`. Es la línea base, y por eso hay que resincronizarlo
    DESPUÉS de cerrar la entrega (`--sincronizar`, o `hooks\\sync-model-objects.ps1`): si no, el
    siguiente actualizador vuelve a proponer lo mismo. Y si el modelo aún no trae inventario, no
    hay línea base contra la que comparar y esto no puede inventarla — lo dice y sale.

QUÉ VIAJA Y QUÉ NO
    Viaja lo nuevo, lo modificado y lo que cambió de estado (un trigger que pasó a DISABLED: el
    cuerpo es el mismo, el `ALTER TRIGGER` que lo acompaña no).

    ⛔ NO viaja una SECUENCIA MODIFICADA. Su DDL es `CREATE` —no `CREATE OR REPLACE`— y en SQL
    Server el bloque trae además un DROP delante: contra un cliente que ya la tiene, o falla
    (ORA-00955) o la recrea en la posición de NUESTRA base de datos, repartiendo IDs ya usados.
    Sale listada como retenida para resolverla con un ALTER a mano.

    ⛔ NO se emite ningún DROP de lo eliminado. Un objeto que falta puede ser un borrado real o
    una extracción incompleta, y las dos cosas se parecen mucho desde aquí; la diferencia es que
    una equivocación borra código en producción. Se emiten al final COMENTADOS, para que quien
    entrega decida y descomente.

Uso: python delta-objects.py <workspace> <proyecto> <out_dir>
                             [--prefijo NN] [--nombre FICHERO] [--sincronizar] [--dry-run]
"""

import sys
import re
import json
import importlib.util
from pathlib import Path
from datetime import datetime

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

_AQUI = Path(__file__).resolve().parent
if str(_AQUI) not in sys.path:
    sys.path.insert(0, str(_AQUI))

import _dbobjetos as obj

# Los dos módulos llevan guion en el nombre -> no son importables con `import`; se cargan por ruta.
def _por_ruta(nombre, fichero):
    spec = importlib.util.spec_from_file_location(nombre, _AQUI / fichero)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_io = _por_ruta("_installer_objects", "installer-objects.py")
_mo = _por_ruta("_model_objects", "model-objects.py")

_PREFIJO_RE = re.compile(r"^(\d{2,3})-")


def indice_bloques(salidas: dict) -> dict:
    """{(sección, nombre): {"bloques": [(nombre_visible, cuerpo), ...], "disabled": bool}}

    El inventario indexa por nombre limpio y un paquete son DOS bloques de ALL_SOURCE
    (especificación y cuerpo) bajo la misma clave; ambos tienen que ir al script, y en ese orden
    —la especificación primero— o el cuerpo no compila.
    """
    idx = {}
    for etapa, seccion in obj.ETAPA_A_SECCION.items():
        res = salidas.get(etapa)
        if not res:
            continue
        deshabilitados = set(res.get("disabled") or [])
        for nombre, cuerpo in (res.get("bloques") or {}).items():
            destino, limpio = (obj.clasificar_plsql(nombre)
                               if seccion == "procedimientos" else (seccion, nombre))
            e = idx.setdefault((destino, limpio), {"bloques": [], "disabled": False})
            e["bloques"].append((nombre, cuerpo))
            if nombre in deshabilitados:
                e["disabled"] = True
    return idx


def render(entregables: dict, idx: dict, motor: str) -> tuple:
    """Las líneas del script y la lista de lo que realmente se ha podido escribir.

    Recorre `SECCIONES` en orden de dependencias, que es el orden en que hay que ejecutarlo:
    secuencias → vistas → funciones → procedimientos → paquetes → triggers → sinónimos.
    """
    lines, escritos = [], []
    for sec in obj.SECCIONES:
        nombres = entregables.get(sec) or []
        if not nombres:
            continue
        lines += ["-- ------------------------------------------------------------",
                  f"-- {sec.upper()} ({len(nombres)})",
                  "-- ------------------------------------------------------------",
                  ""]
        for nombre in nombres:
            e = idx.get((sec, nombre))
            if not e:
                # No debería pasar: `entregables` sale del mismo inventario que `idx`. Si pasa,
                # es preferible un hueco anunciado que un script silenciosamente incompleto.
                lines += [f"-- ⛔ {nombre}: sin cuerpo extraído, NO se ha podido generar.", ""]
                continue
            for visible, cuerpo in e["bloques"]:
                lines += _io.render_objeto(sec, visible, cuerpo, motor, e["disabled"])
            escritos.append(f"{sec}/{nombre}")
    return lines, escritos


def bloque_retenidos(retenidos: dict) -> list:
    if not retenidos:
        return []
    l = ["-- ------------------------------------------------------------",
         "-- SECUENCIAS MODIFICADAS — NO se entregan automáticamente",
         "--",
         "-- Su DDL es CREATE (en SQL Server, DROP + CREATE): contra una secuencia que ya",
         "-- existe en el cliente, o falla, o la recrea en la posición de NUESTRA base de",
         "-- datos y empieza a repartir IDs ya usados. Lo que cambió (INCREMENT BY, CACHE,",
         "-- CYCLE) se aplica con un ALTER SEQUENCE escrito a mano.",
         "-- ------------------------------------------------------------"]
    for sec, nombres in retenidos.items():
        for n in nombres:
            l.append(f"--   {sec}: {n}")
    l.append("")
    return l


def bloque_eliminados(cambios: dict, motor: str) -> list:
    """Los DROP de lo eliminado, COMENTADOS. Ver la cabecera del módulo."""
    hay = {s: c["eliminados"] for s, c in (cambios or {}).items() if c.get("eliminados")}
    if not hay:
        return []
    palabra = {"secuencias": "SEQUENCE", "vistas": "VIEW", "funciones": "FUNCTION",
               "procedimientos": "PROCEDURE", "paquetes": "PACKAGE", "triggers": "TRIGGER",
               "sinonimos": "SYNONYM"}
    l = ["-- ------------------------------------------------------------",
         "-- EN EL MODELO Y YA NO EN LA BD — comentado a propósito",
         "--",
         "-- Un objeto que falta puede ser un borrado real o una extracción incompleta, y desde",
         "-- aquí las dos cosas se parecen. Descomenta solo lo que sepas que se borró de verdad.",
         "-- ------------------------------------------------------------"]
    for sec in obj.SECCIONES:
        for n in hay.get(sec) or []:
            if motor == "ORACLE":
                l.append(f"-- DROP {palabra[sec]} {n};")
            else:
                l.append(f"-- DROP {palabra[sec]} {n};")
                l.append("-- GO")
    l.append("")
    return l


def siguiente_prefijo(out_dir: Path) -> str:
    """El primer hueco de la franja 90-98, mirando los .sql que ya hay en la carpeta.

    Los scripts del actualizador van numerados y el orden importa. Este cae al final a
    propósito: el DDL de los objetos se aplica DESPUÉS de los scripts de estructura y datos que
    traen las tareas —un procedimiento nuevo puede leer una columna que crea uno de ellos— y
    ANTES del 99-RVERSIONES, que cierra siempre la entrega.
    """
    usados = set()
    if out_dir.is_dir():
        for f in out_dir.glob("*.sql"):
            m = _PREFIJO_RE.match(f.name)
            if m:
                usados.add(int(m.group(1)))
    for n in range(90, 99):
        if n not in usados:
            return f"{n:02d}"
    return f"{max(usados) + 1:02d}"


def main():
    if len(sys.argv) < 4:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto> <out_dir> "
              f"[--prefijo NN] [--nombre FICHERO] [--sincronizar] [--dry-run]")
        sys.exit(1)

    workspace, proyecto, out_dir = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    resto = sys.argv[4:]
    dry = "--dry-run" in resto
    sincronizar = "--sincronizar" in resto

    def _opt(bandera, defecto=""):
        return resto[resto.index(bandera) + 1] if bandera in resto and resto.index(bandera) + 1 < len(resto) else defecto

    prefijo = _opt("--prefijo")
    nombre_fichero = _opt("--nombre")

    model_path = Path(workspace) / "BD" / f"{proyecto}-model.json"
    if not model_path.exists():
        print(f"ERROR: Modelo no encontrado: {model_path}")
        sys.exit(1)
    with open(model_path, encoding="utf-8-sig") as f:
        model = json.load(f)

    previo = model.get("objetos") or {}
    if not previo or obj.total(previo) == 0:
        print("ERROR: el modelo no trae inventario de objetos, así que no hay línea base contra")
        print("       la que comparar. Ejecuta primero:  hooks\\sync-model-objects.ps1 \"<workspace>\"")
        print("       — y ten en cuenta que esa primera sincronización fija la base: lo que ya")
        print("       estuviera en la BD NO saldrá como cambio en esta entrega.")
        sys.exit(1)

    cfg = _io._ins.read_db_config(workspace, model)
    if cfg["motor"] not in ("ORACLE", "SQLSERVER"):
        print(f"ERROR: motor no soportado: {cfg['motor']}")
        sys.exit(1)

    print(f"Motor: {cfg['motor']} | schema/BD: {cfg['schema']}")
    print(f"Línea base: {model_path.name} ({obj.total(previo)} objetos)")

    salidas, errores = _mo.extraer(cfg, _io._ins.read_max_paralelo(workspace, proyecto))
    for _fichero, titulo, err in errores:
        print(f"   ERROR en {titulo}: {err}")

    actual = obj.construir(salidas, list((model.get("tables") or {}).keys()))
    cambios = obj.comparar(previo, actual)

    # ⛔ Una sección cuya extracción falló sale vacía, y el diff la leería como "se ha eliminado
    # todo". No se puede decidir nada sobre ella: se saca del delta y se dice.
    fallidas = {obj.ETAPA_A_SECCION.get(f) for f, _t, _e in errores}
    fallidas.discard(None)
    if "procedimientos" in fallidas:
        fallidas.add("paquetes")     # misma etapa
    for sec in fallidas:
        cambios.pop(sec, None)
        print(f"AVISO: '{sec}' queda FUERA del delta porque su extracción falló — revísala a mano.")

    if not cambios:
        print("\nSin cambios: ningún objeto de BD ha cambiado desde la última entrega.")
        print("No se genera script.")
        return

    entregables, retenidos = obj.para_entregar(cambios)
    idx = indice_bloques(salidas)

    print("\nCambios detectados:")
    for sec, c in cambios.items():
        for etiqueta in ("nuevos", "modificados", "estado_cambiado", "eliminados"):
            if c[etiqueta]:
                print(f"   {sec:<15} {etiqueta:<16} {', '.join(c[etiqueta])}")

    lines, escritos = render(entregables, idx, cfg["motor"])
    if not lines and not retenidos and not any(c.get("eliminados") for c in cambios.values()):
        print("\nNada que escribir.")
        return

    extra = [f"Línea base: inventario `objetos` de {model_path.name}",
             f"Contiene SOLO lo que cambió desde la última entrega: {len(escritos)} objeto(s).",
             "Orden de ejecución = orden de dependencias (secuencias → vistas → funciones →",
             "procedimientos → paquetes → triggers → sinónimos)."]
    if retenidos:
        extra.append("Hay secuencias modificadas RETENIDAS al final del fichero: no se entregan solas.")

    contenido = (_io.cab("OBJETOS DE BD MODIFICADOS", proyecto, cfg["motor"], extra,
                         contexto="entrega incremental")
                 + lines + bloque_retenidos(retenidos) + bloque_eliminados(cambios, cfg["motor"]))

    if not nombre_fichero:
        nombre_fichero = f"{prefijo or siguiente_prefijo(out_dir)}-ObjetosBD.sql"

    destino = out_dir / nombre_fichero
    print(f"\n{len(escritos)} objeto(s) al script:")
    for e in escritos:
        print(f"   - {e}")
    if retenidos:
        print("Retenidos (secuencias modificadas, requieren ALTER a mano):")
        for sec, ns in retenidos.items():
            for n in ns:
                print(f"   - {sec}/{n}")

    if dry:
        print(f"\n(--dry-run: no se ha escrito nada. El script habría sido {destino})")
        return

    out_dir.mkdir(parents=True, exist_ok=True)
    destino.write_text("\n".join(contenido) + "\n", encoding="utf-8")
    print(f"\nOK — {destino}")
    print(f"   ⛔ Decláralo en scripts.json:  {{ \"ruta\": \"{nombre_fichero}\" }}")

    if sincronizar:
        # La línea base avanza SOLO si se pide: hacerlo por defecto significaría que un delta
        # generado y luego descartado deja el modelo diciendo que esos cambios ya se entregaron.
        model["objetos"] = actual
        model["updated_at"] = datetime.now().isoformat()
        tmp = model_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(model, indent=2, ensure_ascii=False), encoding="utf-8")
        tmp.replace(model_path)
        print(f"   Línea base actualizada en {model_path.name}: el próximo delta parte de aquí.")
    else:
        print("   Cuando la entrega esté cerrada, resincroniza la línea base:")
        print("     hooks\\sync-model-objects.ps1 \"<workspace>\"")

    if errores:
        sys.exit(2)


if __name__ == "__main__":
    main()
