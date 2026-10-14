#!/usr/bin/env python3
"""Read-only preflight of public installer/index/checksum metadata, not canary."""
import argparse
import hashlib
import json
from pathlib import Path
import re
from urllib.request import urlopen
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]


def parse_sums(data):
    sums = {}
    for line in data.decode('utf-8').splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r'([0-9a-fA-F]{64})\s+\*?([^\s/]+)', line)
        if not match or match[2] in sums:
            raise ValueError('invalid or duplicate checksum metadata')
        sums[match[2]] = match[1].lower()
    if not sums:
        raise ValueError('empty checksum metadata')
    return sums


def audit(base, fetch=None, mode='indexed'):
    if mode not in {'direct', 'indexed'}:
        raise ValueError('unknown publication mode')
    def remote(path):
        with urlopen(base.rstrip('/') + '/' + path, timeout=15) as response:
            if urlsplit(response.url).scheme != 'https':
                raise ValueError('non-HTTPS redirect')
            content = response.read(1024 * 1024 + 1)
            if len(content) > 1024 * 1024:
                raise ValueError('metadata exceeds size bound')
            return content
    fetch = fetch or remote
    checks = []

    def check(path, validate):
        try:
            data = fetch(path)
            validate(data)
            checks.append({'path': path, 'ok': True})
            return data
        except Exception as exc:
            checks.append({'path': path, 'ok': False, 'error': str(exc)})
            return None

    installer = (ROOT / 'ddnsto/install.sh').read_bytes()
    digest = hashlib.sha256(installer).hexdigest()

    def verify_entry(data):
        if data != installer:
            raise ValueError('public entry does not match this checkout')

    check('ddnsto/install.sh', verify_entry)
    catalog = json.loads((ROOT / 'catalog.json').read_text())
    expected = [r for r in catalog['installers'] if r['application'] == 'ddnsto']

    def verify_config(data):
        config = json.loads(data)
        records = config.get('installers', [])
        for target in expected:
            matches = [r for r in records if all(r.get(k) == target[k] for k in ('application', 'os', 'package_manager', 'arch', 'path'))]
            if len(matches) != 1 or matches[0].get('sha256') != digest or matches[0].get('size') != len(installer):
                raise ValueError('missing/ambiguous/stale DDNSTO platform record')

    if mode == 'indexed':
        check('zsetup/config.json', verify_config)
    for path in sorted({r['path'] for r in expected}):
        check(path, verify_entry)
    if mode == 'direct':
        windows = (ROOT / 'ddnsto/install.ps1').read_bytes()
        def verify_windows(data):
            if data != windows:
                raise ValueError('PowerShell entry does not match this checkout')
        check('ddnsto/install.ps1', verify_windows)
        for path in sorted({str(Path(r['path']).with_name('install.ps1')) for r in expected}):
            check(path, verify_windows)

    def version(data):
        value = data.decode().strip()
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9._+-]+)?', value):
            raise ValueError('invalid version pointer')
        return value

    def require_sums(names):
        def validate(data):
            sums = parse_sums(data)
            if not set(names) <= sums.keys():
                raise ValueError('missing product checksum entries')
        return validate

    check('ddnsto/linux-binary/SHA256SUMS', require_sums(['ddnsto-standard-4.2.3.tar.gz']))
    for variant, pointer in [('standard', 'VERSION'), ('lite', 'VERSION_LITE')]:
        data = check('ddnsto/openwrt/' + pointer, version)
        if data is None:
            continue
        for ext, suffix in [('ipk', ''), ('apk', '-apk')]:
            names = [f'ddnsto_{arch}.{ext}' for arch in ('x86_64', 'aarch64', 'arm', 'mipsel')]
            names += [f'luci-app-ddnsto.{ext}', f'luci-i18n-ddnsto-zh-cn.{ext}']
            check(f'ddnsto/openwrt/{variant}{suffix}/{version(data)}/SHA256SUMS', require_sums(names))
    return {'base': base, 'mode': mode, 'publication_inputs_ready': all(c['ok'] for c in checks),
            'device_canary': 'not_checked', 'product_bytes': 'not_downloaded', 'checks': checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='https://fw.koolcenter.com/binary')
    parser.add_argument('--mode', choices=['direct', 'indexed'], default='indexed')
    args = parser.parse_args()
    parsed = urlsplit(args.base)
    if parsed.scheme != 'https' or not parsed.netloc or parsed.username or parsed.query or parsed.fragment:
        parser.error('base must be an HTTPS URL without credentials/query/fragment')
    result = audit(args.base, mode=args.mode)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result['publication_inputs_ready'] else 1)


if __name__ == '__main__':
    main()
