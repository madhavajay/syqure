#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


def bump_version(current: str, kind: str) -> str:
    parts = current.strip().split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        raise SystemExit(f"invalid version: {current}")
    major, minor, patch = map(int, parts)
    if kind == "major":
        major += 1
        minor = 0
        patch = 0
    elif kind == "minor":
        minor += 1
        patch = 0
    elif kind == "patch":
        patch += 1
    else:
        raise SystemExit(f"unsupported bump kind: {kind}")
    return f"{major}.{minor}.{patch}"


def update_file(path: Path, pattern: str, repl: str) -> None:
    text = path.read_text()
    new_text, count = re.subn(pattern, repl, text, count=1, flags=re.M)
    if count != 1:
        raise SystemExit(f"failed to update version in {path}")
    path.write_text(new_text)


def sync_versions(version: str, root: Path) -> None:
    (root / "VERSION").write_text(version + "\n")
    update_file(root / "syqure" / "Cargo.toml", r'^version = ".*"$', f'version = "{version}"')
    update_file(root / "python" / "Cargo.toml", r'^version = ".*"$', f'version = "{version}"')
    update_file(root / "python" / "pyproject.toml", r'^version = ".*"$', f'version = "{version}"')


def main() -> None:
    parser = argparse.ArgumentParser(description="Syqure version helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    bump = sub.add_parser("bump", help="bump a semver string")
    bump.add_argument("--current", required=True)
    bump.add_argument("--kind", required=True, choices=["patch", "minor", "major"])

    sync = sub.add_parser("sync", help="sync VERSION + manifests to a version")
    sync.add_argument("--version", required=True)
    sync.add_argument("--root", default=".")

    pep = sub.add_parser("pep440", help="render a PEP 440-compatible version")
    pep.add_argument("--version", required=True)

    args = parser.parse_args()

    if args.cmd == "bump":
        print(bump_version(args.current, args.kind))
        return
    if args.cmd == "sync":
        sync_versions(args.version, Path(args.root).resolve())
        return
    if args.cmd == "pep440":
        print(args.version)
        return


if __name__ == "__main__":
    main()
