# Cómo funciona el plugin

## Qué es RS Enterprise Agent

RS Enterprise Agent es un plugin de Claude Code para desarrollo C# sobre soluciones **uCollect / RS**.
Aporta dos cosas distintas, y conviene no confundirlas:

- Un **pipeline de desarrollo automatizado** que lleva un cambio de principio a fin —planificación,
  implementación, validación, testing y build— con **aprobación humana obligatoria del plan** antes
  de tocar una sola línea de código.
- **45 modos directos**, invocables como slash commands `/rs-*` o en lenguaje natural, para tareas
  puntuales: auditar, medir el impacto de un cambio, validar código contra la base de datos real,
  consultar esquema, mantener el modelo BD y el ERD, generar tests, hacer commits, documentar,
  revisar seguridad, proteger datos personales en las consultas, generar el instalador de cliente o
  un actualizador de entorno.

Todo lo que hace respeta el **scope de la solución activa**: solo entran los proyectos incluidos en
la `.sln` sobre la que se trabaja. Fuera de ahí no toca nada.

El plugin no sustituye el criterio de nadie. Planifica, propone y ejecuta lo aprobado; los puntos
donde la decisión es humana están marcados como tales y no se pueden saltar.

## Instalación

### El paquete Python del servidor MCP

Antes de instalar el plugin, en una terminal:

```
pip install "mcp>=1.2.0,<2"
```

Nadie lo instala por ti: el plugin no ejecuta ningún `pip`. Sin este paquete el servidor MCP
`rs-workspace` no arranca y las herramientas no responden.

El tope `<2` no es cosmético. La versión 2.0.0 de `mcp` **eliminó** `mcp.server.fastmcp`, que es
justo lo que importa el servidor: un `pip install mcp` a secas arrastra la 2.x y rompe el arranque.

Además tiene que quedar instalado en **el mismo Python que resuelve `python` en el PATH**, porque el
registro del servidor invoca literalmente `python`. Con varias instalaciones de Python o un entorno
virtual de por medio, conviene comprobarlo:

```
python -c "import mcp; print(mcp.__file__)"
```

⚠️ En Windows hay una trampa: **sin Python instalado, `python` no falta del PATH**. Resuelve al
marcador de la Microsoft Store (`...\WindowsApps\python.exe`), que no ejecuta nada y abre la tienda.
Que `where python` responda algo no significa que haya Python.

Si este paso se salta, el plugin **no se queja al usarlo**: los comandos siguen despachando y el
resto de la maquinaria sigue viva, pero ninguna herramienta responde. Por eso, desde la versión
3.24.0, el plugin comprueba Python y el paquete `mcp` **al arrancar cada sesión** y avisa con el
comando exacto de arreglo cuando falta alguno. `/rs-env` repite esa comprobación cuando se quiera y,
si lo que falta es el paquete, ofrece instalarlo — pidiendo confirmación antes de tocar nada.

### El plugin

Se publica como marketplace Git:

```
/plugin marketplace add https://github.com/vgege86/rs-enterprise-plugin.git
/plugin install rs-enterprise-agent@rs-enterprise-agent
```

El repositorio es **privado**: la máquina necesita credencial de GitHub (`gh auth login` o Git
Credential Manager) para que Claude Code pueda clonarlo.

A partir de ahí Claude Code descubre solo los comandos, los agentes, los skills, los hooks y el
servidor MCP. No hay que copiar ficheros a mano ni editar la configuración personal.

Claude Code clona el marketplace en el perfil del usuario y ejecuta el plugin desde esa copia: **el
plugin es portable y no depende de ninguna ruta compartida**.

**Tras instalar hay que reiniciar Claude Code.** Después, `/rs-env` valida la máquina y `/rs-help`
sirve de prueba de que el servidor MCP responde: si el paso del paquete Python falló, se nota ahí.

Para actualizar a una versión nueva:

```
/plugin marketplace update rs-enterprise-agent
```

…y reiniciar otra vez.

### El marketplace publica dos plugins

El mismo marketplace ofrece, además del agente C#, el plugin **`rs-validador`**: desarrollo,
mantenimiento y documentación de la herramienta de validación de ficheros (Python/FastAPI +
HTML/JS), sus estructuras de entrada, la validación de lo que manda el cliente y la generación de
los scripts SQL de configuración de uCollect.

```
/plugin install rs-validador@rs-enterprise-agent
```

Son independientes: se instalan, se versionan y se actualizan por separado. `rs-enterprise-agent`
trabaja sobre soluciones `.sln` de uCollect/RS; `rs-validador` no toca ninguna solución C#.

### Consumo de tokens: no configurar la búsqueda de herramientas

Claude Code **difiere por defecto** los esquemas de las herramientas MCP de `rs-workspace`: solo se
cargan bajo demanda cuando una tarea las necesita, lo que ahorra su coste fijo por sesión sin
configurar nada.

Conviene dejar la variable `ENABLE_TOOL_SEARCH` **sin poner**. El valor `auto` carga los esquemas por
adelantado y `false` los carga todos: ambos deshacen el ahorro. El comportamiento por defecto es el
óptimo.

## Las tres formas de invocarlo

Las tres tienen la misma potencia; cambia la comodidad.

### Pipeline completo

Un mensaje con el patrón *solución + cambio*:

```
RSProcIN.sln - añadir validación de fecha en cabecera
AgendaWeb.sln - modificar lógica de pedidos
```

### Slash commands

Todos los comandos van con el **prefijo del plugin**: el comando real es
`/rs-enterprise-agent:rs-audit`, no `/rs-audit`. Claude Code espacia siempre por nombre lo que aporta
un plugin, para que dos plugins puedan traer un comando homónimo sin pisarse.

En la práctica no hace falta teclear el prefijo entero: se escribe `/rs-audit`, el selector lo
encuentra por coincidencia parcial y lo completa. Lo que **no** funciona es enviar `/rs-audit`
literal sin pasar por el selector.

Por eso el pipeline principal se invoca `/rs-enterprise-agent:rs-enterprise-agent`: el plugin y el
skill del pipeline se llaman igual, así que el nombre sale repetido. No es una errata.

Las tablas del catálogo de este manual omiten el prefijo por legibilidad. Hay que añadirlo
mentalmente a todas.

```
/rs-audit AgendaWeb.sln
/rs-impacto RCLIENTES en RSProcIN.sln
```

### Lenguaje natural

Cualquier mención de una solución RS dispara el plugin:

```
audita AgendaWeb.sln
muéstrame el ERD
qué usa RCLIENTES
faltan índices en RSProcIN
```

Dentro de una sesión, una vez resuelta la solución, **toda petición posterior de cambio de código**
vuelve a entrar por el planner con aprobación de plan, aunque no se repita el nombre de la `.sln`.
Las consultas de solo lectura siguen siendo directas.

## El pipeline de desarrollo

El **planner es el cerebro**: analiza el cambio con acceso al modelo de base de datos y al código,
emite el bloque `PLAN` —que un humano **debe aprobar**— y la lista autoritativa de etapas. El
orquestador **ejecuta esas etapas en orden, sin volver a decidir**; el resto de agentes se limitan a
aplicar el plan.

```
resolver .sln -> scope -> planner -> [APROBACIÓN HUMANA] -> etapas -> checklist -> log
```

### Las etapas

| Etapa | Modelo | Cuándo se ejecuta |
|---|---|---|
| Validación `.sln` + scope | — | Siempre (orquestador) |
| planner | Opus | Siempre — analiza, valida contra BD y decide las etapas |
| Aprobación humana | — | Siempre — gate bloqueante, no toca código sin el visto bueno |
| core | Opus | Siempre — implementa el cambio |
| plan-check | Sonnet | Tras core, solo en cambios complejos (tres o más ítems, dos o más proyectos, esquema de BD o funcionalidad nueva): verifica que el código cubre **todos** los ítems del plan |
| validator | Sonnet | Siempre — compila, análisis estático y revisión lógica |
| fixer | Opus | Si el validator falla (máximo dos ciclos) |
| tester | Sonnet | Si hay lógica testeable, o es Online y toca controles o idiomas |
| crear-tests | Sonnet | Automático si el tester detecta código nuevo sin cobertura |
| Scripts de idiomas | — | Solo Online, cuando hay controles, `Idm.Texto` o rebinds nuevos |
| build | Haiku | Tras modificar código, con verificación de evidencia real |
| db-modeler | Opus | Si el cambio añade o modifica tablas o DALCs |
| documentar | Sonnet | Si el cambio cumple los criterios de documentación |
| Checklist + log | — | Siempre — verificación y registro del historial |

### Dónde está el gate humano

La validación de tipos, longitudes y motor de base de datos la hace el **planner** durante el
análisis, antes de pedir la aprobación. Validator y tester son **bloqueantes**: el build no se
ejecuta si fallan.

El único punto donde el pipeline se detiene a esperar es la aprobación del plan. Todo lo demás corre
seguido, y lo que no cuadre corta la ejecución en lugar de seguir adelante.

## Catálogo de modos directos

45 modos directos. El argumento `<Solution>.sln` casi siempre puede sustituirse por lenguaje natural
equivalente.

El catálogo lista 49 comandos: los 45 modos directos, más el pipeline completo
(`/rs-enterprise-agent`, que no es un modo directo) y los tres comandos de gestión de tareas
—`/rs-tarea`, `/rs-mantis` y `/rs-log-errores`—, que despachan a sus propios skills y no al
principal.

La columna **Modelo** indica qué modelo usa cada modo: **Haiku** para lectura pura y trabajo mecánico
(esquema, diff, estadísticas), **Sonnet** para juicio autocontenido y advisory (auditoría, impacto,
cobertura), y **Opus** cuando escribe código o SQL de producción, o actúa como gate de seguridad o de
cumplimiento.

### Pipeline principal

| Comando | Modelo | Qué hace |
|---|---|---|
| `/rs-enterprise-agent <Solution>.sln - <cambio>` | Opus | Lanza el pipeline completo de desarrollo. Ejemplo: `/rs-enterprise-agent RSProcIN.sln - añadir validación de fecha` |

### Análisis y calidad de código

Solo lectura, no modifican nada. Sirven para entender el riesgo antes de tocar.

| Comando | Modelo | Qué hace |
|---|---|---|
| `/rs-audit <Solution>.sln` | Sonnet | Auditoría estática de calidad (naming, estructura, lógica, seguridad) de **toda** la solución. |
| `/rs-analizar <Solution>.sln [rev\|ficheros]` | Sonnet | Análisis de calidad y riesgo de **un diff concreto**, no de toda la solución. Por defecto, los cambios pendientes. |
| `/rs-review <Solution>.sln [--rev <r>] [--pr <n>]` | Opus | Revisión de un cambio con **veredicto de bloqueo**: aprueba, cambios o bloquea, cruzando riesgo, seguridad y base de datos sobre el delta. Opcionalmente publica el veredicto en un pull request de GitHub. |
| `/rs-impacto <clase\|método\|tabla> en <Solution>.sln` | Sonnet | Mapa de todas las referencias a un símbolo, con clasificación de riesgo. Ejemplo: `/rs-impacto RCLIENTES en RSProcIN.sln` |
| `/rs-dead-code <Solution>.sln` | Sonnet | El inverso del impacto: símbolos sin referencias. Marca como no concluyentes los puntos de entrada, los handlers `.aspx` y lo que llega por reflexión o inyección. Advisory: no borra nada. |
| `/rs-hotspots <Solution>.sln` | Sonnet | Puntos calientes de riesgo, cruzando la frecuencia de cambios del control de versiones con la complejidad del código. Ranking para priorizar tests o refactor. |
| `/rs-security <Solution>.sln` | Opus | Escaneo de seguridad: inyección SQL, credenciales incrustadas, XSS e input sin validar. Devuelve los hallazgos con severidad y ubicación exacta. |

### Refactor y correcciones

Estos modos **escriben código** y todos piden **confirmación humana** antes de aplicar nada.

| Comando | Modelo | Qué hace |
|---|---|---|
| `/rs-rename <Solution>.sln <viejo> a <nuevo>` | Opus | Renombrado seguro: localiza todas las referencias y las reescribe. Avisa de referencias en otras soluciones y de colisiones. |
| `/rs-format <Solution>.sln [fichero]` | Opus | Corrección automática de convenciones (naming, usings, formato); es el complemento de `/rs-audit`. Solo formato, **nunca lógica**: los renombrados públicos se derivan a `/rs-rename`. |
| `/rs-migrar <Solution>.sln a <ORACLE\|SQLSERVER>` | Opus | Adapta los DALCs y el SQL entre SQL Server y Oracle. Alto impacto: reescribe SQL en todo el scope. |
| `/rs-generar-dalc <Tabla> en <Solution>.sln` | Sonnet | Genera clases DALC completas a partir del modelo de base de datos. |

### Base de datos y modelo

| Comando | Modelo | Qué hace |
|---|---|---|
| `/rs-schema <tabla\|palabra clave>` | Haiku | Esquema real de una o varias tablas: columnas, tipos, longitudes, nullabilidad e índices. Consulta pura. |
| `/rs-erd [workspace]` | Opus | Gestión del **modelo de base de datos**: actualiza desde la BD real, visualiza el ERD interactivo (arrastre, zoom, edición de descripciones, exportación a SQL, CSV, SVG y PNG), genera DDL y exporta a Oracle Data Modeler. |
| `/rs-comparar-modelo [workspace]` | Haiku | Detecta el desfase entre el modelo JSON y el esquema real. Ofrece generar los scripts de migración y sincronizar. |
| `/rs-comparar-entornos [id1] [id2] [tablas]` | Sonnet | Diferencias de esquema entre **dos conexiones** configuradas (por ejemplo desarrollo frente a producción): tablas, columnas, tipos, longitudes e índices divergentes. Solo lectura. |
| `/rs-sync-indexes [workspace]` | Haiku | Sincroniza los índices desde la base de datos real al modelo (solo Oracle). Preserva los índices marcados como manuales. |
| `/rs-seed <Solution>.sln <tabla> [N]` | Sonnet | Genera INSERTs sintéticos de prueba respetando tipo, longitud, nullabilidad, claves ajenas y unicidad. Escribe un fichero `.sql`; **no lo ejecuta** contra la base de datos. |

### Rendimiento y validación contra la base de datos

| Comando | Modelo | Qué hace |
|---|---|---|
| `/rs-validar-bd <Solution>.sln <DALC\|clase\|tabla>` | Sonnet | Valida el código C# contra la base de datos real: tipos, longitudes (truncamiento silencioso), nullabilidad y compatibilidad de motor. |
| `/rs-perf <Solution>.sln [DALC\|tabla]` | Opus | Rendimiento del acceso a datos: cruza el SQL de los DALC contra los índices del modelo y señala índices que faltan, recorridos completos de tabla, filtros no aprovechables por índice y proyecciones innecesarias sobre tablas anchas. |

### Testing

| Comando | Modelo | Qué hace |
|---|---|---|
| `/rs-test <Solution>.sln` | Haiku | Ejecuta los tests y reporta pasados, fallados y omitidos leyéndolos del fichero de resultados, no del texto de consola: así el recuento no depende del idioma de la máquina. Si no hay proyecto de test, deriva a `/rs-crear-tests`. Si el resultado no se puede leer o no se ejecuta ninguna prueba, lo dice en lugar de presentarlo como correcto. |
| `/rs-crear-tests <Solution>.sln` | Sonnet | Crea el proyecto de test si no existe y genera tests unitarios para las clases públicas. |
| `/rs-cobertura <Solution>.sln` | Sonnet | Mapa de cobertura: qué clases y métodos públicos no tienen test, empezando por las capas de datos y negocio. Advisory. |

### Control de versiones

El plugin detecta solo si el proyecto usa Subversion o Git; nunca hay que indicarlo. Sin el cliente
de línea de comandos correspondiente, estos modos degradan a instrucciones manuales para el cliente
gráfico.

| Comando | Modelo | Qué hace |
|---|---|---|
| `/rs-diff [Solution.sln]` | Haiku | Cambios pendientes de commit, agrupados por solución y proyecto. |
| `/rs-commit <Solution>.sln` | Sonnet | Filtra por scope, muestra el diff y propone el mensaje de commit. Pide **confirmación explícita** antes de ejecutar. En Git, commit y push se confirman por separado. |
| `/rs-deshacer <Solution>.sln` | Sonnet | Revierte los cambios **pendientes** del último cambio del pipeline a su estado versionado, previa confirmación. No toca commits ya hechos ni la base de datos. |
| `/rs-historial [Solution.sln] [N]` | Haiku | Historial de ejecuciones del pipeline y de commits. |
| `/rs-validar-req "<req>" --rev <r> [--sln <S>]` | Opus | Valida si los commits implementan realmente lo requerido y detecta tests que faltan. La revisión puede ser de Subversion o un hash de Git, y admite varias separadas por comas. |
| `/rs-release-notes [Solution] [N] [--desde ...]` | Sonnet | Convierte el historial de commits en notas de versión funcionales, agrupadas por tipo y escritas en lenguaje de negocio. |

### Documentación e idiomas

| Comando | Modelo | Qué hace |
|---|---|---|
| `/rs-doc <Solution>.sln` | Sonnet | Genera y **persiste** el resumen por solución (propósito, estructura, tablas, flujo y configuración) dentro del manual agentic. |
| `/rs-doc-drift <Solution>.sln [--rev <r>]` | Sonnet | Cruza los cambios recientes contra la documentación funcional y marca las secciones obsoletas, incompletas o inexistentes. Advisory: no reescribe. |
| `/rs-runbook <Solution>.sln <proceso>` | Sonnet | Runbook operativo de un proceso (carga inicial, cierre, reproceso): precondiciones, procedimiento, reglas críticas de esa operación, verificación y errores conocidos. **Entrevista al usuario**: lo que no está en el código lo aporta quien opera. Se persiste en el manual funcional. |
| `/rs-idiomas <Solution>.sln` | Opus | Escanea los `.aspx`, localiza los controles AIS y genera los INSERT de las tablas de idiomas y controles. Solo aplica a Online. |
| `/rs-word <ficheros\|carpeta>` | Haiku | Convierte documentación Markdown del manual agentic a un documento **Word** sobre la plantilla corporativa del workspace, con portada, historial de cambios, índice y los estilos de la plantilla. Requiere Microsoft Word instalado. |

Dos convenciones de idiomas que conviene conocer, porque el plugin las aplica solo:

- **Los idiomas salen de la base de datos, no de una lista fija.** Se leen del catálogo de idiomas de
  la tabla de tablas del propio cliente, así que varían por instalación: ni `/rs-idiomas` ni el gate
  del pipeline dan por hecho ningún idioma concreto.
- **Los identificadores de texto van por rangos según el tipo de texto**: errores del 1000 al 1999,
  mensajes en pantalla del 2000 al 2999, y textos de pantalla —etiquetas, cabeceras de rejilla,
  validadores— desde el 3000 sin techo. Al asignar uno nuevo se **rellenan los huecos** empezando por
  el suelo del rango, en lugar de continuar desde el máximo. Si un rango se agota, el identificador
  se busca a partir del 3000 y el script lo advierte en su cabecera.

Sobre la documentación dentro del pipeline: el manual técnico de convenciones es **input** —el
planner clasifica la tarea y el implementador lee los documentos que apliquen antes de emitir
código—. La documentación **funcional** y el resumen por solución se actualizan automáticamente tras
un cambio; el manual técnico solo se toca por propuesta que un humano confirma.

### Comprensión y onboarding

| Comando | Modelo | Qué hace |
|---|---|---|
| `/rs-explicar <Solution>.sln <clase\|método\|proceso>` | Sonnet | Explica en lenguaje natural qué hace, cuál es su flujo de datos y qué efectos laterales tiene. Puntual: no persiste nada. |
| `/rs-estructura <Solution>.sln` | Haiku | Mapa de capas, grafo de dependencias y detección de referencias circulares. |
| `/rs-deps [proyecto]` | Haiku | Dependencias entre soluciones: proyectos compartidos y conflictos de versión de paquetes. |

### Entorno, estadísticas y utilidades

| Comando | Modelo | Qué hace |
|---|---|---|
| `/rs-init` | Sonnet | Puesta en marcha de un workspace nuevo: crea la configuración de base de datos (o migra la configuración heredada), el andamiaje de documentación y el primer modelo de base de datos. **Nunca sobrescribe** nada existente. |
| `/rs-env [workspace]` | Haiku | Valida la configuración de base de datos, la ruta de instalación, el SDK de .NET, el cliente de control de versiones, el modelo BD y la documentación agentic. |
| `/rs-pii [status\|bootstrap\|audit\|enforce\|off]` | Sonnet | Protección de datos personales en las consultas a base de datos: consulta el estado, genera el inventario de columnas afectadas y cambia el modo. Se detalla en el capítulo siguiente. |
| `/rs-cifrar` | Haiku | Cifra en reposo los secretos que están en texto plano: la contraseña de base de datos y los tokens del gestor de tareas. Idempotente, no imprime ningún secreto y es retrocompatible. |
| `/rs-stats [solution]` | Haiku | Estadísticas del historial: total de ejecuciones, tasa de éxito, soluciones más trabajadas, agentes más usados y tendencia de la última semana. |
| `/rs-dashboard` | Haiku | Panel HTML autónomo con esas mismas estadísticas, con tema claro y oscuro. Es la versión visual de `/rs-stats`. |
| `/rs-help` | Haiku | Renderiza la guía de usuario a un HTML navegable con índice, tablas y tema claro/oscuro, y lo abre en el navegador. |

### Entregas a cliente: instalador y actualizador

| Comando | Modelo | Qué hace |
|---|---|---|
| `/rs-instalador [<Proyecto>\|<workspace>]` | Opus | Genera el **instalador completo de cliente** para una instalación limpia: ejecutables batch en Release, la web, el gestor de servicios con sus módulos, los scripts de base de datos (DDL de tablas, DDL de la tabla de versiones, inserts de tablas paramétricas y la fila base por entorno) y el paquete de instalación con su script de instalación, su script de ejecución de scripts, el fichero de rutas y un readme. |
| `/rs-actualizador <DESA\|TEST\|PROD> [<Sln>...] [--hasta ...]` | Opus | Genera el **actualizador incremental** de un entorno. Consulta en la tabla de versiones cuándo se entregó por última vez cada solución en ese entorno, calcula el delta de commits hasta hoy —o hasta la fecha indicada, descartando desarrollos posteriores— y empaqueta solo lo afectado, más los scripts SQL de las tareas del rango y el registro de la entrega. |

**Lo que se entrega sale de la base de datos, no del modelo.** El modelo JSON es una traducción, y
la traducción pierde cosas: en una entrega real llegaron al cliente cero claves ajenas de las doce
que había, cero restricciones de validación de las tres, una columna autonumérica convertida en un
número corriente, y varias columnas con el tamaño de hacía meses. Nada de eso daba error al
generar; todo lo daba —o algo peor que un error— en el servidor del cliente. Ahora el instalador
lee el esquema real: tipos y tamaños exactos, valores por defecto, columnas autonuméricas, claves
primarias, restricciones únicas y de validación, índices y claves ajenas.

El modelo se sigue manteniendo, pero su papel es **documentar**: descripciones, marcas de datos
personales y el diagrama. Si se detecta que el modelo y la base de datos no coinciden, se avisa y
**no se bloquea**: lo que viaja es lo que hay en la base de datos, que es lo correcto.

**Lo que no debe viajar se declara por nombre**, con su motivo, en el fichero de configuración del
proyecto. Nunca por patrón: excluir por patrón borraría en silencio tablas del producto que
casualmente encajen, y el fallo no aparece hasta que algo las usa. Los nombres que parecen copias
puntuales de desarrollo se **avisan** y **se entregan**; la decisión de excluir es siempre explícita
y queda escrita en la cabecera del script.

**Las descripciones y las marcas de datos personales no llegan al cliente**, y eso no se da por
supuesto: antes de cerrar el paquete se revisa lo generado y, si aparece alguna, la generación
falla. Antes sí llegaban, como comentarios dentro del script de creación de tablas, y nadie lo
había decidido.

**La tabla de versiones** guarda una fila por entorno y solución entregada, con la fecha de corte
—que es el punto de partida del siguiente delta— y una descripción **funcional, no técnica**, pensada
para que el usuario final pueda llegar a leerla. El actualizador genera el insert para la base de
datos del cliente y otro para la base de control interna; ninguno de los dos se ejecuta solo.

**La configuración del cliente no viaja** en el actualizador: ni la configuración de la web, ni el
XML de cada proceso batch, ni los ficheros de ajustes. Los parámetros nuevos se listan en el readme
para que se apliquen a mano. Los ficheros de configuración **del binario** sí viajan, porque llevan
las redirecciones de ensamblado.

**Cómo conecta el script de scripts en el servidor del cliente.** El fichero de rutas puede declarar
que ese entorno usa cartera de credenciales (wallet) o usuario y contraseña. Esa declaración es lo
que escribió quien preparó la entrega, **no un hecho del servidor**, así que el script la contrasta
con la máquina antes de conectar: si consta que ahí no hay cartera, no lo intenta —daría un error de
credenciales que parece de la cartera cuando lo que falta es la cartera entera— y ofrece usuario y
contraseña, que siempre está disponible. Si la conexión falla por credencial, vuelve a pedirlas hasta
tres veces. En ejecución desatendida no pregunta: termina indicando qué parámetros pasar. Y si el
fichero de rutas no declara nada, el modo **no se supone**: se resuelve por lo que hay en la máquina
y se deja escrito cuál se eligió.

**Vaciar un esquema para reinstalar de cero** es una herramienta aparte, en la carpeta de utilidades
del proyecto, y ⛔ **no** forma parte de lo que se copia al servidor del cliente. Es deliberado: el
instalador crea los objetos sin comprobar si existen y se para al primer choque, que es su forma de
decir "este esquema no está vacío, para". Una herramienta de vaciado guardada junto al instalador
convertiría esa parada en un trámite. La utilidad exige además que el usuario conectado sea el dueño
del esquema, enseña cuántas tablas contienen datos antes de tocar nada, pide que se teclee el nombre
del esquema para confirmar, y tiene un modo de simulación que genera el script de borrado sin
ejecutarlo.

Instalación en el servidor del cliente, para ambos paquetes:

- **Ejecutar los scripts.** El script de scripts los lanza en orden, se detiene al primer fallo y
  hace una comprobación previa con confirmación. El orden lo fija el fichero de orden si el paquete
  lo trae; si no, la convención de tres tandas: primero los `.sql` de la carpeta, luego los inserts
  de tablas paramétricas y por último la fila base del entorno indicado, **solo la de ese entorno**.
  Conecta con wallet de Oracle o autenticación integrada, o con usuario y contraseña, según declare
  el fichero de rutas; la contraseña nunca viaja por la línea de comandos. Admite modo simulación
  (conecta y lista, pero no escribe), recarga explícita, ejecución sin confirmación, esquema
  alternativo y ajuste de idioma del cliente.
- **Instalar los binarios.** El script de instalación hace copia de seguridad comprimida de cada
  carpeta destino antes de copiar, con las rutas declaradas en el fichero de rutas.
- **Aplicar los parámetros de configuración a mano**, según el readme del paquete.

### Tareas: Jira y Mantis

| Comando | Qué hace |
|---|---|
| `/rs-tarea [PROJ-123 \| URL \| 1234 \| init]` | **Router**: detecta qué gestor de tickets usa el proyecto y orquesta el ciclo completo de la tarea con el skill correspondiente. Selecciona la incidencia, formatea el requisito al patrón que entiende el pipeline, la pasa a "En proceso", **lanza el pipeline** y, tras el commit, adjunta los `.sql` y la pasa a "En validación". `/rs-tarea init` crea la configuración del gestor elegido. |
| `/rs-mantis [1234 \| crear \| proyectos \| init]` | Puerta **explícita** de Mantis, saltándose la detección. Además de seleccionar, puede **crear** la incidencia, siempre asignada al usuario del token. El proyecto nunca se asume: si hay más de uno, o ninguno, se listan y se pregunta. |

Es una capa **opcional y aditiva**: el pipeline funciona igual sin ella.

**Cómo detecta el gestor**: mira qué configuración existe en el workspace. Si existen las dos,
desambigua por la forma del argumento —un código con prefijo de proyecto es de Jira, un número suelto
es de Mantis— y, si eso no basta, **pregunta**: nunca adivina. Si no existe ninguna, pregunta qué
gestor se usa y ofrece crear su configuración. El gestor detectado se anuncia antes de tocar ningún
ticket.

**Requisitos.** La rama de Jira necesita el conector de Atlassian activo, y un token de API para
poder adjuntar los `.sql`; es de uso interactivo. La rama de Mantis usa un cliente REST propio con
autenticación por token, sin depender de OAuth interactivo, pero toda escritura se confirma igual.

**Valores por defecto y etiquetas.** Ambas configuraciones aceptan un bloque de valores por defecto
que se aplica a toda tarea que cree el plugin: tipo de incidencia, prioridad, componentes, etiquetas
y campos propios en Jira; categoría, prioridad, severidad y etiquetas en Mantis. La precedencia es
**lo que indique el usuario, luego los valores por defecto, y por último la réplica de la última
tarea** —esta última se puede desactivar—. Las etiquetas no se pisan: se acumulan.

### Errores de producción convertidos en tareas

| Comando | Modelo | Qué hace |
|---|---|---|
| `/rs-log-errores <ruta log\|carpeta> [--desde ...] [--max N] [--glob ...] [--niveles ...]` | Opus | Lee el log de errores de la web, **agrupa** las ocurrencias del mismo fallo, separa lo que es bug de lo que es ruido, abre **una tarea por tipo de error** en el gestor del proyecto y propone lanzar el pipeline para cada una, de una en una. |

La agrupación no la hace el modelo: la hace el analizador de logs, agrupando por **firma** —excepción,
primer frame de código propio y mensaje normalizado, donde números, identificadores, fechas y rutas
pasan a marcadores—. Así, "Cliente 4711 no existe" y "Cliente 8322 no existe" son **una** tarea y no
dos. Reconoce los formatos de log habituales de .NET y el propio de la web.

**El log no entra en la conversación**: la herramienta devuelve solo el agregado —las firmas más
frecuentes con su recuento, la ventana temporal y un par de muestras—, nunca las líneas. Da igual que
el fichero pese cientos de megabytes. Los mensajes y las muestras salen con los datos personales
redactados antes de poder acabar copiados en un ticket.

**No duplica tareas entre pasadas**: cada tarea lleva un marcador con su firma; si al volver a
analizar ya existe una incidencia abierta con esa firma, en lugar de crearla otra vez ofrece añadir
una nota con las ocurrencias nuevas.

Nada se crea sin aprobar antes la lista propuesta, y el pipeline se lanza **de una en una**, nunca en
lote.

## El modelo de base de datos no son solo tablas

El modelo JSON del proyecto incluye, además de las tablas, el **inventario de objetos**: vistas,
procedimientos, paquetes, funciones, triggers, sinónimos y secuencias. Se rellena desde la base de
datos real —con un modo de simulación para ver qué haría antes de escribir— y se ve en el ERD, que
gana una sección por tipo de objeto y, en el panel de cada tabla, **qué objetos la usan**: la pregunta
que uno se hace justo antes de cambiarle una columna.

**Se guarda la ficha y una firma del cuerpo, nunca el cuerpo.** El instalador sigue extrayendo el DDL
de la base de datos viva, y esa es la garantía de que un paquete no puede entregar código viejo. La
firma añade lo que faltaba: saber **qué ha cambiado** desde la última entrega, algo que el delta por
control de versiones no ve, porque un procedimiento modificado directamente en la base de datos no
está en el repositorio.

Con eso, el actualizador **escribe el script** de todo lo que cambió desde la última entrega, con el
mismo texto que emitiría el instalador y en orden de dependencias. Dos cosas no las decide solo, a
propósito:

- Una **secuencia modificada no viaja**, porque su DDL reiniciaría el contador del cliente y
  empezaría a repartir identificadores ya usados.
- De lo **eliminado no emite ninguna sentencia de borrado activa**: va comentada al final.

Las dos salen listadas para que alguien decida.

Y como el modelo guarda la ficha pero no el cuerpo, hay una forma de leerlo cuando hace falta: existe
una utilidad que devuelve el DDL de un objeto tal y como está **ahora** en la base de datos, y avisa
si ya no coincide con la firma del modelo. Eso es lo que convierte el inventario en algo utilizable
en el día a día: `/rs-impacto` puede decir qué procedimientos tocan una tabla **y** leerlos antes de
afirmar nada sobre ellos, sin abrir un cliente de base de datos. El ERD no puede hacerlo por su
cuenta —es un HTML estático, sin credenciales ni conexión—, así que en el panel de cada objeto muestra
el comando exacto, con botón de copiar.

## Qué hay por debajo

No hace falta conocer esta parte para usar el plugin, pero explica por qué se comporta como se
comporta.

### El servidor MCP

Un servidor local con **51 herramientas** que envuelven la lógica del plugin. Es la vía preferente
frente a los scripts: más eficiente en tokens, con caché en memoria y en disco.

Su diseño protege la conversación de saturarse:

- La compilación, la ejecución de tests, la búsqueda de símbolos y las consultas a base de datos
  truncan los resultados a un máximo.
- El analizador de logs devuelve el **agregado** de un log de errores —firmas, recuento y ventana
  temporal—, nunca sus líneas.
- El ERD, el panel de estadísticas, la generación de SQL y la exportación del modelo producen
  **ficheros**; su contenido no se carga en la conversación.
- El modelo de base de datos nunca se abre entero: se navega por búsqueda, índice y esquema de tabla
  concreta.

### Los scripts

El plugin lleva un conjunto de scripts de PowerShell que actúan como vía de respaldo cuando el
servidor MCP no está activo. Dos de ellos corren solos: el que fuerza el disparo del plugin al
mencionar una solución en un workspace RS, y el que ejecuta los builds encolados.

### El modelo de base de datos

Es un modelo JSON vivo, versionado con el proyecto:

- Tablas y columnas desde el esquema real, tanto en SQL Server como en Oracle.
- Relaciones inferidas desde el código de acceso a datos, con nivel de confianza.
- Índices sincronizables desde la base de datos y descripciones semánticas editables.
- Exportación a DDL y a Oracle Data Modeler.
- Detección de desfase y generación de scripts de migración.
- **Mezcla segura**: preserva siempre lo introducido a mano y las descripciones; las tablas ausentes
  se marcan como huérfanas, nunca se borran.
- **Formato estable**: lo escribe un único serializador canónico y se verifica tras cada escritura.
  El fichero vive en el repositorio y se revisa por diff, así que dos escritores con dos formatos
  harían el diff inservible aunque el contenido fuese idéntico.

### Cuando la cuenta de BD no ve todo el esquema

Si la cuenta de base de datos **no es dueña del esquema**, ve solo lo que tiene concedido, y Oracle no
permite distinguir un objeto inexistente de uno sin permiso. Por eso:

- Una tabla que no aparece en la sincronización **se conserva entera** —columnas, relaciones e
  índices— y se marca como no visible. Nunca se borra ni se degrada.
- Cada sincronización emite un **bloque de cobertura**: cuántos objetos de cada tipo ve el diccionario
  frente a los capturados, con qué cuenta se leyó y qué permisos tiene. Si hay hueco, el resultado es
  "parcial" —"el modelo está incompleto", que no es lo mismo que "eso ya no está"—.
- El código de servidor exige permiso de ejecución, no de lectura. Sin él, el diccionario devuelve
  cero procedimientos sin dar error; el instalador y el actualizador **fallan** en ese caso, en vez de
  entregar un paquete sin lógica de servidor.
- Para leer con otra cuenta se puede indicar la conexión alternativa, tomada de las conexiones
  declaradas en la configuración. Es la única forma de ver los sinónimos privados. Sin indicarla se
  usa siempre la conexión principal; un identificador que no existe corta la ejecución mostrando la
  lista de válidos, y la conexión usada aparece en la salida.

## Reglas clave

- **Aprobación humana del plan** obligatoria antes de tocar código. No aplica a los modos de solo
  lectura.
- Validator y tester son **bloqueantes**: el build no se ejecuta si fallan.
- **Scope estricto**: solo entran los proyectos incluidos en la solución activa.
- **Build con evidencia**: nunca se da un build por bueno sin salida real del ejecutor.
- El modelo de base de datos preserva siempre las descripciones y las relaciones introducidas a mano.
- Los scripts SQL generados van siempre a la carpeta de scripts del proyecto.
- Los scripts de idiomas son obligatorios en Online cuando hay controles, textos o rebinds nuevos,
  con los idiomas leídos del catálogo del cliente y los identificadores asignados por rango,
  rellenando huecos.
- El control de versiones **nunca se asume**: se detecta antes de cualquier diff o commit.
- Todos los modos que **escriben** piden confirmación antes de aplicar.

## Requisitos de la máquina

| Componente | Para qué |
|---|---|
| Python 3.11 o superior, con el paquete `mcp` en el rango `>=1.2.0,<2` | Servidor MCP. El paquete **no se instala solo** y sin él el servidor no arranca. El tope de versión es obligatorio. Tiene que quedar en el Python que resuelve `python` en el PATH. Es el único requisito que el plugin comprueba por su cuenta al arrancar cada sesión, porque es el que deja el resto sin servicio |
| SDK de .NET | Compilar y testear las soluciones de .NET moderno |
| PowerShell 7 o superior | Scripts del plugin |
| Visual Studio o las Build Tools | Compilar y testear las soluciones de .NET Framework (web, batch, COM) y los builds de Online. El plugin localiza el compilador y el ejecutor de tests por su cuenta, leyendo los proyectos de cada solución; si falta el que hace falta, avisa de que la compilación no se ha verificado en lugar de dar un falso "no compila" |
| Cliente de Subversion **o** de Git | Diff, commit e historial, según el proyecto |

Con Subversion conviene instalar el cliente de línea de comandos con la **misma versión** que el
cliente gráfico, para evitar conflictos de copia de trabajo.

**Primer arranque en un workspace nuevo**: `/rs-init` crea la configuración de base de datos, el
andamiaje de documentación y el primer modelo; después, `/rs-env` valida que todo está en su sitio.

## Problemas frecuentes

- **Los comandos `/rs-*` no aparecen.** Falta reiniciar Claude Code tras instalar o actualizar el
  plugin.
- **Las herramientas no responden y `/rs-help` falla.** Es Python: o no está instalado (y `python`
  resuelve al marcador de la Microsoft Store, que no ejecuta nada), o el paquete `mcp` no está, o
  está en un Python distinto del que resuelve `python` en el PATH, o es una versión 2.x. El aviso de
  arranque de la sesión y `/rs-env` dicen cuál de los cuatro es, con el comando de arreglo.
- **`/plugin marketplace update` no trae los cambios.** El plugin se ejecuta desde la copia cacheada
  en el perfil del usuario; después de actualizar hay que reiniciar. Desde la 3.25.0 no hace falta
  sospecharlo: al arrancar la sesión el plugin compara la copia que ejecuta con la fuente de la que
  sale, y si no cuadran lo dice, con la lista de ficheros afectados y el comando de arreglo.
- **La compilación no se verifica.** Falta el compilador o el ejecutor de tests que exige el tipo de
  solución. El plugin lo dice explícitamente en lugar de reportar un fallo de compilación falso.
