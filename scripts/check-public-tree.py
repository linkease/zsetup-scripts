#!/usr/bin/env python3
"""Reject material that must never be copied with the public apps tree."""

import argparse
import os
from pathlib import Path
import re
import stat
import sys


SAFE_APP = re.compile(r"[a-z][a-z0-9-]{0,63}\Z")
RESERVED_DIRECTORIES = {"zsetup", "_shared"}
ROOT_FILES = {"README.md", "SHA256SUMS"}
FORBIDDEN_DIRECTORIES = {"test", "tests", "fixture", "fixtures", "__pycache__", ".git"}
FORBIDDEN_NAMES = {
    ".env", "authorization.json", "id_rsa", "id_ed25519", "known_hosts",
}
FORBIDDEN_SUFFIXES = {".key", ".pem", ".p12", ".pfx", ".log", ".pyc", ".tmp", ".swp"}
CONNECTION_PATTERNS = (
    re.compile(rb"(?m)^\s*ssh_target\s*="),
    re.compile(rb"(?m)^\s*ssh_port\s*="),
    re.compile(rb"(?m)^\s*deploy_base\s*=\s*/(?:mnt|home|srv|var)/"),
)


def fail(message: str):
    raise ValueError(message)


def validate(root: Path):
    if not root.is_dir() or root.is_symlink():
        fail("public apps root must be a real directory")
    for child in root.iterdir():
        if child.name in ROOT_FILES:
            if not child.is_file() or child.is_symlink():
                fail(f"unsafe public path: {child}")
            continue
        if not child.is_dir() or child.is_symlink():
            fail(f"unsafe public path: {child}")
        if child.name not in RESERVED_DIRECTORIES and not SAFE_APP.fullmatch(child.name):
            fail(f"unsafe public path: {child}")

    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directory = Path(current)
        for name in list(directories):
            path = directory / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                fail(f"symbolic link is forbidden in public apps tree: {path}")
            if not stat.S_ISDIR(mode):
                fail(f"special file is forbidden in public apps tree: {path}")
            if name.lower() in FORBIDDEN_DIRECTORIES:
                fail(f"test directory is forbidden in public apps tree: {path}" if "test" in name.lower()
                     else f"fixture directory is forbidden in public apps tree: {path}" if "fixture" in name.lower()
                     else f"private or transient file is forbidden in public apps tree: {path}")
        for name in files:
            path = directory / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                fail(f"symbolic link is forbidden in public apps tree: {path}")
            if not stat.S_ISREG(mode):
                fail(f"special file is forbidden in public apps tree: {path}")
            lowered = name.lower()
            if lowered in FORBIDDEN_NAMES or Path(lowered).suffix in FORBIDDEN_SUFFIXES:
                fail(f"private or transient file is forbidden in public apps tree: {path}")
            data = path.read_bytes()
            if any(pattern.search(data) for pattern in CONNECTION_PATTERNS):
                fail(f"production connection data is forbidden in public apps tree: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    try:
        validate(args.root)
    except (OSError, ValueError) as error:
        print(f"public tree: {error}", file=sys.stderr)
        return 1
    print(f"Public tree accepted: {args.root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

