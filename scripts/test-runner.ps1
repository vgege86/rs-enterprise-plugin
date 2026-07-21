param(
    [string]$workspace,
    [string]$solution
)

Write-Host "====================================="
Write-Host " TEST RUNNER"
Write-Host "====================================="

# =====================================
# 📂 RESOLVER RUTA DE SOLUCIÓN
# =====================================

# Detectar tipo
if ($solution.StartsWith("RSProc")) {
    $solutionPath = "$workspace\Batch\Soluciones\$solution.sln"
}
else {
    $solutionPath = "$workspace\OnLine\Soluciones\$solution.sln"
}

Write-Host "Solution: $solution"
Write-Host "Path: $solutionPath"

# =====================================
# ✅ VALIDACIÓN
# =====================================

if (!(Test-Path $solutionPath)) {
    Write-Host "❌ Solution not found"
    exit 1
}

# =====================================
# 🚀 EJECUTAR TESTS
# =====================================

Write-Host "Running tests..."

try {
    dotnet test "$solutionPath" --no-build --verbosity minimal

    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Tests FAILED"
        exit 1
    }

    Write-Host "✅ Tests PASSED"
}
catch {
    Write-Host "❌ Test execution error"
    Write-Host $_
    exit 1
}

# =====================================
# ✅ FINAL
# =====================================

Write-Host "Test runner completed"
exit 0