# Puesta en producción con protección de datos personales y credenciales cifradas

## Por qué existe esta configuración

Los agentes consultan la base de datos en modo lectura. Sin ninguna medida, el resultado íntegro de
una consulta entra en la conversación —y de ahí a un proveedor externo— sin filtro alguno: nombres,
documentos de identidad, teléfonos, cuentas bancarias y direcciones de personas en gestión de cobro.

La protección de datos personales sustituye esos valores, **antes de que salgan de la herramienta**,
por un seudónimo determinista calculado con una clave que vive en el perfil local de cada
desarrollador, fuera del repositorio:

```
IDDEUDOR | NOMBRE           | DNI              | SALDO
---------+------------------+------------------+--------
1024     | pii:3f9a2c1b7e04 | pii:7e04dd5111a6 | 1250.00
1025     | pii:c8b17ff2a390 | pii:11a6b930c8b1 |  340.50
1026     | pii:3f9a2c1b7e04 | pii:7e04dd5111a6 |  980.00
```

Que el seudónimo sea determinista es deliberado: la tercera fila del ejemplo es de la misma persona
que la primera y **se sigue viendo que lo es**, así que los datos enmascarados se pueden cruzar y
razonar sobre ellos sin verlos.

**Arranca apagada: si no se hace nada, no cambia nada.** El modo por defecto es "apagado" mientras el
modelo de base de datos del proyecto no declare otra cosa, así que un workspace que se actualiza
sigue viendo exactamente los mismos resultados que antes. Nada se activa solo.

Dos cosas sí aplican siempre, también con el modo apagado, porque no dependen de la política del
workspace: el historial de ejecuciones se sanea al escribirlo —un documento de identidad, un IBAN o
un correo en la descripción de una tarea se guarda como marcador—, y las guardas del arranque, **si**
están registradas, bloquean el uso de clientes de base de datos directos y la escritura de datos
personales en ficheros. Ninguna de las dos cambia lo que devuelve una consulta.

## Los tres modos

| Modo | Qué hace |
|---|---|
| `off` (por defecto) | No se evalúa nada, los datos salen en claro. Cada respuesta lo indica. **No protege.** |
| `audit` | Evalúa cada columna e informa de qué se **habría** enmascarado. **No protege: los datos siguen saliendo en claro.** Quien activa `audit` no puede reportar que ha activado la protección. |
| `enforce` | Enmascarado real. Se puede elegir entre seudónimo —por defecto, permite correlacionar filas— o supresión completa, que sustituye el valor por un literal fijo y no permite correlación. |

### Qué se considera dato personal

La clasificación va por precedencia:

- La marca explícita de la columna en el modelo, en cualquiera de sus dos direcciones.
- El patrón del nombre de la columna: teléfonos, documentos, cuentas y similares.
- Que la tabla sea paramétrica.
- El tipo del dato: los numéricos, las fechas y las claves primarias y ajenas salen en claro.
- Por defecto, el texto se enmascara.

### El bloque de política en el modelo

La política vive en el modelo de base de datos del proyecto, versionado con él. Declara el modo, la
transformación a aplicar, y los patrones de nombre que se añaden o se quitan respecto a los que trae
el plugin de serie. A nivel de columna se puede marcar una como dato personal o como segura.

El modelo es un fichero grande: **no se abre entero para editarlo**. El propio modo `/rs-pii` se
encarga de escribir el bloque de política sin cargarlo en la conversación.

## Qué NO protege

Esta medida es **provisional**. El control definitivo —una cuenta de base de datos de solo lectura
con redacción en el propio motor— está pedido a Sistemas por escrito. Mientras tanto, conviene tener
claros sus límites:

- **Solo filtra las consultas de datos.** Las herramientas que mantienen el modelo y leen estructura
  no pasan por el filtro: leen metadatos —nombres de tabla, de columna, tipos, índices—, no datos de
  personas, y esos nombres salen siempre en claro. El reverso: si el **catálogo del sistema** se
  consulta como si fueran datos, esos nombres **sí** vuelven enmascarados, porque esas tablas no
  están en el modelo. Para leer estructura hay que usar las herramientas de modelo.
- **El dato sale de la base de datos.** El motor sigue emitiendo el valor en claro y el filtro actúa
  después. Cualquier fallo, error de configuración o ruta no prevista lo expone. El control en el
  motor no tendría esta propiedad.
- **Es evitable.** El bloqueo de los clientes de base de datos directos es un **guardarraíl frente al
  descuido, no una frontera de seguridad**: se elude con un script intermedio o invocando el binario
  por otra vía.
- **Una condición de filtrado sigue infiriendo el valor.** Una consulta que cuenta filas con un
  documento que empieza por unos dígitos devuelve un número, que sale en claro por diseño; repitiendo
  la consulta se reconstruye el dato sin haber visto un solo valor enmascarado. La medida **avisa**,
  no bloquea: bloquear rompería el filtrado legítimo.
- **Un seudónimo sigue siendo dato personal.** El artículo 4(5) del RGPD es explícito: la
  seudonimización reduce el riesgo, no saca el dato del ámbito de la norma. El seudónimo se sigue
  transfiriendo al proveedor externo. Si el requisito es que el dato personal **no salga en claro**,
  esto lo cumple; si es que **no salga**, no lo cumple.
- **Depende de que el plugin esté instalado.** Las guardas las declara el propio plugin y se
  instalan, actualizan y retiran con él. Queda la dependencia ordinaria: sin plugin no hay guardas, y
  un plugin recién instalado o actualizado no las tiene vivas hasta reiniciar Claude Code.
- **La vía de respaldo puede devolver datos sin filtrar.** Si la consulta cae al script de respaldo y
  allí el filtro **no se puede ni ejecutar** —falta Python o falta el fichero del filtro en el
  puesto—, la consulta devuelve los datos sin enmascarar y lo señala en la respuesta. Es deliberado:
  dejar la consulta sin servicio empujaría al cliente de base de datos directo, que no pasa por
  ningún filtro. Si el filtro sí corre y falla, no se devuelve ninguna fila.
- **Una columna marcada como segura por error no se detecta**, salvo que sus valores tengan forma
  reconocible. Nombres, apellidos y direcciones no la tienen. Solo lo ve la revisión del cambio en el
  control de versiones.
- **Quedan fuera del filtro** los ficheros que generan el instalador y el actualizador, la
  exportación del modelo y los informes HTML. Se entregan al cliente por diseño y pueden contener
  datos reales; su control es organizativo, no técnico.

## Cifrado de credenciales en reposo

`/rs-cifrar` cifra los secretos que hasta entonces viven en texto plano:

- La **contraseña de base de datos**, dentro de la configuración de conexiones del workspace.
- El **token de Jira** y el **token de Mantis**, en el perfil del usuario.

Cada valor pasa a una forma cifrada que los lectores del plugin descifran al vuelo. Es
**idempotente** —lo ya cifrado se salta—, **retrocompatible** —un valor sin cifrar sigue
funcionando— y **no imprime ningún secreto** en ningún momento.

Dos límites que conviene conocer antes de usarlo:

- El secreto cifrado **solo lo descifra la misma cuenta de Windows en la misma máquina**. Al migrar
  de equipo o cambiar de usuario hay que volver a introducir los secretos en claro y cifrarlos de
  nuevo.
- Protege frente a la copia del fichero o frente a otro usuario del equipo, **no** frente a código
  que se ejecute como el propio usuario.

## Orden de activación, y por qué importa

Todo lo que escribe pide **confirmación explícita**, en cualquier dirección: también al volver a
apagar la protección.

El orden no es una recomendación de estilo. El inventario de columnas solo se puede construir con los
datos en claro, así que **no se puede generar con el enmascarado ya activo**: llegarían enmascarados
y el inventario saldría vacío o falso. Y las guardas del arranque solo se leen al arrancar, así que
el reinicio final tampoco es opcional.

## Procedimiento A: repositorio que usa el plugin por primera vez

### Paso 1. Inicializar el workspace

`/rs-init` crea la configuración de base de datos —o migra la configuración heredada si existe—, el
andamiaje de documentación y el primer modelo de base de datos. Nunca sobrescribe nada existente.

### Paso 2. Validar el entorno

`/rs-env` comprueba la configuración de base de datos, la ruta de instalación, el SDK de .NET, el
cliente de control de versiones, el modelo y la documentación. La fila de protección de datos
personales nunca se omite del informe.

### Paso 3. Cifrar las credenciales

`/rs-cifrar`. Se hace ahora, con el fichero de conexiones recién creado, para que la contraseña no
llegue a convivir en claro con el trabajo diario.

### Paso 4. Ver el punto de partida

`/rs-pii status` informa del modo actual, de si las guardas están registradas y de qué columnas
saldrían hoy en claro. Es de solo lectura.

### Paso 5. Generar el inventario

`/rs-pii bootstrap` muestrea la base de datos y escribe el inventario de columnas afectadas: tabla,
columna, categoría y tratamiento propuesto. No toca el modelo y **nunca reproduce un valor
muestreado**. Es requisito para poder activar el enmascarado.

### Paso 6. Medir sin proteger

`/rs-pii audit` evalúa cada columna e informa de qué se habría enmascarado, sin cambiar lo que se ve.
Aquí es donde se revisan los aciertos y los falsos positivos, y se corrigen las clasificaciones
equivocadas, antes de que empiecen a molestar.

### Paso 7. Activar el enmascarado

`/rs-pii enforce` comprueba que existe el inventario, registra las guardas en la configuración
personal de Claude Code —fuera del repositorio, afecta a todas las sesiones del usuario—, verifica
que el registro ha funcionado y **solo entonces** escribe el modo. Si el registro falla, no conmuta.

### Paso 8. Reiniciar Claude Code

**No es opcional.** Claude Code lee la configuración de guardas al arrancar: las guardas registradas
en una sesión **no están vivas en esa sesión**. Hasta reiniciar, el enmascarado solo cubre las
consultas que pasan por la herramienta de datos; la vía del cliente de base de datos directo y la de
escritura en ficheros siguen abiertas.

### Paso 9. Verificar

`/rs-pii status` y `/rs-env` deben coincidir: modo `enforce` y guardas registradas. Conviene rematar
con una consulta real que devuelva alguna columna de datos personales, y comprobar que vuelve
enmascarada.

## Procedimiento B: proyecto que ya usa el plugin

### Paso 1. Fotografiar el estado actual

`/rs-pii status` y `/rs-env`, y anotar el resultado. Es lo que permite volver atrás sabiendo a dónde.

### Paso 2. Cifrar las credenciales

`/rs-cifrar`. Es idempotente: si ya estaban cifradas, lo dice y no toca nada.

### Paso 3. Poner el modelo al día

El inventario se construye sobre el modelo, así que primero hay que asegurarse de que refleja la base
de datos real: `/rs-comparar-modelo` detecta el desfase y `/rs-erd` lo sincroniza.

### Paso 4. Bajar a `audit` si ya estaba en `enforce`

Si el workspace ya tenía el enmascarado activo, hay que bajarlo a `audit` antes de regenerar el
inventario. Con el enmascarado activo el muestreo no ve nada útil.

### Paso 5. Regenerar el inventario

`/rs-pii bootstrap`, ahora sobre el modelo actualizado. El inventario anterior, si lo había, queda
sustituido.

### Paso 6. Auditar sobre el trabajo real

`/rs-pii audit` y unos días de uso normal. Es el paso que más ahorra: las clasificaciones equivocadas
salen a la luz trabajando, no revisando una tabla.

### Paso 7. Activar el enmascarado

`/rs-pii enforce`, con las mismas comprobaciones que en el procedimiento anterior.

### Paso 8. Reiniciar y verificar

Reiniciar Claude Code y comprobar con `/rs-pii status` y `/rs-env` que el modo y las guardas
coinciden.

### Paso 9. Cómo volver atrás

`/rs-pii off` devuelve el modo a apagado. **No desregistra las guardas**: son configuración personal,
posiblemente compartida con otros workspaces, y siguen bloqueando los clientes de base de datos
directos y la escritura de datos personales con o sin enmascarado.

## Un desarrollador nuevo o una máquina nueva

La política de enmascarado viaja en el modelo, que está en el repositorio: al clonar, el modo llega
con él. Lo que **no** viaja es lo personal, y hay que rehacerlo en cada puesto:

- Las **guardas**: se registran en la configuración personal de Claude Code. `/rs-pii status` dice si
  están; si no, basta con volver a ejecutar `/rs-pii enforce` en ese puesto y reiniciar.
- Los **secretos cifrados**: el cifrado está ligado a la cuenta de Windows y a la máquina. En un
  equipo nuevo hay que introducir los secretos en claro y ejecutar `/rs-cifrar` otra vez.
- La **clave de seudonimización**: vive en el perfil local. Un puesto distinto genera seudónimos
  distintos para la misma persona, lo cual es correcto —no hay que compartirla— pero significa que
  los seudónimos no se pueden comparar entre puestos.

## Corregir una columna mal clasificada

La clasificación va por nombre, tipo y tabla: no adivina. Las dos direcciones se corrigen en el
modelo de base de datos.

- **Sale en claro y sí es dato personal**: marcar la columna como dato personal. Si el caso es
  sistemático, añadir un patrón a la política en lugar de marcar columna a columna.
- **Sale enmascarada y no lo es**: marcar la columna como segura. Si lo que sobra es el patrón de
  nombre para todo el workspace, quitarlo desde la política.
- **Sigue enmascarada pese a estar marcada como segura**: entonces son sus **valores** los que tienen
  forma de dato personal —documento, IBAN, correo, teléfono, tarjeta—. Es la red de seguridad por
  forma del valor, y **no se puede desactivar**: no existe una marca de "en claro pase lo que pase".
  Conviene comprobar el contenido real antes de darlo por falso positivo.

El remedio de un enmascarado que molesta nunca es rodear el filtro.

## Problemas frecuentes

- **`status` dice que las guardas están registradas, pero no bloquean.** Falta reiniciar Claude Code:
  el estado describe el fichero de configuración, no la sesión en curso.
- **El inventario sale vacío o sin sentido.** Se ha generado con el enmascarado ya activo. Hay que
  bajar a `audit`, regenerarlo y volver a subir.
- **Una consulta al catálogo del sistema devuelve nombres de tabla enmascarados.** Esas tablas no
  están en el modelo, así que el filtro las trata como datos. Para leer estructura hay que usar las
  herramientas de modelo, no la consulta directa.
- **Tras cambiar de equipo, las credenciales no funcionan.** El cifrado está ligado a la cuenta de
  Windows y a la máquina anterior. Hay que reintroducir los secretos y ejecutar `/rs-cifrar`.

## Lista de verificación final

Antes de dar la puesta en producción por cerrada:

- El modelo de base de datos refleja el esquema real.
- El inventario de columnas está generado y revisado.
- El modo es `enforce`, no `audit`. Si es `audit`, **no hay protección**, y no se puede reportar como
  si la hubiera.
- Las guardas figuran como registradas en `/rs-pii status` y en `/rs-env`.
- Claude Code se ha reiniciado **después** de registrarlas.
- Una consulta real sobre una columna de datos personales vuelve enmascarada.
- Las credenciales del puesto están cifradas.
- Todo el equipo ha hecho lo mismo en su propio puesto: las guardas y los secretos no viajan con el
  repositorio.
