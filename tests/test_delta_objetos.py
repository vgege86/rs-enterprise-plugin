"""
El delta de objetos de BD que viaja en un actualizador (`scripts/delta-objects.py`) y el
maquetado compartido de un objeto en un .sql (`installer-objects.render_objeto`).

⛔ Por qué existe este fichero. Nada de esto se puede probar contra un motor real desde CI, así
que la defensa está en la lógica que decide QUÉ entra en el script y CÓMO se escribe. Hay cuatro
sitios donde un fallo no da error, solo un script sutilmente equivocado que se ejecuta en la BD
de un cliente:

  1. **La firma de las secuencias.** Su DDL lleva la posición actual del contador, que avanza
     sola. Si eso contara como cambio, cada entrega propondría reentregar todas las secuencias.
  2. **Qué se entrega.** Una secuencia modificada NO puede viajar: su DDL es CREATE (DROP+CREATE
     en SQL Server) y reiniciaría el contador del cliente repartiendo IDs ya usados.
  3. **El terminador.** Un bloque PL/SQL sin su '/' no se ejecuta, y el fallo aparece en el
     cliente, no aquí.
  4. **Lo eliminado.** Un DROP activo por un falso positivo borra código en producción.

Nada aquí abre una conexión.
"""
import importlib.util
import sys
from pathlib import Path

_RAIZ = Path(__file__).resolve().parent.parent
_SCRIPTS = _RAIZ / "scripts"
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

import _dbobjetos as obj


def _por_ruta(nombre, fichero):
    spec = importlib.util.spec_from_file_location(nombre, _SCRIPTS / fichero)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


io = _por_ruta("_io_test", "installer-objects.py")
delta = _por_ruta("_delta_test", "delta-objects.py")


# ---------------------------------------------------------------------------- firma volátil
class TestFirmaDeSecuencias:
    _BASE = "CREATE SEQUENCE SEQ_X MINVALUE 1 START WITH 1240 INCREMENT BY 1 CACHE 20 NOCYCLE;"

    def test_el_contador_avanzando_no_cuenta_como_cambio(self):
        # Sin esto, TODA secuencia salía como modificada en cada sincronización y el actualizador
        # habría propuesto reentregarlas — que es justo lo que no puede hacerse con una secuencia.
        despues = self._BASE.replace("START WITH 1240", "START WITH 1260")
        assert obj.firma_objeto(self._BASE, "secuencias") == obj.firma_objeto(despues, "secuencias")

    def test_un_cambio_real_si_cuenta(self):
        otra = self._BASE.replace("INCREMENT BY 1", "INCREMENT BY 10")
        assert obj.firma_objeto(self._BASE, "secuencias") != obj.firma_objeto(otra, "secuencias")

    def test_el_descuento_es_solo_para_secuencias(self):
        # En cualquier otro objeto un "START WITH" es código del autor y sí es un cambio.
        cuerpo = "CREATE OR REPLACE PROCEDURE P IS BEGIN x := START WITH 1; END;"
        otro = cuerpo.replace("START WITH 1", "START WITH 2")
        assert obj.firma_objeto(cuerpo, "procedimientos") != obj.firma_objeto(otro, "procedimientos")

    def test_sin_seccion_es_la_firma_pura(self):
        assert obj.firma_objeto(self._BASE) == obj.firma(self._BASE)


# ---------------------------------------------------------------------------- qué se entrega
class TestParaEntregar:
    def _cambios(self, **kw):
        base = {"nuevos": [], "eliminados": [], "modificados": [], "estado_cambiado": []}
        return {**base, **kw}

    def test_una_secuencia_modificada_no_viaja(self):
        # DROP + CREATE contra el cliente reiniciaría su contador en NUESTRA posición.
        ent, ret = obj.para_entregar({"secuencias": self._cambios(modificados=["SEQ_X"])})
        assert ent == {}
        assert ret == {"secuencias": ["SEQ_X"]}

    def test_una_secuencia_nueva_si_viaja(self):
        ent, ret = obj.para_entregar({"secuencias": self._cambios(nuevos=["SEQ_NUEVA"],
                                                                 modificados=["SEQ_X"])})
        assert ent == {"secuencias": ["SEQ_NUEVA"]}
        assert ret == {"secuencias": ["SEQ_X"]}

    def test_el_cambio_de_estado_entra(self):
        # El cuerpo es el mismo pero el ALTER TRIGGER que lo acompaña no: sin reemitirlo el
        # cliente se queda con el trigger en el estado antiguo.
        ent, _ = obj.para_entregar({"triggers": self._cambios(estado_cambiado=["TR_X"])})
        assert ent == {"triggers": ["TR_X"]}

    def test_lo_eliminado_no_entra_por_ninguna_de_las_dos_vias(self):
        ent, ret = obj.para_entregar({"vistas": self._cambios(eliminados=["V_VIEJA"])})
        assert ent == {} and ret == {}

    def test_sin_duplicados_y_ordenado(self):
        ent, _ = obj.para_entregar({"vistas": self._cambios(nuevos=["V_B"], modificados=["V_A", "V_B"])})
        assert ent["vistas"] == ["V_A", "V_B"]


# ---------------------------------------------------------------------------- maquetado
class TestRenderObjeto:
    def test_el_bloque_plsql_lleva_su_terminador(self):
        # Sin el '/' sqlplus no ejecuta el bloque, y eso se descubre en el cliente.
        l = io.render_objeto("procedimientos", "PROCEDURE P", "CREATE OR REPLACE PROCEDURE P...", "ORACLE")
        assert "/" in l

    def test_en_sqlserver_no_hay_terminador_de_sqlplus(self):
        # Los cuerpos de SQL Server ya vienen con sus GO desde el catálogo; un '/' suelto sería
        # un error de sintaxis en sqlcmd.
        l = io.render_objeto("procedimientos", "dbo.P", "CREATE PROCEDURE dbo.P AS...", "SQLSERVER")
        assert "/" not in l

    def test_una_vista_no_es_plsql(self):
        assert "/" not in io.render_objeto("vistas", "V_X", "CREATE OR REPLACE VIEW V_X AS ...;", "ORACLE")

    def test_el_trigger_deshabilitado_se_replica_deshabilitado(self):
        l = io.render_objeto("triggers", "TR_X", "CREATE OR REPLACE TRIGGER TR_X ...", "ORACLE", True)
        assert "ALTER TRIGGER TR_X DISABLE;" in l

    def test_el_trigger_activo_no_lleva_disable(self):
        l = io.render_objeto("triggers", "TR_X", "CREATE OR REPLACE TRIGGER TR_X ...", "ORACLE", False)
        assert not any("DISABLE" in x for x in l)

    def test_en_sqlserver_el_disable_ya_viene_en_el_cuerpo_y_no_se_duplica(self):
        cuerpo = "CREATE TRIGGER ...\nGO\nDISABLE TRIGGER [dbo].[TR_X] ON [dbo].[T];\nGO"
        l = io.render_objeto("triggers", "dbo.TR_X", cuerpo, "SQLSERVER", True)
        assert sum(1 for x in l if "DISABLE TRIGGER" in x) == 1

    def test_el_sinonimo_no_lleva_comentario_de_cabecera(self):
        # Su propio CREATE ya dice el nombre; el comentario solo añadía ruido.
        l = io.render_objeto("sinonimos", "SYN_X", "CREATE OR REPLACE SYNONYM SYN_X FOR T;", "ORACLE")
        assert not any(x.startswith("--") for x in l)

    def test_las_secciones_con_el_tipo_en_el_nombre_no_lo_repiten(self):
        # Oracle antepone el tipo en ALL_SOURCE: "-- Procedimiento PROCEDURE P" sería absurdo.
        l = io.render_objeto("procedimientos", "PROCEDURE P", "x", "ORACLE")
        assert l[0] == "-- PROCEDURE P"
        assert io.render_objeto("vistas", "V_X", "x", "ORACLE")[0] == "-- Vista V_X"


# ---------------------------------------------------------------------------- índice y render
_SALIDAS = {
    "Vistas": {"bloques": {"V_CLI": "CREATE OR REPLACE FORCE VIEW V_CLI AS SELECT 1 FROM DUAL;"},
               "disabled": []},
    "Procedimientos": {"bloques": {
        "PACKAGE MIPKG": "CREATE OR REPLACE PACKAGE MIPKG AS\n  PROCEDURE P;\nEND;",
        "PACKAGE BODY MIPKG": "CREATE OR REPLACE PACKAGE BODY MIPKG AS\n  PROCEDURE P IS BEGIN NULL; END;\nEND;",
        "PROCEDURE P_SUELTO": "CREATE OR REPLACE PROCEDURE P_SUELTO IS BEGIN NULL; END;"},
        "disabled": []},
    "Triggers": {"bloques": {"TR_X": "CREATE OR REPLACE TRIGGER TR_X ..."}, "disabled": ["TR_X"]},
    "Secuencias": {"bloques": {"SEQ_N": "CREATE SEQUENCE SEQ_N START WITH 1 INCREMENT BY 1;"},
                   "disabled": []},
}


class TestIndiceBloques:
    def test_el_paquete_agrupa_especificacion_y_cuerpo_en_ese_orden(self):
        # Si el cuerpo se emitiera antes que la especificación, no compila.
        idx = delta.indice_bloques(_SALIDAS)
        visibles = [v for v, _c in idx[("paquetes", "MIPKG")]["bloques"]]
        assert visibles == ["PACKAGE MIPKG", "PACKAGE BODY MIPKG"]

    def test_un_procedimiento_suelto_no_acaba_en_paquetes(self):
        idx = delta.indice_bloques(_SALIDAS)
        assert ("procedimientos", "P_SUELTO") in idx
        assert ("paquetes", "P_SUELTO") not in idx

    def test_el_estado_deshabilitado_llega_al_indice(self):
        assert delta.indice_bloques(_SALIDAS)[("triggers", "TR_X")]["disabled"] is True


class TestRenderDelDelta:
    def test_respeta_el_orden_de_dependencias(self):
        # Un trigger sobre una vista que aún no existe falla; el orden es el del instalador.
        entregables = {"triggers": ["TR_X"], "vistas": ["V_CLI"], "secuencias": ["SEQ_N"]}
        lineas, _ = delta.render(entregables, delta.indice_bloques(_SALIDAS), "ORACLE")
        texto = "\n".join(lineas)
        assert texto.index("SECUENCIAS (") < texto.index("VISTAS (") < texto.index("TRIGGERS (")

    def test_el_paquete_sale_entero(self):
        lineas, escritos = delta.render({"paquetes": ["MIPKG"]},
                                        delta.indice_bloques(_SALIDAS), "ORACLE")
        texto = "\n".join(lineas)
        assert "PACKAGE MIPKG AS" in texto and "PACKAGE BODY MIPKG AS" in texto
        assert escritos == ["paquetes/MIPKG"]

    def test_un_objeto_sin_cuerpo_se_anuncia_y_no_se_cuenta(self):
        # Preferible un hueco visible a un script silenciosamente incompleto.
        lineas, escritos = delta.render({"vistas": ["V_FANTASMA"]},
                                        delta.indice_bloques(_SALIDAS), "ORACLE")
        assert escritos == []
        assert any("V_FANTASMA" in l and "NO se ha podido generar" in l for l in lineas)


class TestBloquesDeAviso:
    def test_ningun_drop_queda_activo(self):
        cambios = {"vistas": {"nuevos": [], "eliminados": ["V_VIEJA"], "modificados": [],
                              "estado_cambiado": []}}
        for motor in ("ORACLE", "SQLSERVER"):
            for l in delta.bloque_eliminados(cambios, motor):
                assert not l.strip() or l.strip().startswith("--")

    def test_sin_eliminados_no_hay_bloque(self):
        assert delta.bloque_eliminados({}, "ORACLE") == []

    def test_las_secuencias_retenidas_se_nombran_una_a_una(self):
        l = delta.bloque_retenidos({"secuencias": ["SEQ_A", "SEQ_B"]})
        assert any("SEQ_A" in x for x in l) and any("SEQ_B" in x for x in l)


class TestPrefijo:
    def test_cae_en_la_franja_reservada(self, tmp_path):
        # Después de los scripts de las tareas, antes del 99-RVERSIONES.
        (tmp_path / "01-TAREA-uno.sql").write_text("x")
        (tmp_path / "99-RVERSIONES-TEST.sql").write_text("x")
        assert delta.siguiente_prefijo(tmp_path) == "90"

    def test_no_pisa_uno_ya_usado(self, tmp_path):
        (tmp_path / "90-ObjetosBD.sql").write_text("x")
        assert delta.siguiente_prefijo(tmp_path) == "91"

    def test_carpeta_inexistente_no_revienta(self, tmp_path):
        assert delta.siguiente_prefijo(tmp_path / "no-existe") == "90"


# ------------------------------------------------------- constructor compartido con el instalador
class TestConstructorCompartido:
    def test_el_paquete_firma_igual_lo_construya_quien_lo_construya(self):
        # El contraste de deriva del instalador plegaba los paquetes por su cuenta y la
        # especificación y el cuerpo se pisaban: TODO paquete salía como "firma distinta" en cada
        # instalador. Ahora los dos pasan por el mismo constructor.
        a = obj.construir(_SALIDAS, [])
        b = obj.construir(_SALIDAS, [])
        assert a["paquetes"]["MIPKG"]["firma"] == b["paquetes"]["MIPKG"]["firma"]
        assert obj.comparar(a, b) == {}

    def test_el_avance_del_contador_de_una_secuencia_no_produce_diff(self):
        otras = dict(_SALIDAS)
        otras["Secuencias"] = {"bloques": {"SEQ_N": "CREATE SEQUENCE SEQ_N START WITH 977 INCREMENT BY 1;"},
                               "disabled": []}
        assert obj.comparar(obj.construir(_SALIDAS, []), obj.construir(otras, [])) == {}
