#!/usr/bin/env python3
"""Prepare an offline run.ddnsto.com document root; never deploy or fetch.

Reuses the reviewed recommendation packager. Upload immutable bodies before
activating manifests/aliases. Preserve existing immutable files on the host.
"""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ORIGIN = 'https://run.ddnsto.com'


def package_site(args):
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError('output must not exist; preserve prior releases')
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.ddnsto-site-', dir=output.parent))
    try:
        spec = importlib.util.spec_from_file_location('recommendation', ROOT / 'scripts/package-ddnsto-recommendation.py')
        recommendation = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(recommendation)
        current = stage / 'ddnsto-install/current'
        recommendation.package(argparse.Namespace(
            source_root=ROOT, source_url=ORIGIN + '/ddnsto-install/current',
            output=current, reviewed_shell_sha256=args.reviewed_shell_sha256,
            reviewed_powershell_sha256=args.reviewed_powershell_sha256,
            candidate_version='0.2.4', native_first=args.native_first))
        for alias, entry in [('install.sh', 'recommended-entry.sh'), ('install.ps1', 'recommended-entry.ps1')]:
            shutil.copyfile(current / entry, stage / alias)
        guide = (ROOT / 'sources/ddnsto/agent/install.md').read_bytes()
        if b'installer.invalid' in guide or ORIGIN.encode() not in guide:
            raise ValueError('agent guide must use the published installation origin')
        guide_root = stage / 'ddnsto-install/agent'
        guide_root.mkdir(parents=True)
        (guide_root / 'install.md').write_bytes(guide)
        history = guide_root / 'versions' / hashlib.sha256(guide).hexdigest()
        history.mkdir(parents=True)
        (history / 'install.md').write_bytes(guide)
        checksums = []
        for path in sorted(stage.rglob('*')):
            if path.is_file():
                checksums.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + str(path.relative_to(stage)))
        (stage / 'SHA256SUMS').write_text('\n'.join(checksums) + '\n', encoding='ascii')
        # Public scripts/docs only. Private mkdtemp permissions are appropriate
        # during construction, not for a document root copied with rsync -a.
        for path in stage.rglob('*'):
            path.chmod(0o755 if path.is_dir() else 0o644)
        stage.chmod(0o755)
        if output.exists() or output.is_symlink():
            raise ValueError('output appeared during packaging')
        stage.rename(output)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--reviewed-shell-sha256', required=True)
    parser.add_argument('--reviewed-powershell-sha256', required=True)
    parser.add_argument('--native-first', action='store_true',
                        help='retain the separately reviewed native-first policy; not release approval')
    args = parser.parse_args()
    try:
        package_site(args)
    except (OSError, ValueError) as error:
        parser.exit(2, f'打包失败：{error}；未发布\n')
    print('独立安装站点本地候选已生成；未发布、未做公网或真机验收')


if __name__ == '__main__':
    main()
