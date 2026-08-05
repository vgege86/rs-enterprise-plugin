{
  "_comentario": "Rutas de instalacion y backup EN EL SERVIDOR DEL CLIENTE, una entrada por entorno. Lo consumen Instalar.ps1 y Ejecutar-Scripts.ps1. NO contiene contrasenas: Ejecutar-Scripts.ps1 las pide por consola y nunca las pasa por la linea de comandos.",
  "_bd": {
    "motor": "ORACLE | SQLSERVER",
    "conexion": "Oracle con wallet: el ALIAS EXACTO de tnsnames.ora, nunca un descriptor (DESCRIPTION=...) ni un EZConnect host:puerto/servicio (el wallet indexa por el texto del alias y el troceo por / y @ da ORA-12154). Oracle con usuario o SQL Server: la cadena habitual",
    "usuario": "vacio si autenticacion es externa",
    "autenticacion": "wallet|externa|integrada -> autenticacion externa (Oracle: wallet; SQL Server: -E). usuario -> usuario y contrasena. Si se omite, se deduce de si hay 'usuario'",
    "tnsAdmin": "Oracle: carpeta con sqlnet.ora / tnsnames.ora / wallet. Vacio para usar %TNS_ADMIN%",
    "schema": "opcional. CURRENT_SCHEMA, para cuando el usuario de conexion no es el dueno de las tablas"
  },
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
        "usuario": "<USUARIO>",
        "autenticacion": "usuario",
        "tnsAdmin": "",
        "schema": ""
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
