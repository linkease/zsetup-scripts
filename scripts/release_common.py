"""Shared maintainer hashing and immutable file-copy operations."""
import hashlib
import shutil


def digest(path):
    with path.open("rb") as stream:
        value = hashlib.file_digest(stream, "sha256").hexdigest()
    return value


def copy_immutable(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if not destination.is_file() or digest(source) != digest(destination):
            raise ValueError(f"immutable path has different bytes: {destination}")
    else:
        shutil.copy2(source, destination)
