param(
    [string]$prompt
)

$outputFile = "output.txt"

Write-Host "Running agent with prompt:"
Write-Host $prompt

# Aquí simulas o integras llamada a Claude/export
Write-Host "Generating output file..."

# En real:
# claude-code "$prompt" > $outputFile

Write-Host "Executing runner..."

.\runner\runner.ps1 $outputFile