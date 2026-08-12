"""
Sincroniza el inventario de objetos de BD (vistas, procedimientos, paquetes, funciones,
triggers, sinónimos, secuencias) al `BD/<proyecto>-model.json`, sección `objetos`.

⛔ NO duplica ninguna consulta. Reutiliza los extractores de `installer-objects.py` —los
mismos que genera el instalador— y se queda con los `bloques` que devuelven. Es deliberado:
si la firma se calculara sobre otra lectura de la BD, "la firma cambió" dejaría de significar
"lo que entregaría el instalador ha cambiado", que es justo para lo que sirve.

Del cuerpo se guarda la ficha y la firma, nunca el texto: ver `scripts/_dbobjetos.py`.

Uso: python model-objects.py <workspace> <proyecto> [--dry-run] [--conexion <id>]
     --dry-run       no escribe el modelo; imprime el inventario y el diff contra el actual.
     --conexion <id> conexión de docs\\.rs-databases.json a usar. Sin ella, la principal.

⛔ Un inventario vacío NO significa "no hay objetos de ese tipo". El PL/SQL exige GRANT EXECUTE
(no SELECT), y con 0 grants EXECUTE tanto ALL_OBJECTS como ALL_SOURCE devuelven cero
procedimientos SIN ERROR. Por eso se emite un bloque de cobertura contrastando lo capturado con
lo que el diccionario dice que hay, y se sale con 2 (parcial) cuando queda hueco: ver
`hooks/db-visibilidad.ps1`.
"""

import sys
import importlib.util
import concurrent.futures
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
import _modeljson

# installer-objects.py lleva guion -> no es importable con `import`; se carga por ruta.
_spec = importlib.util.spec_from_file_location("_installer_objects", _AQUI / "installer-objects.py")
_io = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_io)


def extraer(cfg: dict, max_paralelo: int, solo=None) -> tuple:
    """Lanza los extractores y devuelve ({etapa: resultado}, [errores]).

    En paralelo por el mismo motivo que en el instalador: son independientes y el reloj se lo
    lleva el login, no la consulta. Un tipo que falla NO tumba a los demás — se reporta y el
    inventario sale sin esa sección, que es más útil que no tener inventario.

    `solo` limita las etapas a las secciones indicadas (nombres de `_dbobjetos.SECCIONES`), para
    quien solo quiere el DDL de un objeto y no va a pagar seis sesiones por él. `paquetes` sale
    de la misma etapa que `procedimientos`.
    """
    etapas = _io.etapas_por_motor(cfg)
    if solo:
        quiero = {("procedimientos" if s == "paquetes" else s) for s in solo}
        etapas = [e for e in etapas if obj.ETAPA_A_SECCION.get(e[1]) in quiero]
        if not etapas:
            return {}, []
    workers = max(1, min(len(etapas), max_paralelo))
    salidas, errores = {}, []

    def _uno(etapa):
        num, fichero, titulo, fn = etapa
        try:
            return fichero, fn(), None
        except Exception as e:
            # Se devuelve el FICHERO, no el título: el título lleva acento ("SINÓNIMOS") y la
            # recuperación de más abajo indexa por fichero. Con el título no casaba y la
            # sección se perdía igual que si no hubiera recuperación.
            return fichero, None, (fichero, titulo,
                                   str(e).splitlines()[0] if str(e) else "error desconocido")

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        for fut in concurrent.futures.as_completed([ex.submit(_uno, e) for e in etapas]):
            fichero, res, err = fut.result()
            if err:
                errores.append(err)
            else:
                salidas[fichero] = res
    return salidas, errores


# El constructor del inventario vive en `_dbobjetos.py`: lo comparte con el contraste de deriva
# del instalador, que antes plegaba los paquetes por su cuenta y los daba todos por modificados.
construir = obj.construir


def main():
    if len(sys.argv) < 3:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto> [--dry-run] [--conexion <id>]")
        sys.exit(1)

    workspace, proyecto = sys.argv[1], sys.argv[2]
    dry = "--dry-run" in sys.argv[3:]
    conexion = _io._ins.arg_conexion(sys.argv[3:])
    model_path = Path(workspace) / "BD" / f"{proyecto}-model.json"
    if not model_path.exists():
        print(f"ERROR: Modelo no encontrado: {model_path}")
        sys.exit(1)

    model = _modeljson.cargar(model_path)

    cfg = _io._ins.read_db_config(workspace, model, conexion)
    if cfg["motor"] not in ("ORACLE", "SQLSERVER"):
        print(f"ERROR: motor no soportado: {cfg['motor']}")
        sys.exit(1)

    tablas = list((model.get("tables") or {}).keys())
    print(f"Motor: {cfg['motor']} | schema/BD: {cfg['schema']} | {len(tablas)} tablas en el modelo")
    if cfg.get("conexion"):
        print(f"Conexión: {cfg['conexion']}")

    salidas, errores = extraer(cfg, _io._ins.read_max_paralelo(workspace, proyecto))
    for _fichero, titulo, err in errores:
        print(f"   ERROR en {titulo}: {err}")

    nuevo  = construir(salidas, tablas)
    previo = model.get("objetos") or {}
    print(f"\nInventario: {obj.resumen(nuevo)}  (total {obj.total(nuevo)})")

    cambios = obj.comparar(previo, nuevo)
    if previo and cambios:
        print("\nCambios respecto al modelo actual:")
        for sec, c in cambios.items():
            for etiqueta in ("nuevos", "eliminados", "modificados", "estado_cambiado"):
                if c[etiqueta]:
                    print(f"   {sec:<15} {etiqueta:<16} {', '.join(c[etiqueta][:8])}"
                          f"{' ...' if len(c[etiqueta]) > 8 else ''}")
    elif previo:
        print("Sin cambios respecto al modelo actual.")

    # ---- cobertura: ¿este inventario está completo, o es lo poco que esta cuenta ve? ----
    # ⛔ Sin esto, "0 procedimientos" y "no hay procedimientos" son la misma frase. El PL/SQL
    # exige GRANT EXECUTE (no SELECT) y con 0 EXECUTE el diccionario devuelve cero sin error.
    cob = None
    vis = _io._ins.read_visibilidad(workspace, conexion)
    if vis.get("soportado"):
        capturado = {s: len(nuevo.get(s) or {}) for s in obj.SECCIONES}
        cob = obj.cobertura(vis, capturado, _io.exclusiones_cobertura(salidas))
        print()
        for ln in obj.formato_cobertura(cob):
            print(ln)
        nuevo["_cobertura"] = cob
    elif vis.get("error"):
        print(f"\nAVISO: sin diagnóstico de cobertura ({vis['error']})")

    if dry:
        print("\n(--dry-run: no se ha escrito el modelo)")
        return

    # ⛔ Si un tipo falló, su sección saldría vacía y el diff lo leería como "se han eliminado
    # todas las vistas". Se conserva lo que hubiera para no destruir inventario por un error
    # de conexión puntual, y se dice.
    for fichero, _titulo, _err in errores:
        sec = obj.ETAPA_A_SECCION.get(fichero)
        if sec and previo.get(sec):
            nuevo[sec] = previo[sec]
            print(f"AVISO: '{sec}' se conserva del modelo anterior porque su extracción falló.")

    model["objetos"] = nuevo
    model["updated_at"] = datetime.now().isoformat()
    # Escritura canónica, atómica y verificada: ver scripts/_modeljson.py.
    _modeljson.guardar(model, model_path)
    print(f"\nOK — objetos sincronizados en {model_path}")

    # exit 2 = PARCIAL. Dos causas distintas con la misma consecuencia para el llamante —el
    # inventario no está completo—: un tipo de objeto que falló al extraerse, o un hueco de
    # cobertura (objetos que el diccionario ve y esta cuenta no).
    if errores or (cob and cob.get("parcial")):
        sys.exit(2)


if __name__ == "__main__":
    main()
