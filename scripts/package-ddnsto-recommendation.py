#!/usr/bin/env python3
"""Build a LOCAL recommendation candidate; never upload, fetch or regenerate.

Review canonical ddnsto/ddnsto-install.sh and ddnsto/install.ps1, including their
embedded product pins, then supply both reviewed SHA256 values. The two hashes
are review acknowledgements, not a signing system or proof of device acceptance.

Example (replace hashes with values from the reviewed files):
  python3 -B scripts/package-ddnsto-recommendation.py \
    --source-url https://test.example/binary/ddnsto/recommendation \
    --reviewed-shell-sha256 HASH --reviewed-powershell-sha256 HASH \
    --output /absolute/new-candidate-directory

Serve the resulting directory at source-url only after separate approval.
Stage immutable files first, then atomically replace recommended-*.txt. Keep
old immutable files and stable entry URLs. Old copied entry bytes read the new
recommendation. The initially acquired wrapper itself needs a trusted channel.

Shell requires curl or HTTPS-capable GNU Wget with --no-config, plus
sha256sum/shasum/openssl; PowerShell uses Windows TLS
and SHA256. No executable is fetched to establish trust. Product/native download
and lifecycle stay in the canonical executors. No action is inserted: the core
defaults to ensure; explicit lifecycle flags remain available. This package does
NOT certify automatic same-account upgrade, no downgrade, or stable-running
exit 0. Those are executor acceptance gates before public activation. Arguments
are forwarded unchanged. Environment overrides of the executor remain its own
contract, not an alternate recommendation authority.

Offline cache is per source URL and user, with no freshness guarantee. It only
reuses complete metadata+script pairs; payload/native availability is separate.
Cache permissions defend against other users, not a compromised current user
or root. No crypto supply infrastructure or remote-code parser is introduced.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
MAX_SCRIPT = 8 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source_url(value):
    # Deliberately small grammar shared by both templates: no quoting, escapes,
    # credentials, query, fragment, percent encoding or path traversal.
    if not re.fullmatch(r'https://[A-Za-z0-9.-]+(?::[0-9]{1,5})?(?:/[A-Za-z0-9._-]+)*', value):
        raise ValueError('source URL must be a simple absolute HTTPS directory URL')
    parts = urlsplit(value)
    if not parts.hostname or any(p in ('.', '..') for p in parts.path.split('/')):
        raise ValueError('invalid source URL')
    if parts.port is not None and not 1 <= parts.port <= 65535:
        raise ValueError('invalid source port')
    return value


def package(args):
    base = source_url(args.source_url)
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError('output must not exist; preserve prior immutable releases')
    records = {}
    payloads = {}
    for platform, name, approval, extension in [
        ('shell', 'ddnsto-install.sh', args.reviewed_shell_sha256, 'sh'),
        ('powershell', 'install.ps1', args.reviewed_powershell_sha256, 'ps1'),
    ]:
        path = args.source_root / 'ddnsto' / name
        if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_SCRIPT:
            raise ValueError('canonical installer must be a bounded regular file')
        data = path.read_bytes()
        actual = digest(data)
        if not re.fullmatch('[0-9a-f]{64}', approval) or actual != approval:
            raise ValueError('reviewed hash differs from current canonical bytes')
        # Inventory only; approval covers the actual code and the meaning of its
        # pins. Never evaluate/source scripts to extract metadata.
        embedded = sorted(set(re.findall(r'(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])', data.decode('utf-8'))))
        if not embedded:
            raise ValueError('installer has no embedded digest inventory; review product pins')
        relative = f'immutable/{actual}/install.{extension}'
        records[platform] = dict(source=f'ddnsto/{name}', path=relative,
                                 sha256=actual, size=len(data), embedded_sha256=embedded)
        payloads[relative] = data
        payloads[f'recommended-{platform}.txt'] = (
            f'ddnsto-recommendation-v1-{platform}\n{actual}\n{len(data)}\n').encode('ascii')
        template = (ROOT / f'ddnsto/recommended-entry.{extension}').read_text()
        if extension == 'sh':
            template = template.replace('@@ASUS_STORAGE@@', (ROOT / 'ddnsto/asus-storage.sh').read_text())
        payloads[f'recommended-entry.{extension}'] = template.replace(
            '@@SOURCE_URL@@', base).replace('@@CACHE_KEY@@', digest(base.encode())).encode(
                'utf-8-sig' if extension == 'ps1' else 'utf-8')
    review = dict(schema=1, candidate_version=args.candidate_version,
                  published=False, source_url=base, installers=records,
                  lifecycle_acceptance='not-verified; canonical-executor-owned',
                  product_pins='embedded in the approved immutable installer bytes',
                  native_and_product_payloads_included=False)
    payloads['review.json'] = (json.dumps(review, indent=2, sort_keys=True) + '\n').encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.ddnsto-recommendation-', dir=output.parent))
    try:
        for relative, data in payloads.items():
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        # Candidate directory publication is a single local rename. No existing
        # file, canonical source, catalog or generator is rewritten.
        if output.exists() or output.is_symlink():
            raise ValueError('output appeared during packaging')
        stage.rename(output)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--source-url', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--reviewed-shell-sha256', required=True)
    parser.add_argument('--reviewed-powershell-sha256', required=True)
    parser.add_argument('--candidate-version', default='0.2.4', choices=['0.2.4'])
    args = parser.parse_args()
    try:
        package(args)
    except (OSError, ValueError) as error:
        parser.exit(2, f'打包失败：{error}；状态=未发布；下一步=核对审核摘要和输出目录；code=2\n')
    print('本地候选已生成；状态=未发布、生命周期未验收')


if __name__ == '__main__':
    main()
