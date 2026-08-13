"""
El DDL de tablas que se entrega al cliente, ahora extraído de la BD VIVA
(`scripts/installer-tablas.py`).

⛔ POR QUÉ EXISTE ESTE FICHERO

Cada bloque fija una pérdida MEDIDA en una entrega real, no una hipótesis. Todas tenían la
misma raíz —la traducción BD -> model.json es lossy y el modelo se queda desfasado— y ninguna
daba error al generar:

  1. `RAW` sin longitud: el CREATE TABLE del cliente daba ORA-00906. 15 columnas en 7 tablas.
     El DDL entregado no compilaba.
  2. Tamaños desfasados: una columna que en la BD es (51) y en el modelo (10). Se habrían
     creado columnas cortas en el cliente -> ORA-12899 con los datos reales.
  3. Pérdidas por traducción: 12 FK -> 0, 3 CHECK -> 0, 1 IDENTITY -> columna NUMBER pelada,
     22 DEFAULT -> 21.
  4. Índices duplicados por la lista aditiva del modelo (source:manual + source:db).
  5. Descripciones del modelo inlineadas como comentarios del .sql que viaja al cliente.

La forma de que no vuelvan no es "sincronizar mejor el modelo": es que el modelo deje de ser la
fuente. Lo que se comprueba aquí es que la fuente sea la BD y que ningún camino escriba un
fichero que no se pueda instalar.

Portabilidad: no toca BD. La extracción se sustituye por un doble, así que lo que se ejercita
es la lógica de tipos, agrupación, exclusiones, gates y emisión.
Higiene: todo el fixture es sintético (RTABLA, MIPROYECTO) — ningún nombre real de cliente.
"""
import importlib.util
import json
import sys
from pathlib import Path

import pytest

_RAIZ = Path(__file__).resolve().parent.parent
_SCRIPTS = _RAIZ / "scripts"
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))


def _cargar(nombre):
    spec = importlib.util.spec_from_file_location(nombre.replace("-", "_"), _SCRIPTS / f"{nombre}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


tab = _cargar("installer-tablas")
import _dbsql


# =========================================================== tipos y tamaños
class TestDimension:
    """⛔ No fabricar paréntesis vacíos.

    Con el tamaño ausente, un f"{t}({n})" produce `RAW()`: inválido para el motor y —lo grave—
    INVISIBLE para `falta_tamano`, que da por bueno todo tipo que lleve paréntesis. El gate se
    saltaba justo el caso que existe para cazar y el .sql se escribía con un OK encima. Lo
    encontró este test, no una entrega.
    """

    def test_un_tamano_real_pasa(self):
        assert tab.dimension("51") == "51"

    def test_lo_que_no_es_tamano_no_pasa(self):
        for v in ("", None, "  ", "0", "-1", "N/A", "1.5"):
            assert tab.dimension(v) == "", repr(v)

    def test_sin_tamano_el_tipo_sale_PELADO_para_que_el_gate_lo_pare(self):
        from _dbtypes import falta_tamano
        crudo = tab.tipo_oracle(dict(tipo="RAW", data_length="", char_length="", precision="",
                                     scale="", char_used=""))
        assert crudo == "RAW"
        assert falta_tamano(crudo, "ORACLE") == "invalido"

    def test_CHAR_sin_longitud_lo_detecta_como_silencioso(self):
        from _dbtypes import falta_tamano
        crudo = tab.tipo_oracle(dict(tipo="CHAR", data_length="", char_length="", precision="",
                                     scale="", char_used="C"))
        assert crudo == "CHAR"
        assert falta_tamano(crudo, "ORACLE") == "silencioso"


class TestTipoOracle:
    """El tamaño no es decorativo: sin él, o el DDL no compila o trunca datos en silencio."""

    def _col(self, **kw):
        base = dict(tipo="", data_length="", char_length="", precision="", scale="", char_used="")
        base.update(kw)
        return base

    def test_RAW_lleva_su_longitud_en_BYTES(self):
        # ⛔ La regresión que costó una entrega: RAW sin longitud da ORA-00906 y el .sql se para
        # a mitad del CREATE TABLE, dejando el esquema del cliente a medias.
        # Va por DATA_LENGTH y no por CHAR_LENGTH: CHAR_LENGTH vale 0 para RAW, y habría
        # generado RAW(0), igual de inválido.
        assert tab.tipo_oracle(self._col(tipo="RAW", data_length="16", char_length="0")) == "RAW(16)"

    def test_VARCHAR2_declarado_en_caracteres_conserva_la_semantica_CHAR(self):
        c = self._col(tipo="VARCHAR2", char_length="51", data_length="204", char_used="C")
        assert tab.tipo_oracle(c) == "VARCHAR2(51 CHAR)"

    def test_VARCHAR2_declarado_en_bytes_conserva_la_semantica_BYTE(self):
        # Reinterpretar bytes como caracteres cambia la capacidad real de la columna.
        c = self._col(tipo="VARCHAR2", char_length="51", data_length="51", char_used="B")
        assert tab.tipo_oracle(c) == "VARCHAR2(51 BYTE)"

    def test_el_tamano_sale_del_diccionario_no_de_ningun_modelo(self):
        # La columna que en el modelo estaba como (10) y en la BD es (51). Aquí no hay modelo
        # que consultar: lo que llega del diccionario es lo que se emite.
        c = self._col(tipo="VARCHAR2", char_length="51", data_length="51", char_used="C")
        assert "(51 CHAR)" in tab.tipo_oracle(c)
        assert "(10" not in tab.tipo_oracle(c)

    def test_CHAR_y_NCHAR_llevan_longitud(self):
        # Sin longitud son VÁLIDOS y significan (1): truncan datos sin un solo error.
        assert tab.tipo_oracle(self._col(tipo="CHAR", char_length="1", char_used="C")) == "CHAR(1 CHAR)"
        assert tab.tipo_oracle(self._col(tipo="NCHAR", char_length="3", char_used="C")) == "NCHAR(3 CHAR)"

    def test_NUMBER_con_escala_y_sin_ella(self):
        assert tab.tipo_oracle(self._col(tipo="NUMBER", precision="12", scale="2")) == "NUMBER(12,2)"
        assert tab.tipo_oracle(self._col(tipo="NUMBER", precision="10", scale="0")) == "NUMBER(10)"

    def test_NUMBER_sin_precision_se_queda_pelado(self):
        # NUMBER sin precisión es un tipo válido y DISTINTO de NUMBER(38): inventarle una
        # precisión cambiaría lo que la columna admite.
        assert tab.tipo_oracle(self._col(tipo="NUMBER")) == "NUMBER"

    def test_TIMESTAMP_no_se_dimensiona_dos_veces(self):
        # El diccionario ya devuelve 'TIMESTAMP(6)'; añadirle paréntesis daría TIMESTAMP(6)(6).
        assert tab.tipo_oracle(self._col(tipo="TIMESTAMP(6)")) == "TIMESTAMP(6)"

    def test_UROWID_va_en_bytes(self):
        assert tab.tipo_oracle(self._col(tipo="UROWID", data_length="10")) == "UROWID(10)"


class TestTipoSqlServer:
    def _col(self, **kw):
        base = dict(tipo="", data_length="", char_length="", precision="", scale="", char_used="")
        base.update(kw)
        return base

    def test_nvarchar_convierte_bytes_a_caracteres(self):
        # max_length viene en BYTES y en Unicode son 2 por carácter: emitir 100 donde la
        # columna admite 50 duplicaría la capacidad declarada.
        assert tab.tipo_sqlserver(self._col(tipo="nvarchar", data_length="100")) == "nvarchar(50)"

    def test_max_length_menos_uno_es_MAX(self):
        assert tab.tipo_sqlserver(self._col(tipo="varchar", data_length="-1")) == "varchar(MAX)"
        assert tab.tipo_sqlserver(self._col(tipo="varbinary", data_length="-1")) == "varbinary(MAX)"

    def test_varbinary_lleva_su_tamano(self):
        assert tab.tipo_sqlserver(self._col(tipo="varbinary", data_length="16")) == "varbinary(16)"

    def test_decimal_lleva_precision_y_escala(self):
        assert tab.tipo_sqlserver(self._col(tipo="decimal", precision="12", scale="2")) == "decimal(12,2)"


# =========================================================== exclusiones declaradas
class TestLeerExclusiones:
    def _ws(self, tmp_path, cfg):
        ws = tmp_path / "trunk"
        (ws / "docs").mkdir(parents=True)
        (ws / "docs" / "MIPROYECTO-instalador.json").write_text(json.dumps(cfg), encoding="utf-8")
        return ws

    def test_sin_fichero_no_hay_exclusiones(self, tmp_path):
        e = tab.leer_exclusiones(str(tmp_path), "MIPROYECTO")
        assert e["tablas"] == {} and e["tipos_objeto"] == set()

    def test_lee_nombre_y_motivo(self, tmp_path):
        ws = self._ws(tmp_path, {"exclusiones": {"tablas": [
            {"nombre": "RTABLA_20260731", "motivo": "copia CTAS de desarrollo"}]}})
        e = tab.leer_exclusiones(str(ws), "MIPROYECTO")
        assert e["tablas"]["RTABLA_20260731"] == "copia CTAS de desarrollo"

    def test_indexa_en_mayusculas(self, tmp_path):
        ws = self._ws(tmp_path, {"exclusiones": {"tablas": [{"nombre": "rtabla_a"}]}})
        assert "RTABLA_A" in tab.leer_exclusiones(str(ws), "MIPROYECTO")["tablas"]

    def test_una_exclusion_sin_motivo_se_admite_pero_se_marca(self, tmp_path):
        # Dentro de seis meses nadie sabrá por qué esa tabla no viaja.
        ws = self._ws(tmp_path, {"exclusiones": {"tablas": ["RTABLA_Z"]}})
        assert tab.leer_exclusiones(str(ws), "MIPROYECTO")["tablas"]["RTABLA_Z"] == "sin motivo declarado"

    def test_tipos_objeto_se_normaliza(self, tmp_path):
        ws = self._ws(tmp_path, {"exclusiones": {"tipos_objeto": ["foreign key"]}})
        assert "FOREIGN KEY" in tab.leer_exclusiones(str(ws), "MIPROYECTO")["tipos_objeto"]

    def test_un_json_roto_ABORTA_en_vez_de_ignorarse(self, tmp_path):
        # ⛔ Ignorarlo entregaría con las exclusiones SIN APLICAR, es decir con la tabla que
        # alguien decidió que no viajara.
        ws = tmp_path / "trunk"
        (ws / "docs").mkdir(parents=True)
        (ws / "docs" / "MIPROYECTO-instalador.json").write_text("{roto", encoding="utf-8")
        with pytest.raises(RuntimeError, match="no es JSON válido"):
            tab.leer_exclusiones(str(ws), "MIPROYECTO")


class TestPatronSospechoso:
    def test_marca_las_copias_con_fecha_o_sufijo(self):
        for n in ("RTABLA_20260731", "RTABLA_BAK", "RTABLA_COPIA", "RTABLA_OLD2", "RTABLA_TMP"):
            assert tab.PATRON_SOSPECHOSO.search(n), n

    def test_no_marca_una_tabla_normal(self):
        for n in ("RTABLA", "RMOVIM2", "RTABLA_DEL", "RCONTROLES"):
            assert not tab.PATRON_SOSPECHOSO.search(n), n


# =========================================================== agrupación
def _datos(**over):
    """Diccionario plano tal y como lo devolvería la extracción."""
    d = {
        "columnas": [
            dict(tabla="RTABLA", columna="ID", orden=1, tipo="NUMBER", data_length="22",
                 char_length="", precision="10", scale="0", nullable="N", char_used=""),
            dict(tabla="RTABLA", columna="COD", orden=2, tipo="VARCHAR2", data_length="4",
                 char_length="4", precision="", scale="", nullable="N", char_used="C"),
            dict(tabla="RTABLA", columna="ESTADO", orden=3, tipo="CHAR", data_length="1",
                 char_length="1", precision="", scale="", nullable="Y", char_used="C"),
            dict(tabla="RHIJA", columna="ID", orden=1, tipo="NUMBER", data_length="22",
                 char_length="", precision="10", scale="0", nullable="N", char_used=""),
            dict(tabla="RHIJA", columna="PADRE", orden=2, tipo="NUMBER", data_length="22",
                 char_length="", precision="10", scale="0", nullable="N", char_used=""),
        ],
        "defaults": {("RTABLA", "ESTADO"): "'A'"},
        "identidad": {("RTABLA", "ID"): "BY DEFAULT"},
        "aviso_identidad": "",
        "constraints": [
            dict(tipo="P", tabla="RTABLA", nombre="PK_RTABLA", columna="ID", posicion=1,
                 tabla_ref="", columna_ref="", delete_rule=""),
            dict(tipo="U", tabla="RTABLA", nombre="UQ_RTABLA_COD", columna="COD", posicion=1,
                 tabla_ref="", columna_ref="", delete_rule=""),
            dict(tipo="P", tabla="RHIJA", nombre="PK_RHIJA", columna="ID", posicion=1,
                 tabla_ref="", columna_ref="", delete_rule=""),
            dict(tipo="R", tabla="RHIJA", nombre="FK_RHIJA_RTABLA", columna="PADRE", posicion=1,
                 tabla_ref="RTABLA", columna_ref="ID", delete_rule="CASCADE"),
        ],
        "checks": [dict(tabla="RTABLA", nombre="CK_ESTADO", condicion="ESTADO IN ('A','B')")],
        "indices": [dict(tabla="RTABLA", nombre="IX_RTABLA_COD", unico=False, columna="COD",
                         posicion=1, descend="ASC")],
        "n_tablas_diccionario": 2,
    }
    d.update(over)
    return d


_EXCL_VACIO = {"tablas": {}, "indices": {}, "constraints": {}, "tipos_objeto": set()}


class TestAgrupar:
    def test_la_PK_sale_en_el_orden_de_la_clave_no_de_la_tabla(self):
        d = _datos(constraints=[
            dict(tipo="P", tabla="RTABLA", nombre="PK_RTABLA", columna="COD", posicion=2,
                 tabla_ref="", columna_ref="", delete_rule=""),
            dict(tipo="P", tabla="RTABLA", nombre="PK_RTABLA", columna="ID", posicion=1,
                 tabla_ref="", columna_ref="", delete_rule=""),
        ])
        t = tab.agrupar(d, "ORACLE")["tablas"]["RTABLA"]
        # POSITION es el orden DENTRO de la clave, que es el del índice que la respalda.
        assert t["pk"] == ["ID", "COD"]

    def test_las_FK_se_agrupan_por_constraint_y_conservan_la_regla_de_borrado(self):
        fks = tab.agrupar(_datos(), "ORACLE")["fks"]
        assert list(fks) == ["FK_RHIJA_RTABLA"]
        f = fks["FK_RHIJA_RTABLA"]
        assert f["tabla"] == "RHIJA" and f["tabla_ref"] == "RTABLA"
        assert f["columnas"] == ["PADRE"] and f["columnas_ref"] == ["ID"]
        assert f["delete_rule"] == "CASCADE"

    def test_el_default_y_la_identidad_se_pegan_a_su_columna(self):
        t = tab.agrupar(_datos(), "ORACLE")["tablas"]["RTABLA"]
        cols = {c["columna"]: c for c in t["columnas"]}
        assert cols["ESTADO"]["default"] == "'A'"
        assert cols["ID"]["identidad"] == "BY DEFAULT"
        assert cols["COD"]["default"] == ""


# =========================================================== emisión
class TestRenderTabla:
    def _sql(self, motor="ORACLE"):
        agr = tab.agrupar(_datos(), motor)
        return "\n".join(tab.render_tabla("RTABLA", agr["tablas"]["RTABLA"], motor))

    def test_el_DEFAULT_va_entre_el_tipo_y_el_NOT_NULL(self):
        # ⛔ "COL TIPO NOT NULL DEFAULT x" es error de sintaxis en los DOS motores.
        sql = self._sql()
        assert "NOT NULL DEFAULT" not in sql
        assert "DEFAULT 'A'" in sql

    def test_emite_la_columna_IDENTITY(self):
        # Se perdía por completo: en el paquete anterior salía como una columna NUMBER pelada,
        # así que en el cliente los INSERT sin ID fallaban.
        assert "GENERATED BY DEFAULT AS IDENTITY" in self._sql()

    def test_en_sqlserver_la_identidad_usa_su_sintaxis(self):
        assert "IDENTITY(1,1)" in self._sql("SQLSERVER")

    def test_la_PK_va_inline_con_su_nombre_real(self):
        # El nombre sale de la BD: inventar PK_<tabla> haría que dos entregas no coincidan.
        assert "CONSTRAINT PK_RTABLA PRIMARY KEY (ID)" in self._sql()

    def test_el_NOT_NULL_se_respeta(self):
        sql = self._sql()
        assert "COD VARCHAR2(4 CHAR) NOT NULL" in sql
        assert "ESTADO CHAR(1 CHAR) DEFAULT 'A'" in sql and "ESTADO CHAR(1 CHAR) DEFAULT 'A' NOT NULL" not in sql

    def test_NO_emite_ninguna_descripcion(self):
        # ⛔ Las descripciones son del model.json, que es documentación de desarrollo. El
        # generador anterior las inlineaba como comentarios del .sql que va al cliente.
        sql = self._sql()
        assert "--" not in sql


class TestRenderExtras:
    def test_emite_unique_check_e_indices(self):
        t = tab.agrupar(_datos(), "ORACLE")["tablas"]["RTABLA"]
        uq, ck, ix = tab.render_extras("RTABLA", t, _EXCL_VACIO)
        assert uq == ["ALTER TABLE RTABLA ADD CONSTRAINT UQ_RTABLA_COD UNIQUE (COD);"]
        assert ck == ["ALTER TABLE RTABLA ADD CONSTRAINT CK_ESTADO CHECK (ESTADO IN ('A','B'));"]
        assert ix == ["CREATE INDEX IX_RTABLA_COD ON RTABLA (COD);"]

    def test_un_CHECK_con_nombre_generado_por_el_sistema_se_emite_sin_nombre(self):
        # SYS_Cnnnnnn no significa nada entre dos bases de datos: el número no coincide.
        d = _datos(checks=[dict(tabla="RTABLA", nombre="SYS_C0012345", condicion="ID > 0")])
        t = tab.agrupar(d, "ORACLE")["tablas"]["RTABLA"]
        _, ck, _ = tab.render_extras("RTABLA", t, _EXCL_VACIO)
        assert ck == ["ALTER TABLE RTABLA ADD CHECK (ID > 0);"]

    def test_un_indice_excluido_no_se_emite(self):
        t = tab.agrupar(_datos(), "ORACLE")["tablas"]["RTABLA"]
        excl = dict(_EXCL_VACIO, indices={"IX_RTABLA_COD": "duplicado"})
        _, _, ix = tab.render_extras("RTABLA", t, excl)
        assert ix == []

    def test_un_indice_solo_se_emite_UNA_vez_por_nombre(self):
        # El modelo traía la lista aditiva (source:manual + source:db) y el mismo índice salía
        # dos veces -> ORA-00955 al instalar. Aquí la clave del diccionario lo impide.
        d = _datos(indices=[
            dict(tabla="RTABLA", nombre="IX_RTABLA_COD", unico=False, columna="COD",
                 posicion=1, descend="ASC"),
            dict(tabla="RTABLA", nombre="IX_RTABLA_COD", unico=False, columna="COD",
                 posicion=1, descend="ASC"),
        ])
        t = tab.agrupar(d, "ORACLE")["tablas"]["RTABLA"]
        _, _, ix = tab.render_extras("RTABLA", t, _EXCL_VACIO)
        assert len(ix) == 1

    def test_un_indice_descendente_conserva_el_DESC(self):
        d = _datos(indices=[dict(tabla="RTABLA", nombre="IX_D", unico=False, columna="COD",
                                 posicion=1, descend="DESC")])
        t = tab.agrupar(d, "ORACLE")["tablas"]["RTABLA"]
        _, _, ix = tab.render_extras("RTABLA", t, _EXCL_VACIO)
        assert ix == ["CREATE INDEX IX_D ON RTABLA (COD DESC);"]


class TestRenderFk:
    def test_emite_la_FK_con_su_regla_de_borrado(self):
        f = tab.agrupar(_datos(), "ORACLE")["fks"]["FK_RHIJA_RTABLA"]
        assert tab.render_fk(f) == ("ALTER TABLE RHIJA ADD CONSTRAINT FK_RHIJA_RTABLA "
                                    "FOREIGN KEY (PADRE) REFERENCES RTABLA (ID) ON DELETE CASCADE;")

    def test_NO_ACTION_no_se_escribe(self):
        # Es el comportamiento por defecto; escribirlo no es válido en Oracle.
        f = dict(tabla="A", nombre="FK", columnas=["X"], tabla_ref="B", columnas_ref=["Y"],
                 delete_rule="NO ACTION")
        assert "ON DELETE" not in tab.render_fk(f)


# =========================================================== main: gates y fichero
def _preparar(monkeypatch, tmp_path, datos, exclusiones=None, motor="ORACLE"):
    ws = tmp_path / "trunk"
    (ws / "docs").mkdir(parents=True)
    if exclusiones is not None:
        (ws / "docs" / "MIPROYECTO-instalador.json").write_text(
            json.dumps({"exclusiones": exclusiones}), encoding="utf-8")
    out = tmp_path / "CreacionTablas.sql"
    monkeypatch.setattr(tab._ins, "read_db_config",
                        lambda w, m, c="": {"motor": motor, "schema": "RSMIPROY",
                                            "user": "RSMIPROY", "password": "x",
                                            "datasource": "d"})
    monkeypatch.setattr(tab, "extraer_oracle", lambda cfg: datos)
    monkeypatch.setattr(tab, "extraer_sqlserver", lambda cfg: datos)
    monkeypatch.setattr(sys, "argv", ["installer-tablas.py", str(ws), "MIPROYECTO", str(out)])
    return out


class TestFicheroGenerado:
    def test_el_fichero_lleva_tablas_unique_check_indices_y_FK(self, monkeypatch, tmp_path):
        out = _preparar(monkeypatch, tmp_path, _datos())
        tab.main()
        sql = out.read_text(encoding="utf-8")
        assert "CREATE TABLE RTABLA (" in sql and "CREATE TABLE RHIJA (" in sql
        assert "ADD CONSTRAINT UQ_RTABLA_COD UNIQUE" in sql
        assert "ADD CONSTRAINT CK_ESTADO CHECK" in sql
        assert "CREATE INDEX IX_RTABLA_COD" in sql
        assert "ADD CONSTRAINT FK_RHIJA_RTABLA FOREIGN KEY" in sql

    def test_las_FK_van_DESPUES_de_todas_las_tablas(self, monkeypatch, tmp_path):
        # Una FK emitida junto a su tabla falla si la referenciada aún no existe, y como el
        # .sql es fail-fast la instalación se para ahí.
        out = _preparar(monkeypatch, tmp_path, _datos())
        tab.main()
        sql = out.read_text(encoding="utf-8")
        assert sql.index("CREATE TABLE RTABLA") < sql.index("FOREIGN KEY")
        assert sql.index("CREATE TABLE RHIJA") < sql.index("FOREIGN KEY")

    def test_la_cabecera_dice_que_la_fuente_es_la_BD(self, monkeypatch, tmp_path):
        out = _preparar(monkeypatch, tmp_path, _datos())
        tab.main()
        sql = out.read_text(encoding="utf-8")
        assert "BD VIVA" in sql
        assert "El modelo JSON no interviene" in sql

    def test_ninguna_descripcion_del_modelo_llega_al_fichero(self, monkeypatch, tmp_path):
        out = _preparar(monkeypatch, tmp_path, _datos())
        tab.main()
        sql = out.read_text(encoding="utf-8")
        # Los únicos comentarios permitidos son los de la cabecera y los separadores de bloque.
        for linea in sql.splitlines():
            if linea.strip().startswith("--"):
                assert not linea.strip().startswith("-- Tabla de"), linea


class TestGateTiposSinTamano:
    def test_RAW_sin_longitud_no_escribe_el_fichero_y_sale_con_error(self, monkeypatch, tmp_path):
        # ⛔ La regresión número uno. Un .sql inválido en la carpeta del instalador es PEOR que
        # no tenerlo: viaja, se ejecuta y se para a mitad del CREATE TABLE.
        d = _datos(columnas=[dict(tabla="RTABLA", columna="CHID", orden=1, tipo="RAW",
                                  data_length="", char_length="", precision="", scale="",
                                  nullable="N", char_used="")])
        out = _preparar(monkeypatch, tmp_path, d)
        with pytest.raises(SystemExit) as e:
            tab.main()
        assert e.value.code == 2
        assert not out.exists()

    def test_lista_TODAS_las_columnas_rotas_de_una_vez(self, monkeypatch, tmp_path, capsys):
        # Parar en la primera obligaría a N pasadas de generación para descubrir N columnas
        # rotas, que es exactamente lo que pasó en el cliente.
        cols = [dict(tabla="RTABLA", columna=f"C{i}", orden=i, tipo="RAW", data_length="",
                     char_length="", precision="", scale="", nullable="N", char_used="")
                for i in range(1, 6)]
        _preparar(monkeypatch, tmp_path, _datos(columnas=cols))
        with pytest.raises(SystemExit):
            tab.main()
        salida = capsys.readouterr().out
        assert "5 columna(s)" in salida
        for i in range(1, 6):
            assert f"RTABLA.C{i}" in salida

    def test_distingue_el_invalido_del_silencioso(self, monkeypatch, tmp_path, capsys):
        cols = [
            dict(tabla="RTABLA", columna="A", orden=1, tipo="RAW", data_length="", char_length="",
                 precision="", scale="", nullable="N", char_used=""),
            dict(tabla="RTABLA", columna="B", orden=2, tipo="CHAR", data_length="", char_length="",
                 precision="", scale="", nullable="N", char_used=""),
        ]
        _preparar(monkeypatch, tmp_path, _datos(columnas=cols))
        with pytest.raises(SystemExit):
            tab.main()
        salida = capsys.readouterr().out
        assert "INVÁLIDA(S)" in salida       # el motor rechaza el DDL
        assert "SILENCIOSA(S)" in salida     # vale, significa (1) y trunca datos sin error


class TestGateLecturaVacia:
    def test_cero_columnas_es_un_error_no_un_esquema_vacio(self, monkeypatch, tmp_path, capsys):
        # ⛔ Un inventario vacío NO significa "no hay tablas": significa que la lectura no ha
        # funcionado o que la cuenta no ve nada. Tratarlo como esquema vacío entregaría un
        # paquete sin una sola tabla y con un OK encima.
        out = _preparar(monkeypatch, tmp_path, _datos(columnas=[]))
        with pytest.raises(SystemExit) as e:
            tab.main()
        assert e.value.code == 1
        assert not out.exists()
        assert "no es un esquema vacío" in capsys.readouterr().out

    def test_un_fallo_de_lectura_no_escribe_nada(self, monkeypatch, tmp_path, capsys):
        out = _preparar(monkeypatch, tmp_path, _datos())

        def _revienta(cfg):
            raise RuntimeError("ORA-00942: table or view does not exist")
        monkeypatch.setattr(tab, "extraer_oracle", _revienta)
        with pytest.raises(SystemExit) as e:
            tab.main()
        assert e.value.code == 1
        assert not out.exists()
        assert "ORA-00942" in capsys.readouterr().out


class TestExclusiones:
    def test_una_tabla_excluida_no_se_emite_y_su_motivo_va_en_la_cabecera(self, monkeypatch, tmp_path):
        d = _datos()
        d["columnas"].append(dict(tabla="RTABLA_20260731", columna="ID", orden=1, tipo="NUMBER",
                                  data_length="22", char_length="", precision="10", scale="0",
                                  nullable="N", char_used=""))
        out = _preparar(monkeypatch, tmp_path, d, exclusiones={
            "tablas": [{"nombre": "RTABLA_20260731", "motivo": "copia CTAS de desarrollo"}]})
        tab.main()
        sql = out.read_text(encoding="utf-8")
        assert "CREATE TABLE RTABLA_20260731" not in sql
        assert "EXCLUIDO A PROPÓSITO" in sql
        assert "copia CTAS de desarrollo" in sql

    def test_la_infraestructura_del_paquete_no_se_emite(self, monkeypatch, tmp_path):
        # La crea 00-RVERSIONES.sql, que va el primero. Emitirla otra vez daba ORA-00955 sobre
        # un esquema recién creado y vacío: el paquete chocando consigo mismo.
        d = _datos()
        d["columnas"].append(dict(tabla="RVERSIONES", columna="ID", orden=1, tipo="NUMBER",
                                  data_length="22", char_length="", precision="10", scale="0",
                                  nullable="N", char_used=""))
        out = _preparar(monkeypatch, tmp_path, d)
        tab.main()
        assert "CREATE TABLE RVERSIONES" not in out.read_text(encoding="utf-8")

    def test_un_nombre_sospechoso_se_AVISA_pero_SI_se_entrega(self, monkeypatch, tmp_path, capsys):
        # ⛔ Excluir por patrón borraría en silencio tablas de producto, y el fallo no aparece
        # hasta que algo las usa. El patrón avisa; quien excluye es la lista declarada.
        d = _datos()
        d["columnas"].append(dict(tabla="RTABLA_BAK", columna="ID", orden=1, tipo="NUMBER",
                                  data_length="22", char_length="", precision="10", scale="0",
                                  nullable="N", char_used=""))
        out = _preparar(monkeypatch, tmp_path, d)
        tab.main()
        assert "CREATE TABLE RTABLA_BAK" in out.read_text(encoding="utf-8")
        assert "nombre de copia puntual que SÍ se entregan" in capsys.readouterr().out

    def test_las_FK_pueden_excluirse_como_TIPO_de_objeto(self, monkeypatch, tmp_path):
        # "las FK no viajan nunca" tiene que ser una DECISIÓN DECLARADA, no un silencio del
        # generador. Sin declararla, todo lo que está en la BD viaja.
        out = _preparar(monkeypatch, tmp_path, _datos(),
                        exclusiones={"tipos_objeto": ["FOREIGN KEY"]})
        tab.main()
        sql = out.read_text(encoding="utf-8")
        assert "FOREIGN KEY" not in sql.replace("EXCLUIDO A PROPÓSITO: FOREIGN KEY", "")
        assert "EXCLUIDO A PROPÓSITO: FOREIGN KEY" in sql


class TestGateFkColgante:
    def test_una_FK_que_apunta_a_una_tabla_excluida_aborta(self, monkeypatch, tmp_path, capsys):
        # En el cliente daría ORA-00942/ORA-02270 y la instalación se pararía ahí. Es preferible
        # pararse aquí, donde está el diagnóstico.
        out = _preparar(monkeypatch, tmp_path, _datos(), exclusiones={
            "tablas": [{"nombre": "RTABLA", "motivo": "prueba"}]})
        with pytest.raises(SystemExit) as e:
            tab.main()
        assert e.value.code == 1
        assert not out.exists()
        salida = capsys.readouterr().out
        assert "FK_RHIJA_RTABLA" in salida and "RHIJA -> RTABLA" in salida


class TestCobertura:
    def test_avisa_del_hueco_entre_el_diccionario_y_lo_capturado(self, monkeypatch, tmp_path, capsys):
        # Oracle no permite distinguir "no existe" de "no lo veo": sin este contraste, una
        # cuenta con GRANT parcial entrega un paquete incompleto sin decir nada.
        _preparar(monkeypatch, tmp_path, _datos(n_tablas_diccionario=9))
        tab.main()
        salida = capsys.readouterr().out
        assert "<< HUECO 7" in salida
        assert "iría INCOMPLETO" in salida


class TestDerivaModelo:
    def test_reporta_la_diferencia_pero_NO_bloquea(self, monkeypatch, tmp_path, capsys):
        # El modelo nunca manda sobre lo que se entrega: solo se dice en voz alta.
        ws = tmp_path / "trunk"
        (ws / "BD").mkdir(parents=True)
        (ws / "BD" / "MIPROYECTO-model.json").write_text(json.dumps({
            "tables": {"RTABLA": {"columns": {"COD": {"type": "VARCHAR2(10 CHAR)"}}}}}),
            encoding="utf-8")
        out = _preparar(monkeypatch, tmp_path, _datos())
        tab.main()
        salida = capsys.readouterr().out
        assert out.exists()                                   # se entrega igual
        assert "DERIVA modelo/BD" in salida
        assert "modelo VARCHAR2(10 CHAR) vs BD VARCHAR2(4 CHAR)" in salida
        assert "la deriva no bloquea" in salida

    def test_sin_modelo_se_genera_igual(self, monkeypatch, tmp_path):
        # El modelo es OPCIONAL: antes su ausencia paraba la generación, porque era la fuente.
        out = _preparar(monkeypatch, tmp_path, _datos())
        tab.main()
        assert out.exists()


# =========================================================== parseo de filas
class TestParseFilas:
    def test_el_ultimo_campo_absorbe_los_separadores_sobrantes(self):
        # Un DEFAULT o un CHECK pueden contener '|': partirlos ahí destrozaría la expresión.
        f = _dbsql.parse_filas("##OBJ##RTABLA|CK|A = 1 | B = 2", 3)
        assert f == [["RTABLA", "CK", "A = 1 | B = 2"]]

    def test_una_fila_incompleta_se_descarta(self):
        # ⛔ Menos campos de los esperados significa que algo se truncó, y colarla produciría
        # una columna sin tipo o un índice sin columnas.
        assert _dbsql.parse_filas("##OBJ##SOLO|DOS", 5) == []

    def test_ignora_todo_lo_que_no_lleve_marcador(self):
        # sqlplus intercala banners, líneas en blanco y avisos.
        out = "SQL*Plus: Release 19\n\n##OBJ##A|B\nSesión terminada."
        assert _dbsql.parse_filas(out, 2) == [["A", "B"]]


class TestAssertSinDiagnostico:
    def test_revienta_ante_un_ORA_al_principio_de_linea(self):
        with pytest.raises(RuntimeError, match="ORA-00942"):
            _dbsql.assert_sin_diagnostico("ORA-00942: table or view does not exist", "ORACLE")

    def test_un_ORA_dentro_de_un_dato_NO_es_un_error(self):
        # Anclarlo importa: un mensaje de error almacenado en una tabla abortaría extracciones
        # perfectamente buenas.
        _dbsql.assert_sin_diagnostico("##OBJ##RLOG|MSG|el proceso devolvio ORA-00001", "ORACLE")

    def test_detecta_el_diagnostico_de_sqlserver(self):
        with pytest.raises(RuntimeError, match="Msg 208"):
            _dbsql.assert_sin_diagnostico("Msg 208, Level 16, State 1", "SQLSERVER")
