"""
El inventario de objetos de BD en `model.json` (`scripts/_dbobjetos.py` y el constructor de
`scripts/model-objects.py`).

⛔ Por qué existe este fichero. La extracción SQL no se puede probar sin un Oracle o un SQL
Server delante, así que la única defensa real está en la lógica que decide QUÉ entra en el
modelo. Y esa lógica tiene tres sitios donde un fallo no daría error, solo un modelo sutilmente
falso:

  1. **La firma.** Si cambia por motivos que no son cambios —CRLF, relleno a la derecha— el
     actualizador reporta como modificado todo el esquema en cada entrega y nadie vuelve a
     mirarlo. Si NO cambia cuando el cuerpo sí cambió, un procedimiento modificado se queda
     fuera del delta. Los dos fallos son silenciosos y opuestos.
  2. **La clasificación PL/SQL.** Oracle antepone el tipo al nombre: `PACKAGE BODY MIPKG`. Si
     "PACKAGE" se prueba antes que "PACKAGE BODY", el cuerpo del paquete se archiva como
     especificación y el modelo miente sobre qué hay en la BD.
  3. **El diff.** Es lo que decide qué viaja en una entrega incremental. Un `estado_cambiado`
     que no se detecte deja un trigger deshabilitado en el cliente creyendo que está activo.

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

_spec = importlib.util.spec_from_file_location("_model_objects", _SCRIPTS / "model-objects.py")
mo = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mo)


class TestNormalizarYFirma:
    def test_el_salto_de_linea_no_cambia_la_firma(self):
        # La BD devuelve CRLF y sqlplus vuelve a convertir el LF: sin normalizar, cada
        # extracción daría una firma distinta y todo saldría como "modificado".
        assert obj.firma("BEGIN\r\n  NULL;\r\nEND;") == obj.firma("BEGIN\n  NULL;\nEND;")

    def test_el_relleno_a_la_derecha_no_cambia_la_firma(self):
        assert obj.firma("SELECT 1;   \n  FROM DUAL;  ") == obj.firma("SELECT 1;\n  FROM DUAL;")

    def test_las_lineas_en_blanco_del_final_no_cuentan(self):
        assert obj.firma("BEGIN NULL; END;\n\n\n") == obj.firma("BEGIN NULL; END;")

    def test_la_indentacion_SI_cuenta(self):
        # Es del autor: aplanarla haría indistinguibles dos versiones que difieren para quien
        # lee el código.
        assert obj.firma("BEGIN\n  NULL;\nEND;") != obj.firma("BEGIN\nNULL;\nEND;")

    def test_un_cambio_real_cambia_la_firma(self):
        assert obj.firma("UPDATE T SET X=1;") != obj.firma("UPDATE T SET X=2;")

    def test_cuerpo_vacio_no_revienta(self):
        assert obj.normalizar("") == ""
        assert obj.normalizar(None) == ""
        assert len(obj.firma("")) == 16


class TestClasificarPlsql:
    def test_package_body_no_se_confunde_con_package(self):
        # El orden de prueba importa: si "PACKAGE" gana, el cuerpo se archiva como
        # especificación y el nombre queda como "BODY MIPKG".
        assert obj.clasificar_plsql("PACKAGE BODY MIPKG") == ("paquetes", "MIPKG")
        assert obj.clasificar_plsql("PACKAGE MIPKG") == ("paquetes", "MIPKG")

    def test_separa_procedimientos_y_funciones(self):
        assert obj.clasificar_plsql("PROCEDURE P_ALTA") == ("procedimientos", "P_ALTA")
        assert obj.clasificar_plsql("FUNCTION F_CALC") == ("funciones", "F_CALC")

    def test_un_nombre_sin_prefijo_es_procedimiento(self):
        # SQL Server no antepone tipo: el nombre llega limpio.
        assert obj.clasificar_plsql("dbo.P_ALTA") == ("procedimientos", "dbo.P_ALTA")

    def test_no_se_come_un_nombre_que_empieza_por_el_tipo(self):
        # `PACKAGES_AUX` empieza por "PACKAGE" pero no es "PACKAGE ".
        assert obj.clasificar_plsql("PROCEDURE PACKAGES_AUX") == ("procedimientos", "PACKAGES_AUX")


class TestTablasUsadas:
    def test_encuentra_las_tablas_del_modelo(self):
        cuerpo = "BEGIN SELECT * FROM RCLIENTES JOIN RPEDIDOS ON 1=1; END;"
        assert obj.tablas_usadas(cuerpo, ["RCLIENTES", "RPEDIDOS", "ROTRA"]) == ["RCLIENTES", "RPEDIDOS"]

    def test_respeta_el_limite_de_palabra(self):
        # RCLIENTES_HIST no es RCLIENTES: sin \b, cambiar una columna de RCLIENTES listaría
        # objetos que no la tocan y el aviso dejaría de servir.
        assert obj.tablas_usadas("SELECT * FROM RCLIENTES_HIST;", ["RCLIENTES"]) == []

    def test_devuelve_ordenado_para_no_producir_diffs_falsos(self):
        cuerpo = "SELECT * FROM ZTAB, ATAB;"
        assert obj.tablas_usadas(cuerpo, ["ZTAB", "ATAB"]) == ["ATAB", "ZTAB"]

    def test_sin_tablas_conocidas_no_revienta(self):
        assert obj.tablas_usadas("SELECT 1", []) == []
        assert obj.tablas_usadas("", ["T"]) == []


class TestComparar:
    def _inv(self, vistas):
        i = obj.inventario_vacio()
        i["vistas"] = vistas
        return i

    def test_detecta_nuevos_eliminados_y_modificados(self):
        v = self._inv({"A": {"firma": "1", "estado": "VALID"},
                       "B": {"firma": "2", "estado": "VALID"}})
        n = self._inv({"A": {"firma": "9", "estado": "VALID"},
                       "C": {"firma": "3", "estado": "VALID"}})
        c = obj.comparar(v, n)["vistas"]
        assert c["modificados"] == ["A"]
        assert c["nuevos"] == ["C"]
        assert c["eliminados"] == ["B"]

    def test_detecta_el_cambio_de_estado_con_el_cuerpo_intacto(self):
        # Un trigger que pasa a DISABLED tiene el MISMO cuerpo: la firma no lo ve. Sin esto,
        # el cliente se queda con un trigger deshabilitado creyendo que está activo.
        v = obj.inventario_vacio(); v["triggers"] = {"T": {"firma": "1", "estado": "VALID"}}
        n = obj.inventario_vacio(); n["triggers"] = {"T": {"firma": "1", "estado": "DISABLED"}}
        assert obj.comparar(v, n)["triggers"]["estado_cambiado"] == ["T"]

    def test_sin_cambios_no_devuelve_la_seccion(self):
        v = self._inv({"A": {"firma": "1", "estado": "VALID"}})
        assert obj.comparar(v, v) == {}

    def test_contra_un_modelo_sin_inventario_todo_es_nuevo(self):
        n = self._inv({"A": {"firma": "1", "estado": "VALID"}})
        assert obj.comparar({}, n)["vistas"]["nuevos"] == ["A"]


class TestConstruir:
    def _salidas(self):
        return {
            "Vistas": {"bloques": {"V_CLI": "CREATE VIEW V_CLI AS\r\nSELECT * FROM RCLIENTES;  "},
                       "disabled": []},
            "Procedimientos": {"bloques": {
                "PACKAGE MIPKG": "PACKAGE MIPKG AS\n  PROCEDURE P;\nEND;",
                "PACKAGE BODY MIPKG": "PACKAGE BODY MIPKG AS\n  PROCEDURE P IS BEGIN UPDATE RPEDIDOS SET X=1; END;\nEND;",
                "PROCEDURE P_SUELTO": "PROCEDURE P_SUELTO IS BEGIN NULL; END;",
                "FUNCTION F_X": "FUNCTION F_X RETURN NUMBER IS BEGIN RETURN 1; END;"},
                "disabled": []},
            "Triggers": {"bloques": {"TR_X": "TRIGGER TR_X ..."}, "disabled": ["TR_X"]},
        }

    def test_el_package_se_funde_en_una_sola_ficha(self):
        inv = mo.construir(self._salidas(), ["RCLIENTES", "RPEDIDOS"])
        assert list(inv["paquetes"]) == ["MIPKG"]
        assert inv["paquetes"]["MIPKG"]["lineas"] == 6      # 3 de la spec + 3 del cuerpo
        assert inv["paquetes"]["MIPKG"]["tablas_usadas"] == ["RPEDIDOS"]

    def test_el_cuerpo_no_se_queda_en_el_modelo(self):
        # `_cuerpo` es un acumulador interno para fundir spec y body. Si se colara, el modelo
        # cargaría con el texto que este diseño evita a propósito guardar.
        inv = mo.construir(self._salidas(), [])
        assert "_cuerpo" not in inv["paquetes"]["MIPKG"]

    def test_una_funcion_declarada_en_la_etapa_de_procedimientos_va_a_funciones(self):
        inv = mo.construir(self._salidas(), [])
        assert "F_X" in inv["funciones"]
        assert "F_X" not in inv["procedimientos"]
        assert list(inv["procedimientos"]) == ["P_SUELTO"]

    def test_el_estado_DISABLED_llega_a_la_ficha(self):
        inv = mo.construir(self._salidas(), [])
        assert inv["triggers"]["TR_X"]["estado"] == "DISABLED"

    def test_las_siete_secciones_existen_siempre(self):
        # El ERD y el diff indexan por sección: una ausente sería un KeyError en el cliente.
        inv = mo.construir({}, [])
        assert all(s in inv for s in obj.SECCIONES)
        assert obj.total(inv) == 0

    def test_dos_extracciones_iguales_dan_el_mismo_inventario(self):
        # Si no, cada sync produce un diff falso en el model.json y nadie revisa los reales.
        a = mo.construir(self._salidas(), ["RCLIENTES", "RPEDIDOS"])
        b = mo.construir(self._salidas(), ["RCLIENTES", "RPEDIDOS"])
        assert a == b
        assert obj.comparar(a, b) == {}
