{
  "_comentario": "Rutas de instalacion y backup EN EL SERVIDOR DEL CLIENTE, una entrada por entorno. Lo consumen Instalar.ps1 y Ejecutar-Scripts.ps1. NO contiene contrasenas: Ejecutar-Scripts.ps1 las pide por consola.",
  "proyecto": "<PROYECTO>",
  "entornos": {
    "DESA": {
      "backup": "D:\\Backups\\<PROYECTO>\\DESA",
      "modulos": {
        "AgendaWeb": "D:\\inetpub\\wwwroot\\AgendaWeb",
        "Exes": "D:\\AIS\\<PROYECTO>\\Procesos",
        "ServiceManager": "D:\\AIS\\<PROYECTO>\\ServiceManager",
        "Modulos": "D:\\AIS\\<PROYECTO>\\ServiceManager\\Modulos"
      },
      "bd": {
        "motor": "ORACLE",
        "conexion": "//servidor:1521/SID",
        "usuario": "<USUARIO>"
      }
    },
    "TEST": {
      "backup": "D:\\Backups\\<PROYECTO>\\TEST",
      "modulos": {
        "AgendaWeb": "",
        "Exes": "",
        "ServiceManager": "",
        "Modulos": ""
      },
      "bd": {
        "motor": "ORACLE",
        "conexion": "",
        "usuario": ""
      }
    },
    "PROD": {
      "backup": "D:\\Backups\\<PROYECTO>\\PROD",
      "modulos": {
        "AgendaWeb": "",
        "Exes": "",
        "ServiceManager": "",
        "Modulos": ""
      },
      "bd": {
        "motor": "ORACLE",
        "conexion": "",
        "usuario": ""
      }
    }
  }
}
