<#
.SYNOPSIS
    Cifrado en reposo de secretos del plugin (password BD, tokens Jira/Mantis) con DPAPI.

.DESCRIPTION
    DPAPI (Windows Data Protection API), scope CurrentUser: el secreto cifrado solo lo puede
    descifrar la MISMA cuenta de Windows en la MISMA máquina. Protege si el fichero de credenciales
    se copia a otro equipo/usuario, o lo lee otro usuario del sistema. ⛔ NO protege frente a código
    que se ejecuta como el propio usuario (podría descifrarlo igual).

    Formato en disco: `enc:<base64 del blob DPAPI>`. Los lectores tratan cualquier valor SIN el
    prefijo `enc:` como texto plano (legacy) → retrocompatibilidad total y migración suave.

    ⛔ PARIDAD: el descifrado en Python vive en `_unprotect_secret` (mcp/rs-workspace-server.py y
    scripts/installer-inserts.py). El blob DPAPI es el mismo (CryptProtectData/CryptUnprotectData
    sobre los bytes UTF-8), así que un secreto cifrado aquí se descifra en Python y viceversa.

    ⛔ Windows-only: en otros SO DPAPI no existe. Dot-sourcear desde los hooks que lean secretos.
#>

$script:RsEncPrefix = "enc:"

# Carga defensiva del tipo ProtectedData: en Windows PowerShell 5.1 hace falta Add-Type; en
# PowerShell 7 (Windows) el tipo ya viene cargado.
if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
    try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
}

function Test-RsEncrypted {
    <# ¿El valor está cifrado (lleva el prefijo enc:)? #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return $Value.StartsWith($script:RsEncPrefix)
}

function Protect-RsSecret {
    <# Cifra un secreto con DPAPI (CurrentUser) → "enc:<base64>". Cadena vacía → "" (nada que cifrar).
       Un valor ya cifrado (enc:...) se devuelve tal cual (idempotente). #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Plain)
    if ($Plain -eq "") { return "" }
    if (Test-RsEncrypted $Plain) { return $Plain }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
    $enc   = [System.Security.Cryptography.ProtectedData]::Protect(
                $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return $script:RsEncPrefix + [Convert]::ToBase64String($enc)
}

function Unprotect-RsSecret {
    <# Descifra un valor "enc:<base64>" con DPAPI (CurrentUser). Un valor SIN el prefijo enc: se
       devuelve tal cual (texto plano legacy). Cadena vacía → "". #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value -eq "") { return "" }
    if (-not (Test-RsEncrypted $Value)) { return $Value }   # texto plano legacy
    $b64 = $Value.Substring($script:RsEncPrefix.Length)
    $enc = [Convert]::FromBase64String($b64)
    $dec = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($dec)
}
