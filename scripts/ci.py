import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*command: str) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=ROOT, check=True)


def main() -> int:
    python = sys.executable
    run(python, "scripts/generate_risk_tables.py")
    run(python, "-m", "ruff", "format", "--check", "sdk", "scripts", "tests")
    run(python, "-m", "ruff", "check", "sdk", "scripts", "tests")
    run(python, "-m", "pytest", "--ignore=tests/private", "--disable-warnings")
    run(python, "scripts/check_loc.py")
    run(python, "scripts/verify_repository.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
