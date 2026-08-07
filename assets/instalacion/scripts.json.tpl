{
  "_comentario": "Orden de ejecucion de los .sql de este paquete. Si este fichero existe junto a los scripts, MANDA sobre el descubrimiento por carpetas de Ejecutar-Scripts.ps1. Rutas relativas a la carpeta de scripts.",
  "_campos": {
    "ruta": "obligatorio. Relativa a la carpeta de scripts, con / o \\",
    "opcional": "si true y el fichero no esta en disco, se avisa y se continua. Por defecto false: un script obligatorio ausente aborta ANTES de conectar",
    "entorno": "si se indica, el script solo se ejecuta cuando -Entorno coincide",
    "purga": "si true, solo se ejecuta con -Recargar, y va antes que el resto",
    "ejecutar": "si false, el fichero viaja en el paquete y NO se ejecuta. Para los maestros que encadenan a otros (<Proyecto>-CreacionObjetos.sql, Inserts\\_run_all.sql): ejecutarlos ademas crearia cada objeto y cada fila dos veces. Al estar declarados tampoco salen como no declarados, y su ausencia en disco no aborta la instalacion"
  },
  "_nota": "Un .sql presente en la carpeta y NO declarado aqui se avisa y NO se ejecuta: lanzar SQL no declarado contra la BD de un cliente es peor que omitirlo.",
  "_aviso": "Esta plantilla NO se copia al paquete. Es la referencia del formato: el manifiesto real lo escribe /rs-actualizador (el agente, con el orden que acuerda con el usuario) o hooks/instalacion-paquete.ps1 (en instalacion limpia, a partir de lo que hay en Scripts\\). Un scripts.json con estas rutas de ejemplo abortaria la ejecucion, porque declara como obligatorios ficheros que no existen. Sin scripts.json, Ejecutar-Scripts.ps1 descubre los .sql por convencion de carpetas y los ordena POR NOMBRE, que en una instalacion limpia es el orden equivocado.",
  "scripts": [
    { "ruta": "01-<TAREA>-1.sql" },
    { "ruta": "02-<TAREA>-2.sql" },
    { "ruta": "99-RVERSIONES-<ENTORNO>.sql", "entorno": "<ENTORNO>" },
    { "ruta": "<MAESTRO>.sql", "ejecutar": false }
  ]
}
