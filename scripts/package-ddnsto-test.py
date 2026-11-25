#!/usr/bin/env python3
"""Prepare an isolated DDNSTO test distribution. Never uploads or alters apps/."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

import build

ROOT = Path(__file__).resolve().parents[1]


def prepare(output, base_url):
    url = urlsplit(base_url)
    if (url.scheme != 'https' or not url.hostname or url.username or url.password or
            url.query or url.fragment or not re.fullmatch(r'https://[A-Za-z0-9.:/_-]+', base_url)):
        raise ValueError('base URL must be a plain HTTPS distribution directory')
    base_url = base_url.rstrip('/')
    output = output.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError('choose a new candidate directory; overwriting is forbidden')
    for command in ('build-ddnsto-products.py', 'build.py'):
        subprocess.run([sys.executable, '-B', str(ROOT / 'scripts' / command), '--check'], check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.ddnsto-test-', dir=output.parent) as directory:
        stage = Path(directory) / 'candidate'
        shutil.copytree(ROOT / 'apps/ddnsto', stage / 'ddnsto')
        (stage / 'zsetup').mkdir()
        for name in ('base.json', 'base-windows.json'):
            shutil.copy2(ROOT / 'apps/zsetup' / name, stage / 'zsetup' / name)
        applications = build.discover(stage)
        build.generate_entries(ROOT, applications, check=False, distribution_url=base_url)
        for windows in (False, True):
            build.generate_config(stage, applications, check=False, windows=windows, distribution_url=base_url)
        build.generate_checksums(stage, check=False)
        # mkdir is exclusive, including against a concurrent preparation.
        output.mkdir()
        for child in stage.iterdir():
            shutil.move(str(child), str(output / child.name))
    print(f'Test entry: {base_url}/ddnsto/install.sh; not deployed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--base-url', required=True)
    args = parser.parse_args()
    try:
        prepare(args.output, args.base_url)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')
