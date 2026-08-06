<?xml version="1.0" encoding="utf-8"?>
<!--
  Configuracion centralizada de los batch .NET Framework de este workspace.

  MSBuild importa este fichero automaticamente en TODO proyecto que cuelgue de esta carpeta, asi
  que sustituye al app.config por proyecto. Convencion completa: references\batch-config.md.

  Generado por hooks\batch-centralizar.ps1 -Aplicar.
-->
<Project>

  <PropertyGroup>
    <!-- Excepcion POR PROYECTO: si la carpeta del proyecto tiene su propio app.config, se respeta y
         este fichero no lo pisa. Los procesos que hospedan un AppDomain hijo (p.ej. RSCore.exe y
         RSActBD.exe) conservan el suyo porque llevan <probing privatePath>, loadFromRemoteSources y
         los bindingRedirect de ese AppDomain, que MSBuild NO puede autogenerar.
         ⛔ No unificarlos: perderian esos tres bloques y dejarian de arrancar. -->
    <AppConfig Condition="'$(AppConfig)' == '' And !Exists('$(MSBuildProjectDirectory)\app.config')">$(MSBuildThisFileDirectory)App.Batch.config</AppConfig>

    <!-- MSBuild genera el bloque <runtime> con los bindingRedirects al dia y lo escribe en
         bin\<Config>\<Exe>.exe.config. Esa es la unica copia valida del config de un ejecutable:
         nunca se reconstruye a mano ni se copia desde el arbol de fuentes. -->
    <AutoGenerateBindingRedirects>true</AutoGenerateBindingRedirects>
    <GenerateBindingRedirectsOutputType>true</GenerateBindingRedirectsOutputType>
  </PropertyGroup>

  <!-- Dependencias de ODP.NET declaradas EXPLICITAMENTE, con <Private>true</Private> para que se
       copien al bin.

       ⛔ Por que hace falta declararlas: Comun.dll no las referencia en su IL — quien las usa es
       Oracle.ManagedDataAccess.dll. Al compilar un EXE, MSBuild sigue la cadena
       Comun.dll -> Oracle.ManagedDataAccess.dll -> System.Text.Json <ver>, no encuentra esa version
       en packages y DESCARTA la referencia SIN NINGUN WARNING. El bin queda sin esas DLL y el
       proceso arranca bien pero muere en el primer acceso a BD con:
         "Se produjo una excepcion en el inicializador de tipo de
          'Oracle.ManagedDataAccess.Client.OracleCommand'"
       Fallo silencioso en build y explosivo en ejecucion. Lo vigila el gate de dependencias ODP.NET
       de hooks\installer-batch.ps1. -->
  <ItemGroup>
<!--REFERENCIAS-->
  </ItemGroup>

</Project>
