# Arquitectura de RSValidador

Referencia de dominio: cómo está montada la herramienta y qué trampas tiene su estructura.
Cargar cuando el cambio toca módulos, arranque, sesión de BD, endpoints o frontend.

## 1. Stack

Python 3 · **FastAPI** + Uvicorn (ASGI) · **SQLAlchemy 2.0** · **Pydantic v2** · openpyxl (Excel).
Frontend HTML + CSS + **JavaScript vanilla** (sin framework), i18n propio en `i18n.js`.
Empaquetado con **PyInstaller** a un ejecutable Windows portable.

Dependencias en `requirements.txt`: `fastapi`, `uvicorn[standard]`, `openpyxl`, `pydantic>=2`,
`sqlalchemy>=2`, `python-multipart`, `aiofiles`, `oracledb>=2`, `pyodbc>=5`.
⛔ Añadir una dependencia obliga a declararla aquí **y** a revisar el build del exe.

## 2. Flujo

```
Navegador (HTML/JS)  ──fetch() JSON / form-data──►  FastAPI (estructura.py)
                                                        │            │
                                    SQLAlchemy (get_db) │            │ servicios (lógica pura)
                                                        ▼            ▼
                              Almacén propio (SQLite / Oracle / SQL Server)   openpyxl → Excel

Aparte: conectores a la BD **productiva del cliente** (oracledb / pyodbc) para leer metadatos
        de tablas y ejecutar SQL — mecanismo distinto del almacén propio (ver `bd-motores.md`).
```

## 3. Módulos

| Fichero | Responsabilidad |
|---------|-----------------|
| `estructura.py` | Núcleo monolítico (~208 KB): configuración, modelos ORM, arranque y **todos** los endpoints |
| `validator_service.py` | `parse_line()` y `validar_fichero_con_estructura()`: parseo posicional/delimitado y reglas de campo, PK, dominios, catálogos, comparaciones, `unique_combos` |
| `relation_service.py` | `validar_integridad_relacional()`: cruza F1 y F2 por claves en ambos sentidos |
| `batch_service.py` | `asociar_ficheros()` (match por nomenclatura), `validar_masivo()`, `exportar_excel_masivo()` |
| `detect_service.py` | Autodetección de estructura desde una muestra (delimitador, tipos, fechas) |
| `launcher_portable.py` | Arranque del `.exe`: fija `RS_DATA_DIR`, levanta uvicorn en un hilo, ventana tkinter de control |

⛔ **No leer `estructura.py` entero.** Localizar con Grep (`@app.get`, `@app.post`, `__tablename__`,
el nombre de la función) y leer solo el rango necesario.

## 4. Arranque y sesión de BD

Secuencia al importar `estructura.py`:

1. Se resuelve `DATA_DIR` (env `RS_DATA_DIR` o `./data`) y se configura el logger `rsvalidador`
   (consola INFO + `data/rsvalidador.log` DEBUG, rotativo 2 MB × 3).
2. Se definen los modelos (`Base = declarative_base()`); el **engine se crea de forma perezosa** —
   `engine` y `SessionLocal` empiezan a `None`.
3. `init_engine()` resuelve la URL, crea el engine, ejecuta `ensure_project_schema()` y siembra
   datos por defecto. Si el motor de servidor falla, **captura la excepción**, deja `engine = None`
   y guarda el mensaje en `DB_INIT_ERROR` → **modo configuración**: la app arranca igual para poder
   corregir la conexión desde la UI.
4. Se crea `app = FastAPI(...)`. Swagger `/docs` y `/redoc` solo si `RS_DEV=1`.

**Sesión por request:** todos los endpoints usan `db: Session = Depends(get_db)`. Si el almacén no
está disponible (`SessionLocal is None`), `get_db()` responde **HTTP 503**.
`ensure_project_schema()` es de startup y sí usa `SessionLocal()` directamente.

⛔ Un endpoint nuevo **debe** usar `Depends(get_db)`: el generador garantiza el cierre de la sesión
incluso ante excepción.

## 5. Trampas del backend

- **Logging**: usar siempre `logger.*`, nunca `print()`. Los **422** de FastAPI (validación de query
  params) los resuelve el middleware antes de llegar al código → **no aparecen** en
  `data/rsvalidador.log`. Si un fetch falla "sin dejar rastro", sospechar de un 422.
- **`Optional[int]` en query params**: enviar `&grupo_id=` (cadena vacía) provoca 422. Omitir el
  parámetro cuando no se necesita.
- **Convención de nombres**: `pid` = `proyecto_id` en las rutas `/proyecto/{pid}/...`.
- La UI estática se sirve en `/ui` (StaticFiles); la home `/` devuelve `estructura_admin.html`.

## 6. Frontend

Una página HTML por pantalla; la navegación arrastra el contexto (proyecto / mandante / grupo) **por
la URL**. Un enlace nuevo debe propagar ese contexto o la página hija se abre en el contexto
equivocado.

- **`shared.css`**: toda página carga `<link rel="stylesheet" href="shared.css">` **antes** de su
  `<style>` inline. El inline solo lleva reglas específicas de esa pantalla. ⛔ CSS que deba aplicar
  a todas las pantallas va en `shared.css`, no duplicado en una.
- Los overrides de **dark mode** en `shared.css` usan `!important` en `background`/`color`/`border`
  de inputs y selects, para ganar a estilos inline residuales.
- ⛔ **`apiFetch` no es la misma función en todas las páginas**: en `scripts_sql.html` devuelve el
  `Response` crudo (hay que usar `.ok` + `.json()` a mano); en el patrón de la pestaña de algoritmos
  sí parsea el JSON y lanza excepción en error. Comprobar cuál rige en el fichero que se toca.
- Patrón de guardado en `estructura.html`: `saveStructure()` → `getSchemaFromEditor()` parsea el
  textarea `#output` (preview JSON); si está vacío o inválido cae a `getCurrentSchema()` (lee el
  formulario). ⛔ Todo input que afecte al schema necesita listener `updatePreview()` o se guardará
  un valor obsoleto.
- Al añadir una página HTML nueva: incluir el link a `shared.css` **y** añadirla al empaquetado
  (ver `build-despliegue.md`).
