#!/usr/bin/env python3
"""Assemble frozen application-owned recipe metadata; never bundle binaries."""
import argparse
import json
from pathlib import Path
import os
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
apps = {'linkspace': 'linkspace/backup-release.lock.json'}
value = {'schemaVersion': 1, 'software': {}}
for name, source in apps.items():
    recipe = json.loads((root / source).read_text())
    value['software'][name] = {**recipe, 'canonicalSource': source}
body = json.dumps(value, indent=2) + '\n'
target = root / 'software/releases.lock.json'
if args.check:
    assert target.read_text() == body, 'stale application recipe snapshot'
else:
    with tempfile.NamedTemporaryFile(mode='w', dir=target.parent, delete=False) as temporary:
        temporary.write(body)
        name = temporary.name
    os.chmod(name, 0o644)
    os.replace(name, target)
