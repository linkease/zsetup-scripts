#!/usr/bin/env python3
"""Compile reviewed per-platform product data. No network or device dependency."""
import argparse
import json
from pathlib import Path
import re
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = {'linux', 'openwrt', 'macos', 'windows', 'synology', 'asus'}
OUTPUTS = {'product-pins.sh', 'business.sh', 'managed-cli.sh',
           'install-macos.sh', 'install.ps1', 'auto-synology.sh',
           'synology-download.sh', 'asus-platform.sh', 'asus-package.sh',
           'asus-service.sh', 'asus-transaction.sh', 'install-rules.json'}
TOKEN = re.compile(r'@@([a-z][a-z0-9_]*\.[a-z][a-z0-9_]*)@@')
VERSION = r'(?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5})'


def render(root, config):
    source = root / 'sources/ddnsto'
    if not source.is_dir():
        source = root / 'ddnsto'
    if set(config) != {'schema_version', 'platforms'} or config['schema_version'] != 1:
        raise ValueError('unsupported product configuration schema')
    if set(config['platforms']) != PLATFORMS:
        raise ValueError('missing or unsupported platform')
    values = {}
    for platform, fields in config['platforms'].items():
        if 'client_version' not in fields:
            raise ValueError('missing client version: ' + platform)
        for field, value in fields.items():
            if not isinstance(value, str):
                raise ValueError('product values must be strings')
            if field == 'client_version' or (platform == 'macos' and field == 'legacy_client_version'):
                pattern = VERSION
            elif field == 'package_version':
                pattern = re.escape(fields['client_version']) + r'-[1-9][0-9]{0,5}'
            elif field.endswith('_sha256'):
                pattern = r'[0-9a-f]{64}'
            elif field.endswith('_size'):
                pattern = r'[1-9][0-9]{0,11}'
            else:
                raise ValueError('unknown product field: ' + field)
            if not re.fullmatch(pattern, value):
                raise ValueError('invalid product value: ' + platform + '.' + field)
            values[platform + '.' + field] = value
    outputs = {}
    used = set()
    if {p.name[:-3] for p in (source / 'templates').glob('*.in')} != OUTPUTS:
        raise ValueError('missing or unexpected product template')
    for path in sorted((source / 'templates').glob('*.in')):
        template = path.read_text()
        shared_marker = '@@SHARED_BOOTSTRAP@@'
        if shared_marker in template:
            bootstrap = ROOT / 'lib' / ('bootstrap.ps1' if path.suffixes[-2:] == ['.ps1', '.in'] else 'bootstrap.sh')
            template = template.replace(shared_marker, bootstrap.read_text().rstrip())
        def replace(match):
            key = match[1]
            if key not in values:
                raise ValueError('missing product value: ' + key)
            used.add(key)
            return values[key]
        content = TOKEN.sub(replace, template)
        if '@@' in content:
            raise ValueError('unresolved product token: ' + path.name)
        outputs[path.name[:-3]] = content
    if not outputs or used != set(values):
        raise ValueError('unused product fields or missing templates: ' + str(set(values) - used))
    return outputs


def generate(root=ROOT, check=False):
    source = root / 'sources/ddnsto'
    if not source.is_dir():
        source = root / 'ddnsto'
    config = json.loads((source / 'platform-releases.json').read_text())
    outputs = render(root, config)  # Validate everything before writing anything.
    for name, content in outputs.items():
        path = source / name
        if path.is_file() and path.read_text() == content:
            continue
        if check:
            raise ValueError('stale generated product source: ' + str(path))
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                         prefix='.product-', delete=False) as stream:
            stream.write(content)
            temporary = Path(stream.name)
        try:
            temporary.chmod(path.stat().st_mode & 0o777 if path.exists() else 0o644)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    generate(check=args.check)
