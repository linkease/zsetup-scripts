#!/usr/bin/env python3
"""Read-only entry/index and opt-in pinned-product byte audit; never a canary."""
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


def remote_product(url):
    """Stream bounded artifacts into a hash, never retain or execute products."""
    digest = hashlib.sha256()
    size = 0
    with urlopen(url, timeout=30) as response:
        if urlsplit(response.url).scheme != 'https':
            raise ValueError('non-HTTPS redirect')
        while chunk := response.read(1024 * 1024):
            size += len(chunk)
            if size > 128 * 1024 * 1024:
                raise ValueError('product exceeds size bound')
            digest.update(chunk)
    return digest.hexdigest(), size


def audit(base, fetch=None, mode='indexed', verify_products=False, fetch_product=None):
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

    installer = (ROOT / 'ddnsto/ddnsto-install.sh').read_bytes()
    digest = hashlib.sha256(installer).hexdigest()

    def verify_entry(data):
        if data != installer:
            raise ValueError('public entry does not match this checkout')

    catalog = json.loads((ROOT / 'catalog.json').read_text())
    expected = [r for r in catalog['installers'] if r['application'] == 'ddnsto']
    if not expected:
        raise ValueError('catalog has no DDNSTO platform records')

    def verify_config(data):
        config = json.loads(data)
        records = config.get('installers', [])
        for target in expected:
            matches = [r for r in records if all(r.get(k) == target[k] for k in ('application', 'os', 'package_manager', 'arch', 'path'))]
            if len(matches) != 1 or matches[0].get('sha256') != digest or matches[0].get('size') != len(installer):
                raise ValueError('missing/ambiguous/stale DDNSTO platform record')

    if mode == 'indexed':
        check('zsetup/config.json', verify_config)
    windows = (ROOT / 'ddnsto/install.ps1').read_bytes()
    def verify_windows(data):
        if data != windows:
            raise ValueError('PowerShell entry does not match this checkout')
    directories = {'ddnsto'} | {str(Path(r['path']).parent) for r in expected}
    for directory in sorted(directories):
        for name in ('ddnsto-install.sh', 'install.sh'):
            check(directory + '/' + name, verify_entry)
        check(directory + '/install.ps1', verify_windows)
    entrypoints_ready = all(c['ok'] for c in checks)

    # This reviewed manifest covers native archives, OpenWrt packages and SPKs;
    # Docker registry images and real platform lifecycle acceptance are separate.
    product_state = 'not_downloaded'
    if verify_products:
        manifest = json.loads((ROOT / 'docs/ddnsto-artifacts-2026-11-03.json').read_text())
        products = [r for r in manifest['files']
                    if not r['source_path'].endswith(('VERSION', 'VERSION_LITE'))]
        if not products:
            raise ValueError('empty product manifest')
        # Fail closed if the evidence snapshot has fallen behind maintained
        # product pins. A historically valid download is not the current input.
        owners = {'linux-binary': 'product-pins.sh', 'openwrt': 'product-pins.sh',
                  'macOS': 'install-macos.sh', 'windows': 'install.ps1',
                  'synology': 'synology-download.sh'}
        sources = {name: (ROOT / 'ddnsto' / name).read_text() for name in set(owners.values())}
        fetch_product = fetch_product or (lambda path: remote_product(base.rstrip('/') + '/' + path))
        product_state = 'verified'
        for record in products:
            path = 'ddnsto/' + record['source_path']
            try:
                owner = owners[record['source_path'].split('/')[0]]
                if record['sha256'] not in sources[owner]:
                    raise ValueError('reviewed product manifest differs from current installer pins')
                digest_size = fetch_product(path)
                if digest_size != (record['sha256'], record['size']):
                    raise ValueError('product SHA256/size differs from reviewed manifest')
                checks.append({'path': path, 'ok': True})
            except Exception as exc:
                product_state = 'failed'
                checks.append({'path': path, 'ok': False, 'error': str(exc)})
    return {'base': base, 'mode': mode, 'entrypoints_ready': entrypoints_ready,
            'publication_inputs_ready': entrypoints_ready and product_state == 'verified',
            'device_canary': 'not_checked', 'product_bytes': product_state,
            'product_manifest': 'docs/ddnsto-artifacts-2026-11-03.json',
            'checks': checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='https://fw.koolcenter.com/binary')
    parser.add_argument('--mode', choices=['direct', 'indexed'], default='indexed')
    parser.add_argument('--verify-products', action='store_true',
                        help='stream all reviewed product archives and verify SHA256/size (no installation)')
    args = parser.parse_args()
    parsed = urlsplit(args.base)
    if parsed.scheme != 'https' or not parsed.netloc or parsed.username or parsed.query or parsed.fragment:
        parser.error('base must be an HTTPS URL without credentials/query/fragment')
    result = audit(args.base, mode=args.mode, verify_products=args.verify_products)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result['publication_inputs_ready'] else 1)


if __name__ == '__main__':
    main()
