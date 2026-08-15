$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root

$python = "python"
if (Test-Path -LiteralPath ".venv\Scripts\python.exe") {
    $python = ".venv\Scripts\python.exe"
}

& $python -m pip install -r requirements-dev.txt
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $python scripts\ci.py
exit $LASTEXITCODE
