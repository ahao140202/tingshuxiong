# Full regression: static analysis + full test suite.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\regression.ps1
# Convention: run this script after every code change; exit 0 = all green.

$ErrorActionPreference = 'Continue'  # PS 5.1: flutter stderr would abort with 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logFile = Join-Path $env:TEMP "tingshuxiong_regression.log"
$failed = $false

function Step($name) {
    Write-Host "`n========== $name ==========" -ForegroundColor Cyan
}

# Run a command with all output streams redirected to a log file
# (avoids NativeCommandError false positives from flutter stderr in
# PowerShell 5.1 pipelines) and return the real exit code.
function Invoke-Flutter([scriptblock]$command) {
    & $command *> $logFile
    $code = $LASTEXITCODE
    Get-Content $logFile | ForEach-Object { Write-Host $_ }
    return $code
}

Step "flutter analyze"
Push-Location $root
try {
    $code = Invoke-Flutter { flutter analyze }
    if ($code -ne 0) {
        # flutter analyze prints lines like "   error • message • file:line";
        # only error-level findings fail the gate.
        $errors = Select-String -Path $logFile -Pattern '^\s*error\s*'
        if ($errors) {
            Write-Host "Found error-level findings:" -ForegroundColor Red
            $errors | ForEach-Object { Write-Host $_.Line -ForegroundColor Red }
            $failed = $true
        } else {
            Write-Host "Only info/warning level, treated as pass" -ForegroundColor Yellow
        }
    }
} finally {
    Pop-Location
}

Step "flutter test"
Push-Location $root
try {
    $code = Invoke-Flutter { flutter test }
    if ($code -ne 0) {
        Write-Host "Tests failed" -ForegroundColor Red
        $failed = $true
    }
} finally {
    Pop-Location
}

Remove-Item $logFile -ErrorAction SilentlyContinue

Write-Host ""
if ($failed) {
    Write-Host "FAILED: fix issues and rerun" -ForegroundColor Red
    exit 1
} else {
    Write-Host "PASS: full regression green" -ForegroundColor Green
    exit 0
}
