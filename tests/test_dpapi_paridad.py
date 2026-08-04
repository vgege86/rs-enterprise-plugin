"""
Paridad DPAPI entre las TRES implementaciones que manejan secretos cifrados del plugin:

    hooks/lib-crypto.ps1            Protect-RsSecret / Unprotect-RsSecret  (la UNICA que cifra)
    mcp/rs-workspace-server.py      _unprotect_secret                      (solo descifra)
    scripts/installer-inserts.py    _unprotect_secret                      (solo descifra)

El cruce real en produccion es asimetrico: /rs-cifrar cifra desde PowerShell y db_query descifra
desde Python. Hasta ahora la paridad era un comentario, no una propiedad probada. Estos tests
cierran ese hueco cifrando de verdad con PowerShell en tiempo de test y descifrando con las dos
implementaciones Python, en vez de usar un blob pegado a mano (que solo probaria contra si mismo,
ademas de no ser descifrable por otra cuenta/maquina).

Portabilidad: DPAPI es Windows-only y ademas atado a la cuenta. Fuera de Windows (o sin pwsh en el
PATH) los tests de cruce se SALTAN limpiamente; los de passthrough en texto plano corren en todo SO.

Higiene: el valor de prueba es inventado y sin ningun valor real, no se lee ninguna credencial del
sistema, y ni el valor en claro ni el blob se imprimen nunca -- viajan por fichero dentro de un
temporal que se borra al salir (nunca por linea de comandos, visible para todo el sistema) y las
aserciones son sobre un booleano ya calculado, para que un fallo no vuelque nada al log.
"""
import importlib.util
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

_RAIZ = Path(__file__).resolve().parent.parent
_SERVER = _RAIZ / "mcp" / "rs-workspace-server.py"
_INSTALADOR = _RAIZ / "scripts" / "installer-inserts.py"
_LIB_CRYPTO = _RAIZ / "hooks" / "lib-crypto.ps1"

# Valor INVENTADO. Acentos y simbolo no ASCII a proposito: el formato esta documentado como
# CryptProtectData sobre los bytes UTF-8, y un desajuste de codificacion entre quien cifra
# (PowerShell) y quien descifra (Python) es exactamente la divergencia que este test existe
# para cazar. No se parece a ninguna password, token ni clave real.
_VALOR_FICTICIO = "valor-de-prueba-sin-valor-real-áéíóú-ñ-€"

_PWSH = shutil.which("pwsh") or shutil.which("powershell")
_SIN_DPAPI = sys.platform != "win32" or _PWSH is None
_MOTIVO_SKIP = "DPAPI solo existe en Windows y hace falta PowerShell para cifrar: nada que cruzar"


def _cargar(nombre, ruta):
    """Carga por ruta un modulo con guion en el nombre (no importable con `import`)."""
    spec = importlib.util.spec_from_file_location(nombre, ruta)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_srv = _cargar("rs_workspace_server_paridad", _SERVER)
_inst = _cargar("installer_inserts_paridad", _INSTALADOR)


def _cifrar_con_powershell(plano):
    """Cifra con Protect-RsSecret (hooks/lib-crypto.ps1) llamando a PowerShell de verdad y
    devuelve el 'enc:<base64>'. El valor entra por fichero y el blob sale por fichero, ambos
    dentro de un temporal que se borra al salir: nada sensible pasa por la linea de comandos
    ni por stdout/stderr."""
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        f_in, f_out, f_ps = d / "in.txt", d / "out.txt", d / "cifra.ps1"
        f_in.write_text(plano, encoding="utf-8")
        f_ps.write_text(
            "$ErrorActionPreference = 'Stop'\n"
            ". '%s'\n"
            "$p = [System.IO.File]::ReadAllText('%s', [System.Text.Encoding]::UTF8)\n"
            "$c = Protect-RsSecret $p\n"
            "[System.IO.File]::WriteAllText('%s', $c)\n" % (_LIB_CRYPTO, f_in, f_out),
            encoding="utf-8")
        res = subprocess.run([_PWSH, "-NoProfile", "-NonInteractive", "-File", str(f_ps)],
                             capture_output=True, text=True, timeout=60)
        if res.returncode != 0 or not f_out.exists():
            # El script no imprime el valor ni el blob, asi que stderr es seguro de mostrar.
            pytest.fail("Protect-RsSecret no cifro (exit %s): %s"
                        % (res.returncode, (res.stderr or "").strip()[:400]))
        return f_out.read_text(encoding="utf-8").strip()


# --- cruce real PowerShell -> Python (Windows) ---

@pytest.mark.skipif(_SIN_DPAPI, reason=_MOTIVO_SKIP)
def test_powershell_cifra_y_el_mcp_lo_descifra():
    # El camino vivo: /rs-cifrar cifra con PowerShell, db_query descifra con el MCP.
    cifrado = _cifrar_con_powershell(_VALOR_FICTICIO)
    tiene_prefijo = cifrado.startswith("enc:")
    assert tiene_prefijo, "Protect-RsSecret no devolvio el formato enc:<base64>"
    coincide = _srv._unprotect_secret(cifrado) == _VALOR_FICTICIO
    assert coincide, "divergencia: el MCP no recupera lo que cifro PowerShell"


@pytest.mark.skipif(_SIN_DPAPI, reason=_MOTIVO_SKIP)
def test_powershell_cifra_y_el_instalador_lo_descifra():
    # Mismo formato leido por el generador de inserts del instalador.
    cifrado = _cifrar_con_powershell(_VALOR_FICTICIO)
    coincide = _inst._unprotect_secret(cifrado) == _VALOR_FICTICIO
    assert coincide, "divergencia: installer-inserts no recupera lo que cifro PowerShell"


@pytest.mark.skipif(_SIN_DPAPI, reason=_MOTIVO_SKIP)
def test_los_dos_descifradores_python_coinciden_sobre_el_mismo_blob():
    # Un unico blob, los dos lectores Python: si alguno derivara (prefijo, base64, encoding),
    # dejarian de coincidir entre si aunque ambos "funcionaran".
    cifrado = _cifrar_con_powershell(_VALOR_FICTICIO)
    coincide = _srv._unprotect_secret(cifrado) == _inst._unprotect_secret(cifrado)
    assert coincide, "divergencia entre los dos _unprotect_secret de Python"


# --- passthrough legacy en installer-inserts (multiplataforma) ---

def test_instalador_passthrough_texto_plano():
    # Un valor SIN prefijo enc: se devuelve tal cual -> retrocompatibilidad con la config antigua.
    assert _inst._unprotect_secret("valor-de-prueba-en-claro") == "valor-de-prueba-en-claro"
    assert _inst._unprotect_secret("") == ""


def test_instalador_enc_invalido_degrada_con_oserror():
    # Fuera de Windows no hay windll; en Windows el blob es invalido y CryptUnprotectData falla.
    # En ambos casos, error controlado y no un descifrado silenciosamente incorrecto.
    with pytest.raises(OSError):
        _inst._unprotect_secret("enc:QUJDRA==")
