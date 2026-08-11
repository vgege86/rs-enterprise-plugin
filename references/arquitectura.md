# Arquitectura uCollect / RS

---

# 🧠 Visión general

El sistema se divide en dos tipos principales de soluciones:

- Batch → procesos secuenciales ejecutables (.exe)
- Online → aplicaciones web y servicios

---

# 🟡 Batch

Ubicación:

Batch\Soluciones\<Solution>

---

## Características

- ejecución secuencial
- procesos críticos
- uso intensivo de BD
- salida en EXE

---

## Flujo típico

1. lectura de entrada
2. validación
3. procesamiento
4. escritura en BD o fichero

---

## Reglas clave

- orden de ejecución es crítico
- errores deben detener el proceso
- validaciones previas obligatorias

---

# 🟣 Online

Ubicación:

OnLine\Soluciones\<Solution>

---

## Características

- aplicaciones web
- interacción con usuario
- llamadas a servicios

---

## Flujo típico

Request → Validación → Lógica → Respuesta

---

## Reglas clave

- validar entradas siempre
- evitar lógica pesada en capa web
- separar servicios

---

## Stack de capas Online (obligatorio)

1. `RSModel` — contenedores de datos puros, solo propiedades, sin lógica
2. `RSDalc` — SQL directo vía `conn.EjecutarQuery(sql, "name")→DataSet` / `conn.EjecutarQuery(sql)→int`; siempre `this.Errores = conn.Errores`; constructor recibe `cConexion`
3. `RSBus` — orquestación fina: instancia RSDalc, propaga errores
4. `RSFac` — ciclo de conexión (`new cConexion(); Conectar(); ... Desconectar()`) y transacciones (`ComienzoTransaccion`/`CommitTransaccion`/`RollbackTransaccion`) para escrituras multi-paso
5. Web — WebForms hereda `FrmBase`, controles AIS (`AISGridView`, `AISCatalogo`, `AISBusinessField`, `AISDialog`, `AISButton`, `AISGroupbox`)

⛔ Nunca saltar RSBus. ⛔ RSFac solo conexión/transacción — sin lógica de negocio.

## Convenciones web Online

- Páginas: `FrmXxx.aspx` → `PAGINA = "FormXxx"` → `RCONTROLES.ICFORM = <App>.FORMXXX`
- `coerr.eXXXX` (`Comun/coerr.cs`) y `coMens.mXXXX` (`Comun/coMens.cs`) mapean 1:1 a `RIDIOMA.IDTEXTO` — añadir la constante antes de usarla
- **Idiomas de alta: catálogo 32 de `RTABL`**, nunca una lista fija.
  `SELECT TBCODE, TBTEXT FROM RTABL WHERE TBNUME = 32 ORDER BY TBCODE` → `TBCODE` es el id de idioma
  (el valor que va en `RIDIOMA.IDIDIOMA`, usado tal cual) y `TBTEXT` su descripción. Varían por
  instalación: ⛔ no dar por hecho `ESP`/`POR`.
- **Rangos de `RIDIOMA.IDTEXTO`** — el rango lo decide el **tipo de texto**, no el id de un texto vecino:

  | Tipo | Origen en código | Rango |
  |---|---|---|
  | Errores | `Idm.Texto(coerr.eXXXX, ...)` | 1000–1999 |
  | Mensajes en pantalla | `Idm.Texto(coMens.mXXXX, ...)` | 2000–2999 |
  | Textos de pantalla | `LabelText`/`Text`/`GroupingText`/`Titulo`, headers de grid, `ErrorMessage` de validadores | ≥ 3000, sin techo |

  Al asignar un IDTEXTO nuevo se **rellenan huecos** empezando por el suelo del rango, no se
  continúa desde el máximo. Rango agotado → primer hueco a partir de 3000, y **declarado** en la
  cabecera del script: fuera de su rango el id ya no identifica el tipo por su número.
  ⛔ Los huecos se buscan siempre contra `RIDIOMA`, nunca en `coerr.cs`/`coMens.cs` (hay IDTEXTO sin
  constante). Reglas operativas completas en `agents/rs-editor-tester.md` (gate del pipeline) y
  `agents/rs-idiomas-standalone.md` (`/rs-idiomas`).
- `AISCatalogo.CatalogData`: primera columna = value, segunda = texto mostrado
- Grid: `DataKeyNames` guarda todos los FK/valores necesarios por fila (sin round-trips extra a BD); filas de detalle en `ViewState` — persistir a BD solo en el Guardar exterior, no por fila

---

## AIS Services Manager (3ª familia de soluciones Online)

Host REST modular (net8.0) que expone servicios externos a las apps AIS. **No es WebForms** — no
usa `.aspx`, controles AIS, RIDIOMA ni RCONTROLES (el gate de idiomas no le aplica). Vive **fuera**
de `OnLine\Soluciones\`:

- Host: `OnLine\AISServiceManager\AISServiceManager\AIS.ServicesManager.sln` — proyectos core
  `AIS.ServicesManager` (arranque + loader), `AIS.ServicesManager.Tipos` (`BaseServicioGestionado`,
  `ICacheServicio`, `ICacheableInput`), `AIS.ServicesManager.Cache`, `AIS.Configuration`, `AIS.ENCRYPT`.
- Framework compartido: `OnLine\AISServiceManager\ArqNet\AIS.ArqNet.sln`.
- Módulos: `OnLine\AISServiceManager\Modulos\<Modulo>\*.sln` (⚠️ el nombre del `.sln` no siempre
  coincide con el proyecto, ej. `AIS.RS.<Proyecto>.API` → `RS<Proyecto>.sln`).

**Mecanismo de plug-in:** en arranque, `ConfiguradorServicios.cs` lee `Settings\Settings.xml` sección
`<MODULOS>` (cada key → `X.dll`), hace `Assembly.LoadFile("Modulos\X.dll")` + `AddApplicationPart`
(resolución de dependencias vía `AssemblyLoadContext.Default.Resolving`). Un módulo = API con
`Controllers/` (heredan `BaseServicioGestionado`, `[Route(...)]`, DI de `ICacheServicio` + `ILogger<T>`;
auth BasicAuth o JWT) + `Dalc/`/`Bus/`/`PublicEntities/`. Deploy: la `.dll` cae en `Modulos\` del host
(PostBuild XCOPY a `C:\AIS\ServicesManagerB2\bin\Modulos`). Log NLog (`Settings\NLog.config.xml`),
caché `IDistributedCache` (SQL Server o memoria). Los módulos concretos **varían por proyecto**.

Doc de referencia: `docs\agentic_manual\AIS-ARQ-DT-Gestor de servicios.md` (⛔ ~335K tokens/base64 —
leer solo por sección).

---

# 📁 AIS (entorno de ejecución)

Ubicación:

C:\ais\<proyecto>\Procesos\Exes\

---

## Propósito

- ejecución de procesos Batch
- entorno de producción

---

## Reglas

- copiar SIEMPRE bin completo
- evitar DLLs antiguas
- mantener coherencia de versiones
