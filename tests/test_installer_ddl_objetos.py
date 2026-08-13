"""
Las dos piezas de la etapa de scripts de `/rs-instalador` que decidían, en silencio, qué NO
llegaba al servidor del cliente: el DDL de tablas (`scripts/installer-ddl.py`) y la extracción
de objetos de BD (`scripts/installer-objects.py`).

⛔ Por qué existe este fichero. Las tres cosas que un cliente reportó como ausentes del
instalador —vistas, procedimientos y valores por defecto— no fallaban con un error: salían
como un paquete aparentemente correcto y más pequeño.

  1. **Valores DEFAULT.** El generador de DDL no leía el campo `default` de la columna, así que
     el `CREATE TABLE` entregado no lo llevaba. En el cliente, toda columna con default queda a
     NULL en el primer INSERT que no la nombre — y eso no da error, se descubre consultando.
     Aquí se fija además el ORDEN del fragmento (`TIPO DEFAULT x NOT NULL`): al revés no es
     sintaxis válida en ninguno de los dos motores.
  2. **Un default es una EXPRESIÓN, no un tipo.** `adapt_type` traduce tipos entre motores;
     `SYSDATE` -> `getdate()` no lo traduce nadie. Generar para un motor distinto al del modelo
     e inlinear el default produciría un `CREATE TABLE` que revienta ENTERO en el cliente, así
     que en ese caso tienen que salir aparte y comentados.
  3. **SQL Server no estaba implementado en la extracción de objetos.** El script salía con un
     AVISO y exit 0: ni vistas, ni funciones, ni procedimientos, ni triggers, ni sinónimos. El
     reparto de etapas por motor es lo que hace que ese agujero no pueda repetirse en silencio.

Portabilidad: no toca BD ni lanza sqlplus/sqlcmd — solo lógica pura y el SQL que se construye.
Higiene: todo el fixture es sintético (`RTABLA`, `MIPROYECTO`) — ningún nombre real de cliente.
"""
import importlib.util
import json
import sys
from pathlib import Path

import pytest

_RAIZ = Path(__file__).resolve().parent.parent
_SCRIPTS = _RAIZ / "scripts"

# scripts/ en sys.path: installer-ddl.py importa _dbtypes con `from _dbtypes import ...`.
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))


def _cargar(nombre):
    """Los módulos llevan guion -> no son importables con `import`; se cargan por ruta."""
    spec = importlib.util.spec_from_file_location(nombre.replace("-", "_"), _SCRIPTS / f"{nombre}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ⛔ `installer-ddl.py` está RETIRADO (3.26.0): el DDL del instalador ya no sale del modelo.
# La lógica que consumía el modelo —orden de la PK, expresión del DEFAULT— sigue viva en
# `_dbmodel.py` y en `generate-sql.py`, que es un generador de DESARROLLO (/rs-erd) y ahí el
# modelo sí es la fuente legítima. Los tests de esa lógica se apuntan ahí; lo que se entrega al
# cliente lo cubre tests/test_installer_tablas.py, contra la extracción de la BD.
gsql = _cargar("generate-sql")
shim = _cargar("installer-ddl")
obj = _cargar("installer-objects")

import _dbmodel


# --------------------------------------------------------------- column_default
class TestColumnDefault:
    def test_columna_sin_default_da_cadena_vacia(self):
        assert _dbmodel.column_default({"type": "NUMBER(10)"}) == ""
        assert _dbmodel.column_default({"type": "NUMBER(10)", "default": None}) == ""

    def test_cero_y_cadena_vacia_son_defaults_reales(self):
        # `0` y `'N'` son falsy o casi: la comprobación tiene que ir contra la cadena vacía,
        # nunca contra la falsedad del valor, o se pierden justo los defaults más comunes.
        assert _dbmodel.column_default({"default": "0"}) == "0"
        assert _dbmodel.column_default({"default": 0}) == "0"
        assert _dbmodel.column_default({"default": "'N'"}) == "'N'"

    def test_recorta_espacios_del_diccionario(self):
        # Oracle devuelve DATA_DEFAULT con relleno; sin recortar, el DDL sale con espacios.
        assert _dbmodel.column_default({"default": "  SYSDATE  "}) == "SYSDATE"


# --------------------------------------------------------------- CREATE TABLE
def _tabla():
    return {
        "description": "Tabla de prueba",
        "columns": {
            "ID":      {"type": "NUMBER(10)", "nullable": False, "pk": 1},
            "ESTADO":  {"type": "CHAR(1)",    "nullable": False, "pk": False, "default": "'A'"},
            "F_ALTA":  {"type": "DATE",       "nullable": False, "pk": False, "default": "SYSDATE"},
            "SALDO":   {"type": "NUMBER(12,2)", "nullable": True, "pk": False, "default": "0"},
        },
    }


class TestGenerateCreateTable:
    def test_emite_el_default_entre_el_tipo_y_el_not_null(self):
        sql = gsql.generate_create_table("RTABLA", _tabla(), "ORACLE", "ORACLE")
        assert "ESTADO CHAR(1 CHAR) DEFAULT 'A' NOT NULL" in sql
        assert "F_ALTA DATE DEFAULT SYSDATE NOT NULL" in sql
        # Nullable con default: sin NOT NULL detrás, pero el DEFAULT sigue estando.
        assert "SALDO NUMBER(12,2) DEFAULT 0" in sql
        # ⛔ "NOT NULL DEFAULT x" es error de sintaxis en Oracle y en SQL Server.
        assert "NOT NULL DEFAULT" not in sql

    def test_columna_sin_default_no_gana_la_palabra_DEFAULT(self):
        sql = gsql.generate_create_table("RTABLA", _tabla(), "ORACLE", "ORACLE")
        linea = [l for l in sql.splitlines() if l.strip().startswith("ID ")][0]
        assert "DEFAULT" not in linea

    def test_la_coma_separadora_no_se_come_el_comentario(self):
        # Cicatriz previa (ORA-00907): el comentario nunca puede ir antes de la coma. El
        # DEFAULT se mete entre tipo y NOT NULL, así que esto se vuelve a comprobar aquí.
        t = _tabla()
        t["columns"]["ESTADO"]["description"] = "Estado del registro"
        sql = gsql.generate_create_table("RTABLA", t, "ORACLE", "ORACLE")
        linea = [l for l in sql.splitlines() if "ESTADO CHAR" in l][0]
        assert linea.rstrip().index(",") < linea.index("--")


# --------------------------------------------------------------- fichero completo
def _modelo(engine="ORACLE"):
    return {"version": "1.0", "project": "MIPROYECTO", "engine": engine,
            "schema": "RSMIPROY", "tables": {"RTABLA": _tabla()}}


class TestInstallerDdlRetirado:
    """El shim tiene que NEGARSE, no generar.

    Se deja el fichero en su sitio a propósito: borrarlo haría que un llamante antiguo diera
    "no such file" —un error de infraestructura, que se arregla restaurando el fichero— en vez
    de explicar que la fuente del DDL ha cambiado. El error es la documentación.
    """

    def test_ejecutarlo_falla_con_codigo_distinto_de_cero(self):
        with pytest.raises(SystemExit) as e:
            shim.main()
        assert e.value.code != 0

    def test_dice_cual_es_el_sustituto(self, capsys):
        with pytest.raises(SystemExit):
            shim.main()
        salida = capsys.readouterr().out
        assert "installer-tablas.py" in salida
        assert "retirado" in salida.lower()

    def test_importarlo_no_revienta(self):
        # Si el shim hiciera sys.exit(1) durante el import, este fichero sería inimportable y
        # ni siquiera se podría comprobar que se niega.
        assert shim.MOTIVO


# --------------------------------------------------------------- orden de la PK
class TestOrdenPk:
    """El orden de la PK es el del índice que la respalda; cambiarlo pierde los accesos por
    prefijo de clave. No da error: el DDL es válido, solo que el índice es otro."""

    def _tabla(self, pks):
        return {"columns": {c: {"type": "NUMBER(10)", "nullable": False, "pk": v}
                            for c, v in pks.items()}}

    def test_el_ordinal_manda_sobre_el_orden_de_declaracion(self):
        # Columnas declaradas ID_MOV, COD_EMP; PK real (COD_EMP, ID_MOV).
        t = self._tabla({"ID_MOV": 2, "COD_EMP": 1, "FECHA": False})
        assert _dbmodel.pk_columns(t) == ["COD_EMP", "ID_MOV"]

    def test_sin_ordinales_se_respeta_el_orden_de_declaracion(self):
        # Modelos anteriores al ordinal siguen valiendo; es lo mejor que se puede hacer.
        t = self._tabla({"ID_MOV": True, "COD_EMP": True})
        assert _dbmodel.pk_columns(t) == ["ID_MOV", "COD_EMP"]

    def test_pk_true_no_se_confunde_con_el_ordinal_1(self):
        # bool es subclase de int en Python: sin descartarlo, `True` contaría como posición 1.
        t = self._tabla({"A": True, "B": True, "C": False})
        assert _dbmodel.pk_columns(t) == ["A", "B"]

    def test_el_CREATE_TABLE_emite_la_PK_en_su_orden_real(self):
        t = {"columns": {
            "ID_MOV":  {"type": "NUMBER(12)", "nullable": False, "pk": 2},
            "COD_EMP": {"type": "VARCHAR2(4)", "nullable": False, "pk": 1},
            "FECHA":   {"type": "DATE", "nullable": False, "pk": False}}}
        sql = gsql.generate_create_table("RMOVIM", t, "ORACLE", "ORACLE")
        assert "PRIMARY KEY (COD_EMP, ID_MOV)" in sql
        # y las columnas siguen en su orden de tabla, que es independiente
        assert sql.index("ID_MOV NUMBER") < sql.index("COD_EMP VARCHAR2")

    def test_el_estado_MIXTO_no_se_ordena_a_medias(self):
        """Una tabla con unas columnas en ordinal y otras en `true` no se puede ordenar.

        Antes SÍ se ordenaba, y era peor que no hacer nada: `true` contaba como ordinal 0 y se
        iba al final, así que (A=true, B=2) salía como (B, A) — la clave invertida, sin error.
        """
        t = self._tabla({"COD_EMP": True, "ID_MOV": 2})
        assert _dbmodel.pk_columns(t) == ["COD_EMP", "ID_MOV"]      # orden de declaración
        assert _dbmodel.pk_orden_ambiguo(t) is True

    def test_una_tabla_coherente_no_se_marca_como_ambigua(self):
        assert _dbmodel.pk_orden_ambiguo(self._tabla({"A": 1, "B": 2})) is False
        assert _dbmodel.pk_orden_ambiguo(self._tabla({"A": True, "B": True})) is False
        assert _dbmodel.pk_orden_ambiguo(self._tabla({"A": False, "B": False})) is False

    def test_las_columnas_que_no_son_PK_no_cuentan_para_la_ambiguedad(self):
        # `pk: false` no es "la otra forma": es no ser clave. Contarlo daría un falso aviso
        # en toda tabla con PK por ordinal, que es justo lo que escribe el sync ahora.
        t = self._tabla({"A": 1, "B": 2, "C": False})
        assert _dbmodel.pk_orden_ambiguo(t) is False
        assert _dbmodel.pk_columns(t) == ["A", "B"]

    def test_los_dos_generadores_de_DDL_usan_la_misma_funcion(self):
        # Estaban duplicados y generate-sql.py no ordenaba: mismo objeto, no dos copias.
        import _dbmodel
        import importlib.util as _u
        spec = _u.spec_from_file_location("_gen_sql", _SCRIPTS / "generate-sql.py")
        gen = _u.module_from_spec(spec)
        spec.loader.exec_module(gen)
        assert gen.pk_columns is _dbmodel.pk_columns
        assert gen.column_default is _dbmodel.column_default
        assert gen.pk_orden_ambiguo is _dbmodel.pk_orden_ambiguo


# --------------------------------------------------------------- objetos por motor
_CFG_SS = {"motor": "SQLSERVER", "schema": "MIBD", "user": "u", "password": "p",
           "datasource": "srv"}
_CFG_OR = {"motor": "ORACLE", "schema": "RSMIPROY", "user": "u", "password": "p",
           "datasource": "srv"}


class TestEtapasPorMotor:
    @pytest.mark.parametrize("cfg", [_CFG_OR, _CFG_SS])
    def test_los_dos_motores_declaran_los_seis_tipos_y_en_el_mismo_orden(self, cfg):
        # El maestro y el manifiesto del paquete referencian los ficheros por su número: si un
        # motor se saltara un tipo o los ordenara distinto, el paquete quedaría descuadrado.
        etapas = obj.etapas_por_motor(cfg)
        assert [(n, f) for n, f, _t, _fn in etapas] == [
            ("01", "Secuencias"), ("02", "Vistas"), ("03", "Funciones"),
            ("04", "Procedimientos"), ("05", "Triggers"), ("06", "Sinonimos"),
        ]

    def test_sqlserver_ya_no_es_un_agujero_silencioso(self, cfg=_CFG_SS):
        # Antes: "AVISO: solo implementada para ORACLE" + exit 0. El paquete salía sin vistas
        # ni procedimientos y la etapa se reportaba correcta.
        assert len(obj.etapas_por_motor(cfg)) == 6


class TestSqlServerGenerado:
    """El T-SQL no se ejecuta aquí; se comprueba lo que tiene que llevar sí o sí."""

    def _sql_de(self, generador):
        capturado = {}

        def falso(cfg, body):
            capturado["sql"] = body
            return ""

        original, obj.run_sqlcmd = obj.run_sqlcmd, falso
        try:
            generador()
        finally:
            obj.run_sqlcmd = original
        return capturado["sql"]

    def test_las_vistas_salen_de_sys_sql_modules_con_drop_condicional(self):
        sql = self._sql_de(lambda: obj.ss_modulos(_CFG_SS, ["V"], "VIEW"))
        assert "sys.sql_modules" in sql
        assert "m.definition" in sql
        assert "IS NOT NULL DROP VIEW" in sql
        # CREATE VIEW tiene que ser la primera sentencia de su lote.
        assert "'GO'" in sql

    def test_los_procedimientos_incluyen_los_tipos_P_y_PC(self):
        sql = self._sql_de(lambda: obj.ss_modulos(_CFG_SS, ["P", "PC"], "PROCEDURE"))
        assert "o.type IN ('P', 'PC')" in sql
        assert "IS NOT NULL DROP PROCEDURE" in sql

    def test_los_objetos_del_sistema_quedan_fuera(self):
        sql = self._sql_de(lambda: obj.ss_modulos(_CFG_SS, ["V"], "VIEW"))
        assert "is_ms_shipped = 0" in sql

    def test_un_trigger_deshabilitado_en_origen_se_replica_deshabilitado(self):
        # Instalar activo un trigger que en origen estaba DISABLED cambia el comportamiento de
        # la aplicación en el cliente.
        sql = self._sql_de(lambda: obj.ss_triggers(_CFG_SS))
        assert "tr.is_disabled" in sql
        assert "DISABLE TRIGGER" in sql

    def test_marcadores_dentro_del_result_set_y_no_por_PRINT(self):
        # Dentro de un lote, el flujo de mensajes (PRINT) y el de resultados no llegan
        # necesariamente intercalados en orden: el marcador dejaría de identificar su objeto.
        sql = self._sql_de(lambda: obj.ss_modulos(_CFG_SS, ["V"], "VIEW"))
        assert sql.lstrip().startswith("SELECT")
        assert "PRINT" not in sql
        assert obj.OBJ_MARK in sql and obj.END_MARK in sql


class TestCabecera:
    def test_la_cabecera_de_sqlserver_no_lleva_directivas_de_sqlplus(self):
        # `SET DEFINE OFF` / `SET SQLBLANKLINES ON` son de sqlplus: en un fichero que va a
        # correr sqlcmd son error de sintaxis y tumbarían el script en el cliente.
        c = "\n".join(obj.cab("VISTAS", "MIPROYECTO", "SQLSERVER"))
        assert "SET DEFINE OFF" not in c
        assert "SET SQLBLANKLINES ON" not in c

    def test_la_de_oracle_sigue_llevandolas(self):
        c = "\n".join(obj.cab("VISTAS", "MIPROYECTO", "ORACLE"))
        assert "SET DEFINE OFF" in c
        assert "SET SQLBLANKLINES ON" in c
