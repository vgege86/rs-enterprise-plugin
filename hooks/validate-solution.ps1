<#
.SYNOPSIS
    Confirma que la .sln existe y es accesible. Emite JSON en ambas rutas.
.PARAMETER path
    Ruta al fichero .sln.
#>
param(
    [Parameter(Mandatory = $true)][string]$path
)

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

if (-not (Test-Path $path)) {
    @{ success = $false; error = "Solution not found"; sln_path = $path } | ConvertTo-Json
    exit 1
}

@{
    success  = $true
    sln_path = (Resolve-Path $path).Path
    solution = [IO.Path]::GetFileNameWithoutExtension($path)
} | ConvertTo-Json
exit 0
