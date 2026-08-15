from __future__ import annotations

import re
import struct
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
EXPECTED_VERSION = "1.0.0"
FORBIDDEN_PUBLIC_TERMS = re.compile(
    r"\b(?:ctf|vulnerabilit(?:y|ies)|vulnerable|exploit(?:s|ed|ing)?|bugs?|"
    r"laborator(?:y|ies)|laboratorios?|vulnerabilidades?)\b",
    re.IGNORECASE,
)
TEXT_SUFFIXES = {".md", ".py", ".vy", ".json", ".toml", ".yaml", ".yml", ".sh", ".ps1"}


def tracked_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    files = []
    for relative in result.stdout.splitlines():
        path = ROOT / relative
        if path.is_file():
            files.append(path)
    return files


def verify_docs() -> None:
    docs = {path.name for path in (ROOT / "docs").glob("*.md")}
    if docs != EXPECTED_DOCS:
        raise AssertionError(f"expected exactly seven canonical docs, found {sorted(docs)}")
    for name in sorted(EXPECTED_DOCS):
        content = (ROOT / "docs" / name).read_text(encoding="utf-8")
        nonblank = sum(1 for line in content.splitlines() if line.strip())
        if nonblank < 45:
            raise AssertionError(f"docs/{name} is too shallow: {nonblank} nonblank lines")


def verify_metadata() -> None:
    metadata = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    if metadata["project"]["version"] != EXPECTED_VERSION:
        raise AssertionError("pyproject version mismatch")
    client = (ROOT / "sdk" / "carmine_client.py").read_text(encoding="utf-8")
    if f'VERSION = "{EXPECTED_VERSION}"' not in client:
        raise AssertionError("SDK version mismatch")


def verify_readme_and_security() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    security = (ROOT / "SECURITY.md").read_text(encoding="utf-8")
    if "![CarmineAuctionProtocol](./assets/banner.png)" not in readme:
        raise AssertionError("canonical banner reference missing")
    if readme.count("```mermaid") < 4:
        raise AssertionError("README requires at least four Mermaid diagrams")
    if "Production 1.0.0" not in readme or "Python 3.12" not in readme:
        raise AssertionError("README release contract incomplete")
    if "GitHub Security Advisory" not in security:
        raise AssertionError("private security reporting route missing")


def verify_banner() -> None:
    data = (ROOT / "assets" / "banner.png").read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise AssertionError("banner is not a canonical PNG")
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) != (1672, 941):
        raise AssertionError(f"banner dimensions mismatch: {width}x{height}")


def verify_public_language() -> None:
    excluded = {
        ROOT / "scripts" / "verify_repository.py",
        ROOT / "tests" / "private",
    }
    for path in tracked_files():
        if path in excluded or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        if "tests/private" in path.as_posix():
            raise AssertionError("private evidence must never be versioned")
        content = path.read_text(encoding="utf-8")
        match = FORBIDDEN_PUBLIC_TERMS.search(content)
        if match:
            relative = path.relative_to(ROOT)
            raise AssertionError(f"forbidden public term in {relative}: {match.group(0)}")


def verify_workflows() -> None:
    ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
    release = (ROOT / ".github" / "workflows" / "release-integrity.yml").read_text(encoding="utf-8")
    for expected in ("ubuntu-latest", "windows-latest", "actions/checkout@v7"):
        if expected not in ci:
            raise AssertionError(f"CI workflow missing {expected}")
    if "Production tag integrity" not in release or "release:" not in release:
        raise AssertionError("release integrity workflow incomplete")


def main() -> int:
    verify_docs()
    verify_metadata()
    verify_readme_and_security()
    verify_banner()
    verify_public_language()
    verify_workflows()
    print("Repository contract verified: 7 docs, version 1.0.0, canonical banner.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"repository verification failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
