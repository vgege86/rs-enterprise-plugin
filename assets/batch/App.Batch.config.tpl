<?xml version="1.0" encoding="utf-8"?>
<!--
  Configuracion COMUN de los procesos batch .NET Framework de este workspace.

  Batch\Directory.Build.targets la asigna como <AppConfig> a cada proyecto que NO tenga su propio
  app.config. MSBuild la toma como base y GENERA <Exe>.exe.config en bin\<Config>\ anadiendo el
  bloque <runtime> con los bindingRedirects (AutoGenerateBindingRedirects).

  ⛔ NO lleva bloque <runtime>: lo escribe MSBuild en cada build. Anadirlo a mano aqui congela los
     redirects y reintroduce el desalineo config/DLL que provoca FileLoadException -> StackOverflow.

  ⛔ NO es desplegable. Es fuente de compilacion: no debe aparecer nunca en un paquete de entrega.
     La unica copia valida de la configuracion de un ejecutable es su bin\<Config>\<Exe>.exe.config.

  Generado por hooks\batch-centralizar.ps1 -Aplicar. Convencion: references\batch-config.md.
-->
<configuration>

  <configSections>
    <section name="oracle.manageddataaccess.client"
             type="OracleInternal.Common.ODPMSectionHandler, Oracle.ManagedDataAccess, Version=<ODP_VERSION>, Culture=neutral, PublicKeyToken=<ODP_TOKEN>" />
  </configSections>

  <startup>
    <supportedRuntime version="v4.0" sku=".NETFramework,Version=<TFM>" />
  </startup>

  <system.data>
    <DbProviderFactories>
      <remove invariant="Oracle.ManagedDataAccess.Client" />
      <add name="ODP.NET, Managed Driver"
           invariant="Oracle.ManagedDataAccess.Client"
           description="Oracle Data Provider for .NET, Managed Driver"
           type="Oracle.ManagedDataAccess.Client.OracleClientFactory, Oracle.ManagedDataAccess, Version=<ODP_VERSION>, Culture=neutral, PublicKeyToken=<ODP_TOKEN>" />
    </DbProviderFactories>
  </system.data>

  <oracle.manageddataaccess.client>
    <version number="*">
      <settings>
        <!-- Ajustes comunes del driver gestionado.
             ⛔ Las cadenas de conexion NO van aqui: viven en el XML de configuracion de cada
             proceso (RSCore.xml, RSActBD.xml, ...), que es configuracion del entorno del cliente
             y no viaja en las entregas. -->
      </settings>
    </version>
  </oracle.manageddataaccess.client>

</configuration>
