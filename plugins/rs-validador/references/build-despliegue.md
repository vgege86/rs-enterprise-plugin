# Arranque, build y despliegue — RSValidador

## 1. Arranque en desarrollo

`iniciar.bat [puerto]` o `iniciar.ps1`: instalan dependencias, levantan `uvicorn estructura:app` y
abren la pantalla de administración.

Arranque manual (el que usa la etapa de verificación funcional):

```powershell
$env:RS_DEV = "1"                                   # expone /docs y /redoc
python -m uvicorn estructura:app --port 8010
```

- Log de aplicación: `data/rsvalidador.log` (DEBUG, rotativo 2 MB × 3).
- Recordatorio: los **422** de FastAPI no llegan a ese log (ver `arquitectura.md` §5).
- La home `/` sirve la pantalla de administración; la UI estática cuelga de `/ui`.

## 2. Tests

`scripts/smoke_integration_tests.py` — tests de integración smoke; fija `DATABASE_URL` a un SQLite
temporal, así que **no toca** `data/app.db`. Es la verificación automatizada por defecto tras un
cambio de backend.

## 3. Build del ejecutable Windows

```powershell
& .\scripts\build_windows_exe.ps1 -UpgradePyInstaller:$false -PyInstallerClean:$false -DistRoot 'dist' -BuildRoot 'build'
```

Salida: `dist\RSValidador\RSValidador.exe`.

⛔ Reglas del build:
- **Cerrar `RSValidador.exe` antes de recompilar** — si está abierto, bloquea
  `dist\RSValidador\_internal\...` y el build falla.
- Compilar siempre en `dist\RSValidador` dentro de la carpeta de trabajo; no usar directorios
  alternativos.
- **Fichero estático nuevo** (una página HTML, un CSS, un JS) ⇒ añadir su `--add-data "<fichero>;."`
  en `build_windows_exe.ps1`, o no viajará dentro del exe y la pantalla dará 404 solo en la versión
  empaquetada.
- **Dependencia nueva** ⇒ `requirements.txt` **y** comprobar que PyInstaller la empaqueta (los
  imports dinámicos suelen necesitar `--hidden-import`).
- El build no se lanza salvo petición explícita del usuario.

## 4. ⛔ Resolución de rutas dentro del exe

Bajo PyInstaller, `Path(__file__).parent` apunta a `_internal/` — **incorrecto para datos**.

- Para datos usar siempre `RS_DATA_DIR` (o `DATABASE_URL`), que fija `launcher_portable.py`
  **antes** de importar `estructura.py`.
- En el exe, la BD y `app_config.json` viven en `<carpeta_del_exe>/data`.
- `launcher_portable.py` levanta uvicorn en un hilo y muestra una ventana de control tkinter.
- Helper interno `_get_sqlite_path()` resuelve la ruta correcta en desarrollo y en el exe.

Código nuevo que construya rutas a ficheros de datos debe pasar por ese mecanismo, nunca por
`__file__`.

## 5. Entrega

Cada cambio funcional deja una entrada en `RELEASE_NOTES_<AAAA-MM-DD>.md` en la raíz del proyecto,
con el mismo nivel de detalle que las existentes: qué cambia, por qué, y qué hay que hacer al
instalar (migración SQL, reinicio, recompilación del exe).

El árbol vive en **SVN**. El commit y el `svn add` de ficheros nuevos requieren petición explícita:
⛔ nunca commitear como efecto colateral de un cambio.
