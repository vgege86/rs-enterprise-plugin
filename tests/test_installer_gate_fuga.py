"""
Gate de fuga de metadatos de desarrollo en el paquete del cliente
(`scripts/installer-gate-fuga.py`).

⛔ POR QUÉ ES UN GATE Y NO UNA CONVENCIÓN

Hasta la 3.25.0 el generador de DDL inlineaba las `description` del model.json como comentarios
del `.sql` que se copia al servidor del cliente:

    -- Cabecera de expedientes
    CREATE TABLE RTABLA (
        ESTADO CHAR(1 CHAR),  -- Estado inicial, ver documento funcional

Nadie lo había decidido: era un efecto de que la fuente del DDL fuera el mismo fichero donde se
documenta para desarrollo. Al pasar la fuente a la BD el problema desaparece por construcción,
pero "desaparece por construcción" es exactamente el tipo de afirmación que hay que comprobar
en vez de suponer — y el modelo sigue existiendo, con sus descripciones y sus marcas PII, a un
import de distancia.

El gate no confía en el generador: mira el artefacto que se entrega.

Higiene: todo el fixture es sintético — ningún nombre real de cliente.
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

_spec = importlib.util.spec_from_file_location("installer_gate_fuga",
                                               _SCRIPTS / "installer-gate-fuga.py")
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)


def _paquete(tmp_path, ficheros):
    d = tmp_path / "Scripts"
    d.mkdir(parents=True, exist_ok=True)
    for nombre, texto in ficheros.items():
        f = d / nombre
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(texto, encoding="utf-8")
    return d


DDL_LIMPIO = """-- ============================================================
-- Creación de tablas — instalación limpia de MIPROYECTO
-- Motor: ORACLE | Generado: 2026-08-13 10:00
-- Extraído de la BD VIVA (diccionario ALL_*), SIN schema.
-- ============================================================
SET DEFINE OFF

CREATE TABLE RTABLA (
    ID NUMBER(10) NOT NULL,
    ESTADO CHAR(1 CHAR) DEFAULT 'A',
    CONSTRAINT PK_RTABLA PRIMARY KEY (ID)
);
"""


class TestPaqueteLimpio:
    def test_un_DDL_sin_metadatos_pasa(self, tmp_path):
        d = _paquete(tmp_path, {"MIPROYECTO-CreacionTablas.sql": DDL_LIMPIO})
        assert gate.revisar(d, []) == []

    def test_los_codigos_del_motor_no_se_confunden_con_tickets(self, tmp_path):
        # ⛔ ORA-00955 se parece a PROJ-1234. Un gate que cría avisos falsos deja de leerse, y
        # entonces no sirve para nada.
        d = _paquete(tmp_path, {"a.sql": "-- si da ORA-00955 el esquema no está vacío\n"
                                         "-- encoding AL32UTF8, salida UTF-8\n"
                                         "-- SP2-0751 al conectar\n"})
        assert gate.revisar(d, []) == []


class TestFugaDeDescripciones:
    def test_caza_el_campo_description_del_modelo(self, tmp_path):
        d = _paquete(tmp_path, {"x.json": '{"tables": {"RTABLA": {"description": "algo"}}}'})
        h = gate.revisar(d, [])
        assert any("description" in m for _, _, m, _ in h)

    def test_caza_una_descripcion_INLINEADA_como_comentario_SQL(self, tmp_path):
        # La forma en que se filtraba de verdad: ya no lleva ninguna marca que la delate, así
        # que hay que buscar el texto literal del modelo.
        desc = "Cabecera de expedientes de reclamacion"
        d = _paquete(tmp_path, {"t.sql": f"-- {desc}\nCREATE TABLE RTABLA (ID NUMBER(10));\n"})
        h = gate.revisar(d, [desc])
        assert len(h) == 1
        assert "descripción del modelo" in h[0][2]

    def test_una_descripcion_corta_no_dispara(self, tmp_path):
        # "Estado" coincidiría con media docena de comentarios legítimos del propio DDL.
        d = _paquete(tmp_path, {"t.sql": "-- Estado\nCREATE TABLE X (A NUMBER(1));\n"})
        assert gate.revisar(d, ["Estado"]) == []


class TestFugaDeMarcasPii:
    @pytest.mark.parametrize("linea", [
        '  "pii": true,',
        '  "safe": false,',
        '  "clasificacion": "personal",',
        'pii = "alto"',
    ])
    def test_caza_las_marcas_de_politica(self, tmp_path, linea):
        d = _paquete(tmp_path, {"x.json": linea})
        h = gate.revisar(d, [])
        assert any("PII" in m for _, _, m, _ in h), h

    def test_una_columna_que_se_llame_SAFE_no_dispara(self, tmp_path):
        # La marca es del esquema del modelo, no la palabra suelta.
        d = _paquete(tmp_path, {"t.sql": "CREATE TABLE X (SAFE NUMBER(1), PII NUMBER(1));"})
        assert gate.revisar(d, []) == []


class TestFugaDeReferenciasInternas:
    def test_caza_un_identificador_de_ticket(self, tmp_path):
        # Se reporta una vez por línea y motivo: repetir el mismo hallazgo por cada aparición
        # llenaría el informe sin añadir nada. Lo que importa es que la línea salga señalada.
        d = _paquete(tmp_path, {"readme.txt": "Corrige PROJ-1234\ny tambien el mantis #987\n"})
        h = gate.revisar(d, [])
        motivos = [m for _, _, m, _ in h]
        assert motivos.count("referencia a ticket interno") == 2
        assert {l for _, l, _, _ in h} == {1, 2}

    def test_caza_una_ruta_del_workspace_de_desarrollo(self, tmp_path):
        d = _paquete(tmp_path, {"a.sql": "-- generado desde N:\\SVN\\MIPROY\\trunk"})
        assert any("workspace" in m for _, _, m, _ in gate.revisar(d, []))

    def test_caza_la_referencia_al_fichero_de_conexiones(self, tmp_path):
        d = _paquete(tmp_path, {"a.ps1": "# ver docs\\.rs-databases.json"})
        assert any("conexiones" in m for _, _, m, _ in gate.revisar(d, []))


class TestAlcance:
    def test_recorre_las_subcarpetas(self, tmp_path):
        d = _paquete(tmp_path, {"Inserts/RTABLA.sql": '{"pii": true}'})
        assert gate.revisar(d, []) != []

    def test_ignora_los_binarios(self, tmp_path):
        d = tmp_path / "Scripts"
        d.mkdir()
        (d / "algo.zip").write_bytes(b'\x00\x01"pii":')
        assert gate.revisar(d, []) == []


class TestDescripcionesDelModelo:
    def test_extrae_las_de_tabla_y_columna(self, tmp_path):
        m = tmp_path / "m.json"
        m.write_text(json.dumps({"tables": {"RTABLA": {
            "description": "Cabecera de expedientes de reclamacion",
            "columns": {"ESTADO": {"description": "Estado inicial del expediente"}}}}}),
            encoding="utf-8")
        d = gate.descripciones_del_modelo(m)
        assert "Cabecera de expedientes de reclamacion" in d
        assert "Estado inicial del expediente" in d

    def test_sin_modelo_devuelve_lista_vacia(self, tmp_path):
        assert gate.descripciones_del_modelo(tmp_path / "no-existe.json") == []


class TestSalida:
    def test_un_paquete_limpio_sale_por_cero(self, tmp_path, monkeypatch, capsys):
        d = _paquete(tmp_path, {"t.sql": DDL_LIMPIO})
        monkeypatch.setattr(sys, "argv", ["gate", str(d)])
        with pytest.raises(SystemExit) as e:
            gate.main()
        assert e.value.code == 0
        assert "sin fugas" in capsys.readouterr().out

    def test_una_fuga_FALLA_y_dice_donde(self, tmp_path, monkeypatch, capsys):
        # ⛔ Falla cerrado: el paquete NO es entregable. Y no "limpia" el fichero — borrar la
        # línea dejaría intacto el generador que la produjo, y volvería en la siguiente vuelta.
        d = _paquete(tmp_path, {"t.sql": '-- {"pii": true}\nCREATE TABLE X (A NUMBER(1));'})
        monkeypatch.setattr(sys, "argv", ["gate", str(d)])
        with pytest.raises(SystemExit) as e:
            gate.main()
        assert e.value.code == 1
        salida = capsys.readouterr().out
        assert "t.sql:1" in salida
        assert "NO es entregable" in salida
        assert "Corrige el GENERADOR" in salida
