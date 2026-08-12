"""
Inventario de objetos de BD en `model.json`: las vistas, procedimientos, paquetes, funciones,
triggers, sinónimos y secuencias que hasta ahora solo existían en la BD y en el paquete del
instalador, nunca en el modelo.

QUÉ SE GUARDA, Y POR QUÉ NO EL CUERPO
    Del objeto se guarda su ficha —tipo, estado, nº de líneas, tablas que usa— y una **firma**
    del cuerpo, no el cuerpo. Tres razones, en orden de importancia:

    1. **El instalador sigue extrayendo de la BD viva.** Esa es la garantía que hoy hace que un
       paquete no pueda entregar código viejo: lo que viaja es literalmente lo que hay en la BD.
       Si el modelo pasara a ser la fuente, un `model.json` desactualizado entregaría un
       procedimiento de hace tres meses a un cliente y nada lo avisaría.
    2. **La firma sí permite detectar el cambio**, que es lo que le faltaba a `/rs-actualizador`:
       su delta es por VCS (`FECHA_CORTE` + `vcs_delta` sobre ficheros del repo) y un
       procedimiento modificado en BD no está en el VCS, así que hoy solo viaja si alguien se
       acuerda de escribir el script a mano. Comparando firmas se sabe qué cambió desde la
       última entrega.
    3. Un package puede tener miles de líneas, y el `model.json` se inyecta entero como JSON
       dentro del HTML del ERD.

    ⛔ La firma se calcula sobre el MISMO texto que emitiría el instalador (los `bloques` que
    devuelven los extractores de `installer-objects.py`), no sobre otra lectura de la BD. Es lo
    que hace que "la firma cambió" signifique exactamente "lo que se entregaría ha cambiado", y
    no "alguien reformateó algo".

Este módulo no toca BD: recibe los bloques ya extraídos y decide qué va al modelo.
"""

import hashlib
import re

# Las siete secciones del inventario, en orden de dependencias — el mismo que usa el maestro
# del instalador. `paquetes` va aparte de `procedimientos` aunque el instalador los emita en el
# mismo fichero (ambos ocupan la misma posición de dependencia): en el modelo y en el ERD son
# cosas distintas para quien desarrolla.
SECCIONES = ("secuencias", "vistas", "funciones", "procedimientos",
             "paquetes", "triggers", "sinonimos")

# Etapa de installer-objects.py -> sección del modelo. `Procedimientos` se reparte entre dos
# secciones según el tipo que el propio Oracle antepone al nombre (ver clasificar_plsql).
ETAPA_A_SECCION = {
    "Secuencias": "secuencias",
    "Vistas": "vistas",
    "Funciones": "funciones",
    "Procedimientos": "procedimientos",
    "Triggers": "triggers",
    "Sinonimos": "sinonimos",
}

# Tipos que Oracle antepone al nombre en ALL_SOURCE. El orden importa: "PACKAGE BODY" tiene que
# probarse antes que "PACKAGE" o el cuerpo se clasificaría como especificación.
_TIPOS_PLSQL = ("PACKAGE BODY", "PACKAGE", "PROCEDURE", "FUNCTION", "TYPE BODY", "TYPE")

FIRMA_ALGORITMO = "sha256-16"
_FIRMA_HEX = 16

# ⛔ El DDL de una secuencia lleva su posición actual (`START WITH LAST_NUMBER` en Oracle,
# `START WITH current_value` en SQL Server), y esa posición avanza cada vez que alguien consume
# un valor. Firmando el texto tal cual, TODA secuencia salía como "modificada" en cada
# sincronización: el diff se llenaba de ruido y —peor— el delta del actualizador habría propuesto
# reentregar todas las secuencias en cada entrega. Se descuenta antes de firmar, así que un cambio
# real (INCREMENT BY, CACHE, CYCLE) sí se detecta y el mero avance del contador no.
_START_WITH = re.compile(r"\bSTART\s+WITH\s+[-+]?\d+", re.IGNORECASE)


def normalizar(texto: str) -> str:
    """Texto comparable entre extracciones.

    Sin esto la firma cambiaría por motivos que no son cambios: la BD devuelve CRLF, sqlplus
    vuelve a convertir el LF en CRLF, y el relleno a la derecha depende de la sesión. Se
    normalizan saltos, se recorta cada línea por la derecha y se quitan las líneas en blanco
    del final. ⛔ La indentación NO se toca: en PL/SQL es del autor, y aplanarla haría
    indistinguibles dos versiones que sí difieren para quien lee el código.
    """
    if not texto:
        return ""
    t = texto.replace("\r\n", "\n").replace("\r", "\n")
    return "\n".join(l.rstrip() for l in t.split("\n")).strip()


def firma(texto: str) -> str:
    """Firma del cuerpo, para detectar cambios entre entregas.

    16 hex (64 bits) bastan de sobra: no es un control de integridad frente a un adversario,
    es distinguir dos versiones del mismo procedimiento. Y mantiene el `model.json` legible.
    """
    return hashlib.sha256(normalizar(texto).encode("utf-8")).hexdigest()[:_FIRMA_HEX]


def firma_objeto(cuerpo: str, seccion: str = "") -> str:
    """Firma con la volatilidad propia de la sección ya descontada.

    Es la que hay que usar siempre que se firme un objeto del inventario; `firma()` a secas es
    el cálculo puro y solo vale cuando ya se sabe que el texto es estable.

    Hoy solo las secuencias son volátiles (ver `_START_WITH`). Si mañana aparece otro tipo cuyo
    DDL arrastre estado de ejecución, el descuento va aquí y no en cada llamante.
    """
    if seccion == "secuencias":
        cuerpo = _START_WITH.sub("START WITH <posicion>", cuerpo or "")
    return firma(cuerpo)


def clasificar_plsql(nombre: str) -> tuple:
    """`PACKAGE BODY MIPKG` -> ('paquetes', 'MIPKG'). Devuelve (sección, nombre limpio).

    Oracle antepone el tipo al nombre en la etapa de procedimientos porque ALL_SOURCE mezcla
    PROCEDURE, PACKAGE y PACKAGE BODY en la misma consulta. En SQL Server no existen los
    paquetes y el nombre llega ya limpio, así que ahí esta función no cambia nada.
    """
    n = (nombre or "").strip()
    for tipo in _TIPOS_PLSQL:
        if n.upper().startswith(tipo + " "):
            resto = n[len(tipo):].strip()
            seccion = "paquetes" if tipo.startswith("PACKAGE") else (
                "funciones" if tipo == "FUNCTION" else "procedimientos")
            return seccion, resto
    return "procedimientos", n


def tablas_usadas(cuerpo: str, tablas_conocidas) -> list:
    """Tablas del modelo que aparecen en el cuerpo del objeto.

    ⛔ Es una DERIVACIÓN POR TEXTO, no el diccionario de dependencias de la BD: un nombre de
    tabla dentro de un comentario o de un literal cuenta igual. Se llama `tablas_usadas` y no
    `depende_de` justamente para no prometer una autoridad que no tiene. Vale para lo que se
    quiere —"qué procedimientos tocan RCLIENTES" antes de cambiar una columna—, que es una
    pregunta donde un falso positivo se descarta de un vistazo y un falso negativo duele.

    Se compara con límite de palabra y sin distinguir mayúsculas, y se devuelve ordenado para
    que dos extracciones del mismo objeto den el mismo `model.json` (si no, cada sync
    produciría un diff falso).
    """
    if not cuerpo or not tablas_conocidas:
        return []
    texto = cuerpo.upper()
    encontradas = [t for t in tablas_conocidas
                   if re.search(r"\b" + re.escape(t.upper()) + r"\b", texto)]
    return sorted(set(encontradas))


def ficha(cuerpo: str, tablas_conocidas=(), estado: str = "VALID", extra: dict = None,
          seccion: str = "") -> dict:
    """La entrada que va al modelo para un objeto."""
    cuerpo_n = normalizar(cuerpo)
    d = {
        "estado": estado,
        "firma": firma_objeto(cuerpo, seccion),
        "lineas": len(cuerpo_n.split("\n")) if cuerpo_n else 0,
        "tablas_usadas": tablas_usadas(cuerpo_n, tablas_conocidas),
        "source": "db",
    }
    if extra:
        d.update(extra)
    return d


def inventario_vacio() -> dict:
    return {"_firma": FIRMA_ALGORITMO,
            "_nota": ("Inventario de objetos de BD. Se guarda la ficha y una FIRMA del cuerpo, "
                      "no el cuerpo: el instalador sigue extrayendo de la BD viva, y la firma "
                      "sirve para detectar qué cambió desde la última entrega."),
            **{s: {} for s in SECCIONES}}


def construir(salidas: dict, tablas_conocidas=()) -> dict:
    """Convierte lo extraído —{etapa: resultado de un extractor}— en el inventario del modelo.

    ⛔ Vive aquí, y no en `model-objects.py`, porque hay DOS consumidores: el sync del modelo y
    el contraste de deriva de `installer-objects.py`. Mientras estuvo solo en el sync, el
    contraste plegaba los paquetes a su manera —la especificación y el cuerpo son dos entradas
    de ALL_SOURCE y una sola ficha en el modelo— y se pisaban entre sí, así que TODO paquete
    salía como "firma distinta" en cada instalador. Una alarma que salta siempre es una alarma
    que nadie lee.
    """
    inv = inventario_vacio()

    for etapa, seccion in ETAPA_A_SECCION.items():
        res = salidas.get(etapa)
        if not res:
            continue
        deshabilitados = set(res.get("disabled") or [])
        for nombre, cuerpo in (res.get("bloques") or {}).items():
            destino, limpio = seccion, nombre
            # Oracle mezcla PROCEDURE / PACKAGE / PACKAGE BODY en la misma etapa y antepone el
            # tipo al nombre; en SQL Server no hay paquetes y el nombre llega ya limpio.
            if seccion == "procedimientos":
                destino, limpio = clasificar_plsql(nombre)
            estado = "DISABLED" if nombre in deshabilitados else "VALID"
            f = ficha(cuerpo, tablas_conocidas, estado, seccion=destino)
            if destino == "paquetes":
                # Especificación y cuerpo son dos objetos en ALL_SOURCE y una sola cosa para
                # quien desarrolla: se funden en una ficha, firmando los textos concatenados.
                previa = inv[destino].get(limpio)
                acumulado = normalizar(cuerpo)
                if previa:
                    acumulado = previa.get("_cuerpo", "") + "\n" + acumulado
                    f["lineas"] += previa.get("lineas", 0)
                    f["tablas_usadas"] = sorted(set(previa.get("tablas_usadas", []))
                                                | set(f["tablas_usadas"]))
                f["firma"] = firma_objeto(acumulado, destino)
                f["_cuerpo"] = acumulado
            inv[destino][limpio] = f

    # `_cuerpo` es un acumulador interno para fundir especificación y cuerpo del package;
    # no tiene por qué acabar en el modelo.
    for d in inv["paquetes"].values():
        d.pop("_cuerpo", None)
    return inv


def comparar(viejo: dict, nuevo: dict) -> dict:
    """Qué ha cambiado entre dos inventarios.

    Es lo que consume `/rs-actualizador` para saber qué objetos entran en el delta, y lo que
    usa el instalador para avisar de deriva entre el modelo y la BD.

    Devuelve, por sección: `nuevos`, `eliminados`, `modificados` (misma clave, firma distinta)
    y `estado_cambiado` (p.ej. un trigger que pasó a DISABLED, o una vista que quedó INVALID —
    la firma no lo detecta porque el cuerpo es el mismo).
    """
    res = {}
    for sec in SECCIONES:
        v = (viejo or {}).get(sec) or {}
        n = (nuevo or {}).get(sec) or {}
        nuevos      = sorted(k for k in n if k not in v)
        eliminados  = sorted(k for k in v if k not in n)
        comunes     = [k for k in n if k in v]
        modificados = sorted(k for k in comunes
                             if (v[k] or {}).get("firma") != (n[k] or {}).get("firma"))
        estado      = sorted(k for k in comunes
                             if k not in modificados
                             and (v[k] or {}).get("estado") != (n[k] or {}).get("estado"))
        if nuevos or eliminados or modificados or estado:
            res[sec] = {"nuevos": nuevos, "eliminados": eliminados,
                        "modificados": modificados, "estado_cambiado": estado}
    return res


def para_entregar(cambios: dict) -> tuple:
    """De un `comparar()`, qué tiene que viajar en la entrega y qué NO puede viajar solo.

    Devuelve `(entregables, retenidos)`, ambos {sección: [nombre, ...]} y recorridos en orden de
    dependencias (`SECCIONES`), que es el orden en que hay que ejecutarlos.

    Entra lo `nuevo`, lo `modificado` y lo de `estado_cambiado` —este último porque el cuerpo es
    el mismo pero el `ALTER TRIGGER ... DISABLE` que lo acompaña no, y sin reemitirlo el cliente
    se queda con el estado antiguo.

    ⛔ SALVO LAS SECUENCIAS MODIFICADAS. El DDL de una secuencia es `CREATE`, no `CREATE OR
    REPLACE`: entregarla contra una secuencia que ya existe en el cliente o falla (Oracle,
    ORA-00955) o la borra y la recrea (SQL Server, que emite DROP + CREATE) **reiniciando el
    contador a la posición de NUESTRA base de datos**. Eso repartiría IDs ya usados en el
    cliente. Una secuencia nueva sí viaja; una que cambió de INCREMENT/CACHE/CYCLE sale como
    retenida para que se resuelva a mano con un ALTER, que es lo que corresponde.

    Lo `eliminado` no aparece en ninguna de las dos: ver `delta-objects.py`, se emite comentado.
    """
    entregables, retenidos = {}, {}
    for sec in SECCIONES:
        c = (cambios or {}).get(sec)
        if not c:
            continue
        vivos = list(c.get("nuevos") or [])
        if sec == "secuencias":
            frenados = sorted(set(c.get("modificados") or []) | set(c.get("estado_cambiado") or []))
            if frenados:
                retenidos[sec] = frenados
        else:
            vivos += list(c.get("modificados") or []) + list(c.get("estado_cambiado") or [])
        if vivos:
            entregables[sec] = sorted(set(vivos))
    return entregables, retenidos

def cobertura(visibilidad: dict, capturado: dict, excluido: dict = None) -> dict:
    """Cuánto del esquema se ha llegado a ver, frente a lo que el diccionario dice que hay.

    ⛔ Existe porque un inventario vacío NO significa "no hay objetos de ese tipo". El PL/SQL
    exige GRANT EXECUTE, no SELECT: con cero grants EXECUTE, ALL_OBJECTS y ALL_SOURCE devuelven
    cero procedimientos y cero paquetes SIN ERROR. Medido en una instalación de cliente — tras
    conceder 13 grants aparecieron 12 procedimientos y 1 paquete que hasta entonces "no
    existían". Lo mismo con las tablas: 323 pasaron a 329.

    `visibilidad` es lo que devuelve hooks/db-visibilidad.ps1 (es_dueno, grants, diccionario).
    `capturado` es {sección: n}. `excluido` es {sección: {"n": k, "motivo": "..."}} para lo que
    el propio script descarta a propósito — sin declararlo, una exclusión legítima se cuenta
    como hueco y la cobertura cría avisos que nadie vuelve a mirar.

    Devuelve un dict listo para escribir en el modelo y para imprimir. `parcial` es lo que
    decide el exit 2 del llamante.
    """
    excluido = excluido or {}
    dicc = (visibilidad or {}).get("diccionario") or {}
    es_dueno = bool((visibilidad or {}).get("es_dueno"))

    secciones, huecos = [], 0
    for sec in sorted(capturado):
        real = dicc.get(sec)
        cap  = int(capturado[sec] or 0)
        exc  = int((excluido.get(sec) or {}).get("n") or 0)
        motivo = str((excluido.get(sec) or {}).get("motivo") or "")
        hueco = 0 if real is None else max(0, int(real) - cap - exc)
        secciones.append({"seccion": sec, "real": real, "capturado": cap,
                          "excluido": exc, "motivo": motivo, "hueco": hueco})
        huecos += hueco

    cob = {"es_dueno": es_dueno,
           "usuario": (visibilidad or {}).get("usuario") or "",
           "esquema": (visibilidad or {}).get("esquema") or "",
           "conexion": (visibilidad or {}).get("conexion") or "",
           "grants": (visibilidad or {}).get("grants") or {},
           "secciones": secciones, "huecos": huecos,
           "parcial": huecos > 0, "nota": ""}

    if huecos > 0:
        cob["nota"] = ("Descuadre con la cuenta DUEÑA del esquema: no son permisos, es un filtro "
                       "del propio script."
                       if es_dueno else
                       "La cuenta no es dueña del esquema: el hueco puede ser un objeto real sin "
                       "GRANT. Nada se ha borrado del modelo.")
    elif not es_dueno:
        cob["nota"] = "Cuenta no dueña del esquema, pero el conteo cuadra con el diccionario."
    return cob


def formato_cobertura(cob: dict) -> list:
    """El bloque de cobertura como líneas de texto, para el log. Equivalente de
    Format-RsCobertura en hooks/lib-dbvisibilidad.ps1."""
    quien = "DUEÑA del esquema" if cob.get("es_dueno") else "solo con GRANT per-object"
    l = ["---- Cobertura (conteo real en el diccionario vs capturado) ----",
         f"   Cuenta: {cob.get('usuario')} sobre {cob.get('esquema')} ({quien})"]
    grants = cob.get("grants") or {}
    if grants:
        l.append("   Grants: " + " · ".join(f"{k} {grants[k]}" for k in sorted(grants)))
    elif not cob.get("es_dueno"):
        l.append("   Grants: NINGUNO detectado sobre este esquema.")

    for s in cob.get("secciones") or []:
        real = "n/d" if s["real"] is None else str(s["real"])
        linea = f"   {s['seccion']:<16} diccionario {real:>6}  capturado {s['capturado']:>6}"
        if s["excluido"]:
            linea += f"  excluidas {s['excluido']} ({s['motivo']})"
        if s["hueco"]:
            linea += f"  << HUECO {s['hueco']}"
        l.append(linea)

    if cob.get("nota"):
        l.append(f"   {cob['nota']}")
    if cob.get("parcial") and not cob.get("es_dueno"):
        l.append("   Para cerrarlo: conceder los GRANT que falten (SELECT para tablas y vistas,")
        l.append("   EXECUTE para procedimientos y paquetes) y repetir.")
    return l


def total(inventario: dict) -> int:
    return sum(len((inventario or {}).get(s) or {}) for s in SECCIONES)


def resumen(inventario: dict) -> str:
    """Línea de conteo por sección, para el log y para el SUMMARY del agente."""
    partes = [f"{s[:6]} {len((inventario or {}).get(s) or {})}" for s in SECCIONES]
    return " · ".join(partes)
