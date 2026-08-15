from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MINIMUM_SOURCE_LOC = 3_500
MAXIMUM_SOURCE_LOC = 5_200


def source_nonblank_loc() -> int:
    count = 0
    for path in sorted((ROOT / "src").rglob("*.vy")):
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                count += 1
    return count


def main() -> int:
    count = source_nonblank_loc()
    print(f"src nonblank executable LOC: {count}")
    if not MINIMUM_SOURCE_LOC <= count <= MAXIMUM_SOURCE_LOC:
        raise SystemExit(f"src LOC outside [{MINIMUM_SOURCE_LOC}, {MAXIMUM_SOURCE_LOC}]: {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
