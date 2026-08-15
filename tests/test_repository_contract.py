import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_DOCS = {
    "architecture.md",
    "auction-mechanics.md",
    "economic-model.md",
    "governance.md",
    "operations.md",
    "portfolio-risk.md",
    "sdk.md",
}


def test_repository_contains_exact_documentation_contract():
    assert {path.name for path in (ROOT / "docs").glob("*.md")} == EXPECTED_DOCS
    assert (ROOT / "README.md").read_text(encoding="utf-8").count("```mermaid") >= 4
    assert (ROOT / "SECURITY.md").is_file()


def test_release_version_is_synchronized():
    metadata = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    client = (ROOT / "sdk" / "carmine_client.py").read_text(encoding="utf-8")
    workflow = (ROOT / ".github" / "workflows" / "release-integrity.yml").read_text(
        encoding="utf-8"
    )

    assert metadata["project"]["version"] == "1.0.0"
    assert 'VERSION = "1.0.0"' in client
    assert 'test "$TAG" = "v1.0.0"' in workflow


def test_repository_verifier_accepts_public_tree():
    result = subprocess.run(
        [sys.executable, "scripts/verify_repository.py"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
