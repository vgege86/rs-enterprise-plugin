"""
El escritor canónico del `model.json` (`scripts/_modeljson.py`).

⛔ Por qué existe este fichero. Todos los fallos que este módulo viene a cerrar son
**silenciosos**: el JSON sigue siendo válido, el contenido sigue siendo el mismo, y lo único que
se rompe es el diff del control de versiones — que es donde se revisa el modelo. Nadie se entera
hasta que el diff ya está subido.

Tres propiedades que hay que sostener, y ninguna se ve leyendo el fichero resultante:

  1. **El formato es exacto.** BOM, CRLF, `ensure_ascii` y dos espacios de indentación. Si una
     sola de las cuatro se cae, el siguiente escritor produce un fichero distinto byte a byte y
     el diff sale entero.
  2. **Es idempotente entre lenguajes.** Un modelo escrito por Python, leído y reescrito por
     PowerShell, tiene que salir idéntico. Es la propiedad que de verdad importa: el modelo lo
     tocan hooks de los dos lados.
  3. **La verificación rechaza de verdad.** Si `guardar` aceptara un fichero mal escrito, la
     verificación sería decorativa — y el modelo bueno se habría perdido ya.
"""
import json
import sys
from pathlib import Path

import pytest

_RAIZ = Path(__file__).resolve().parent.parent
_SCRIPTS = _RAIZ / "scripts"
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

import _modeljson

BOM = b"\xef\xbb\xbf"

MODELO = {
    "version": "1.0",
    "project": "Demo",
    "schema": "ESQ",
    "tables": {
        "RCLIENTES": {
            "description": "Sinónimos, códigos y ñ á é í ó ú",
            "columns": {
                "ID":     {"type": "NUMBER(10)",   "nullable": False, "pk": 1},
                "NOMBRE": {"type": "VARCHAR2(50)", "nullable": True,  "pk": False, "pii": True},
            },
            "relations": [],
            "indexes": [],
        }
    },
}


class TestFormatoCanonico:
    def test_lleva_bom(self, tmp_path):
        p = tmp_path / "m.json"
        _modeljson.guardar(MODELO, p)
        assert p.read_bytes().startswith(BOM)

    def test_todos_los_saltos_son_crlf(self, tmp_path):
        # Un LF suelto convierte el fichero en "todo modificado" para un cliente configurado
        # en CRLF, que es el caso de este repositorio.
        p = tmp_path / "m.json"
        _modeljson.guardar(MODELO, p)
        cuerpo = p.read_bytes()[len(BOM):]
        sueltos = [i for i, b in enumerate(cuerpo) if b == 0x0A and (i == 0 or cuerpo[i - 1] != 0x0D)]
        assert sueltos == []
        assert cuerpo.count(b"\r\n") > 0

    def test_no_queda_ni_un_byte_no_ascii(self, tmp_path):
        # `ensure_ascii=True` no es cosmético: garantiza que ninguna herramienta pueda
        # reinterpretar la codificación del fichero y provocar un diff completo.
        p = tmp_path / "m.json"
        _modeljson.guardar(MODELO, p)
        assert all(b <= 0x7F for b in p.read_bytes()[len(BOM):])
        assert "\\u00f1" in p.read_bytes()[len(BOM):].decode("ascii")

    def test_indenta_a_dos_espacios_sin_espacios_finales(self, tmp_path):
        p = tmp_path / "m.json"
        _modeljson.guardar(MODELO, p)
        lineas = p.read_bytes()[len(BOM):].decode("ascii").split("\r\n")
        assert '  "version": "1.0",' in lineas
        assert not [l for l in lineas if l != l.rstrip()], "hay líneas con espacios al final"

    def test_el_contenido_sobrevive_intacto(self, tmp_path):
        p = tmp_path / "m.json"
        _modeljson.guardar(MODELO, p)
        assert _modeljson.cargar(p) == MODELO


class TestIdempotencia:
    def test_reescribir_no_cambia_ni_un_byte(self, tmp_path):
        # Sin esto, cada sincronización produciría un diff aunque no hubiera cambiado nada.
        p = tmp_path / "m.json"
        _modeljson.guardar(MODELO, p)
        antes = p.read_bytes()
        _modeljson.guardar(_modeljson.cargar(p), p)
        assert p.read_bytes() == antes

    def test_el_orden_de_las_claves_se_respeta(self, tmp_path):
        # No se ordena alfabéticamente: reordenar las claves de un modelo existente sería un
        # diff completo de una sola vez, y además cada motor las trae en su propio orden.
        p = tmp_path / "m.json"
        _modeljson.guardar({"z": 1, "a": 2, "m": 3}, p)
        texto = p.read_bytes()[len(BOM):].decode("ascii")
        assert texto.index('"z"') < texto.index('"a"') < texto.index('"m"')


class TestVerificacion:
    def test_acepta_un_fichero_canonico(self, tmp_path):
        p = tmp_path / "m.json"
        _modeljson.guardar(MODELO, p)
        assert _modeljson.verificar(p)["ok"] is True

    def test_rechaza_sin_bom_y_con_acentos_crudos(self, tmp_path):
        # Exactamente lo que producía `json.dump(..., ensure_ascii=False)` sin BOM.
        p = tmp_path / "malo.json"
        p.write_bytes(json.dumps({"a": "ñáé"}, indent=2, ensure_ascii=False).encode("utf-8"))
        res = _modeljson.verificar(p)
        assert res["ok"] is False
        assert res["bom"] is False
        assert res["no_ascii"] > 0

    def test_rechaza_lf_sueltos(self, tmp_path):
        p = tmp_path / "lf.json"
        p.write_bytes(BOM + b'{\n  "a": 1\n}')
        res = _modeljson.verificar(p)
        assert res["ok"] is False
        assert res["lf_sueltos"] == 2

    def test_rechaza_lo_que_no_vuelve_a_parsearse(self, tmp_path):
        p = tmp_path / "roto.json"
        p.write_bytes(BOM + b'{"a": ')
        res = _modeljson.verificar(p)
        assert res["ok"] is False
        assert res["reparse"] is False

    def test_detecta_que_el_contenido_no_es_el_esperado(self, tmp_path):
        # La única comprobación que habla de pérdida de datos y no de formato.
        p = tmp_path / "m.json"
        _modeljson.guardar(MODELO, p)
        res = _modeljson.verificar(p, esperado={"otra": "cosa"})
        assert res["ok"] is False
        assert res["coincide"] is False

    def test_un_fichero_que_no_existe_no_lanza(self, tmp_path):
        res = _modeljson.verificar(tmp_path / "no-esta.json")
        assert res["ok"] is False
        assert res["error"]


class TestEscrituraAtomica:
    def test_no_deja_temporal_tras_escribir(self, tmp_path):
        p = tmp_path / "m.json"
        _modeljson.guardar(MODELO, p)
        assert not (tmp_path / "m.json.tmp").exists()

    def test_si_el_modelo_no_es_serializable_el_anterior_queda_intacto(self, tmp_path):
        # ⛔ Entregar un modelo corrupto es peor que no actualizarlo: a partir de ahí todo lo que
        # lo consume —DDL del instalador, ERD, política PII— trabaja sobre datos rotos sin saberlo.
        p = tmp_path / "m.json"
        _modeljson.guardar(MODELO, p)
        antes = p.read_bytes()
        with pytest.raises(Exception):
            _modeljson.guardar({"malo": object()}, p)
        assert p.read_bytes() == antes
        assert not (tmp_path / "m.json.tmp").exists()


class TestCli:
    """El camino que usa `hooks/lib-modeljson.ps1`."""

    def test_escribir_convierte_un_json_cualquiera_a_canonico(self, tmp_path):
        origen = tmp_path / "compacto.json"
        origen.write_text(json.dumps(MODELO, separators=(",", ":"), ensure_ascii=False),
                          encoding="utf-8")
        destino = tmp_path / "m.json"
        assert _modeljson._main(["_modeljson.py", "escribir", str(destino), str(origen)]) == 0
        assert _modeljson.verificar(destino)["ok"] is True
        assert _modeljson.cargar(destino) == MODELO

    def test_verificar_devuelve_1_si_no_es_canonico(self, tmp_path):
        p = tmp_path / "malo.json"
        p.write_bytes(b'{"a": 1}')
        assert _modeljson._main(["_modeljson.py", "verificar", str(p)]) == 1

    def test_una_accion_desconocida_no_revienta(self, tmp_path):
        assert _modeljson._main(["_modeljson.py", "borrar", str(tmp_path / "x")]) == 1
