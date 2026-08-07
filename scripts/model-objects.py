"""
Sincroniza el inventario de objetos de BD (vistas, procedimientos, paquetes, funciones,
triggers, sinónimos, secuencias) al `BD/<proyecto>-model.json`, sección `objetos`.

⛔ NO duplica ninguna consulta. Reutiliza los extractores de `installer-objects.py` —los
mismos que genera el instalador— y se queda con los `bloques` que devuelven. Es deliberado:
si la firma se calculara sobre otra lectura de la BD, "la firma cambió" dejaría de significar
"lo que entregaría el instalador ha cambiado", que es justo para lo que sirve.

Del cuerpo se guarda la ficha y la firma, nunca el texto: ver `scripts/_dbobjetos.py`.

Uso: python model-objects.py <workspace> <proyecto> [--dry-run]
     --dry-run  no escribe el modelo; imprime el inventario y el diff contra el actual.
"""

import sys
import json
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

# installer-objects.py lleva guion -> no es importable con `import`; se carga por ruta.
_spec = importlib.util.spec_from_file_location("_installer_objects", _AQUI / "installer-objects.py")
_io = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_io)


def extraer(cfg: dict, max_paralelo: int) -> tuple:
    """Lanza los extractores y devuelve ({etapa: resultado}, [errores]).

    En paralelo por el mismo motivo que en el instalador: son independientes y el reloj se lo
    lleva el login, no la consulta. Un tipo que falla NO tumba a los demás — se reporta y el
    inventario sale sin esa sección, que es más útil que no tener inventario.
    """
    etapas = _io.etapas_por_motor(cfg)
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


def construir(salidas: dict, tablas_conocidas) -> dict:
    """Convierte lo extraído en la sección `objetos` del modelo."""
    inv = obj.inventario_vacio()

    for etapa, seccion in obj.ETAPA_A_SECCION.items():
        res = salidas.get(etapa)
        if not res:
            continue
        deshabilitados = set(res.get("disabled") or [])
        for nombre, cuerpo in (res.get("bloques") or {}).items():
            destino, limpio = seccion, nombre
            # Oracle mezcla PROCEDURE / PACKAGE / PACKAGE BODY en la misma etapa y antepone el
            # tipo al nombre; en SQL Server no hay paquetes y el nombre llega ya limpio.
            if seccion == "procedimientos":
                destino, limpio = obj.clasificar_plsql(nombre)
            estado = "DISABLED" if nombre in deshabilitados else "VALID"
            ficha = obj.ficha(cuerpo, tablas_conocidas, estado)
            if destino == "paquetes":
                # Especificación y cuerpo son dos objetos en ALL_SOURCE y una sola cosa para
                # quien desarrolla: se funden en una ficha, firmando los textos concatenados.
                previa = inv[destino].get(limpio)
                acumulado = obj.normalizar(cuerpo)
                if previa:
                    acumulado = previa.get("_cuerpo", "") + "\n" + acumulado
                    ficha["lineas"] += previa.get("lineas", 0)
                    ficha["tablas_usadas"] = sorted(set(previa.get("tablas_usadas", []))
                                                    | set(ficha["tablas_usadas"]))
                ficha["firma"] = obj.firma(acumulado)
                ficha["_cuerpo"] = acumulado
            inv[destino][limpio] = ficha

    # `_cuerpo` es un acumulador interno para fundir especificación y cuerpo del package;
    # no tiene por qué acabar en el modelo.
    for d in inv["paquetes"].values():
        d.pop("_cuerpo", None)
    return inv


def main():
    if len(sys.argv) < 3:
        print(f"Uso: {sys.argv[0]} <workspace> <proyecto> [--dry-run]")
        sys.exit(1)

    workspace, proyecto = sys.argv[1], sys.argv[2]
    dry = "--dry-run" in sys.argv[3:]
    model_path = Path(workspace) / "BD" / f"{proyecto}-model.json"
    if not model_path.exists():
        print(f"ERROR: Modelo no encontrado: {model_path}")
        sys.exit(1)

    with open(model_path, encoding="utf-8-sig") as f:
        model = json.load(f)

    cfg = _io._ins.read_db_config(workspace, model)
    if cfg["motor"] not in ("ORACLE", "SQLSERVER"):
        print(f"ERROR: motor no soportado: {cfg['motor']}")
        sys.exit(1)

    tablas = list((model.get("tables") or {}).keys())
    print(f"Motor: {cfg['motor']} | schema/BD: {cfg['schema']} | {len(tablas)} tablas en el modelo")

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
    tmp = model_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(model, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(model_path)
    print(f"\nOK — objetos sincronizados en {model_path}")

    if errores:
        sys.exit(2)


if __name__ == "__main__":
    main()
