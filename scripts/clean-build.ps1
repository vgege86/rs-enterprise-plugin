param(
    [string]$workspace
)

Write-Host "Cleaning build folders..."

Get-ChildItem -Path $workspace -Recurse -Include bin,obj | ForEach-Object {
    try {
        Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
        Write-Host "Deleted: $($_.FullName)"
    }
    catch {
        Write-Host "Could not delete: $($_.FullName)"
    }
}

Write-Host "Build folders cleaned ✅"