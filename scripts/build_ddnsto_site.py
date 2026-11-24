"""Generate console resources into apps/ddnsto; no release approval or upload."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile


def generate(root: Path, apps: Path, *, check: bool, install_file):
    app = apps / 'ddnsto'
    if not app.is_dir() or not (apps.parent / 'sources/ddnsto').is_dir():
        return
    version = json.loads((root / 'sources/ddnsto/app.json').read_text())['version']
    # Reuse the existing recommendation format, bounded wrappers and digest
    # inventory. Build-time hashes establish consistency, not human approval.
    spec = importlib.util.spec_from_file_location('ddnsto_site', root / 'scripts/package-ddnsto-site.py')
    site = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(site)
    with tempfile.TemporaryDirectory(prefix='ddnsto-site-build-') as directory:
        output = Path(directory) / 'site'
        site.package_site(argparse.Namespace(
            output=output, native_first=False,
            reviewed_shell_sha256=hashlib.sha256((app / version / 'installer.sh').read_bytes()).hexdigest(),
            reviewed_powershell_sha256=hashlib.sha256((root / 'sources/ddnsto/install.ps1').read_bytes()).hexdigest()))
        for source in sorted(output.rglob('*')):
            if not source.is_file() or source == output / 'SHA256SUMS' or source.name == 'review.json':
                continue
            relative = source.relative_to(output)
            target = app / relative
            immutable = 'immutable' in relative.parts or 'versions' in relative.parts
            if immutable and target.exists() and target.read_bytes() != source.read_bytes():
                raise ValueError(f'conflicting DDNSTO immutable resource: {target}')
            install_file(target, source.read_bytes(), executable=False, check=check,
                         label='DDNSTO console resource')
    # Never prune old digest paths: copied commands and rollback need them.
