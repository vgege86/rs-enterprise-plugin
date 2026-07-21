param(
    [string]$workspace
)

Write-Host "Project structure:"

Get-ChildItem -Path $workspace -Recurse | Select-Object FullName