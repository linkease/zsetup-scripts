#!/usr/bin/env python3
"""Stage DDNSTO direct entries; use published zsetup, not native source tools.

Does not publish, activate indexes, or certify native device support.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='new dedicated candidate directory; never overwritten')
    args = parser.parse_args()
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error('output already exists; choose a new candidate directory')
    subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/build-entrypoints.py'), '--check'], check=True)
    catalog = json.loads((ROOT / 'catalog.json').read_text())
    paths = {r['path'] for r in catalog['installers'] if r['application'] == 'ddnsto'}
    if len(paths) != 1:
        raise ValueError('DDNSTO needs one immutable shell entry')
    version_dir = Path(next(iter(paths))).parent
    if len(version_dir.parts) != 2 or version_dir.parts[0] != 'ddnsto' or version_dir.parts[1] in {'.', '..', 'stable', 'latest'}:
        raise ValueError('invalid immutable directory')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.ddnsto-entries-', dir=output.parent) as tmp:
        staging = Path(tmp) / 'candidate'
        for name in ('install.sh', 'install.ps1'):
            for directory in (Path('ddnsto'), version_dir):
                target = staging / 'binary' / directory / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / 'ddnsto' / name, target)
        # Audit metadata travels with the candidate, never fetched as executable
        # policy at runtime. Each public entry remains standalone.
        shutil.copy2(ROOT / 'ddnsto/install-rules.json', staging / 'binary' / version_dir / 'install-rules.json')
        files = [{'path': str(p.relative_to(staging)), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'size': p.stat().st_size}
                 for p in sorted(staging.rglob('*')) if p.is_file()]
        manifest = {'schema_version': 1, 'config_version': catalog['config_version'],
                    'scope': 'ddnsto-direct-entrypoints-only', 'readiness': 'candidate-not-published',
                    'includes_native_or_products': False, 'files': files}
        (staging / 'entrypoints-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        sums = ''.join(f"{r['sha256']}  {r['path']}\n" for r in files)
        (staging / 'SHA256SUMS').write_text(sums)
        # Refuse any overwrite, even if another process created output meanwhile.
        output.mkdir()
        for child in staging.iterdir():
            shutil.move(str(child), str(output / child.name))
    print(f'DDNSTO direct-entry candidate: {output}; not published or canary-verified')


if __name__ == '__main__':
    main()
