#!/usr/bin/env python3
"""Build the portable jq installer from reviewed release metadata, without binaries."""
import argparse
import base64
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def build(lock):
    assert lock['schemaVersion'] == 1
    version = lock['version']
    assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version)
    table = 'jq_release_artifact() {\n    jq_version=' + version + '\n    case "$1:$2" in\n'
    for selector, a in sorted(lock['artifacts'].items()):
        assert re.fullmatch(r'(linux|macos|windows):[a-z0-9]+', selector)
        assert re.fullmatch(r'jq-[a-z0-9.-]+', a['name'])
        assert re.fullmatch(r'[a-f0-9]{64}', a['sha256'])
        assert type(a['size']) is int and 0 < a['size'] <= 4*1024*1024
        assert a['url'] == f"https://github.com/jqlang/jq/releases/download/jq-{version}/{a['name']}"
        table += f"        {selector}) jq_artifact={a['name']}; jq_sha={a['sha256']}; jq_size={a['size']}; jq_url={a['url']} ;;\n"
    table += '        *) return 2 ;;\n    esac\n}\n'
    return ('#!/bin/sh\nset -eu\n' + (ROOT/'lib/bootstrap.sh').read_text() + '\n' + table + '\n' +
            (ROOT/'jq/business.sh').read_text() + '\n' + (ROOT/'jq/main.sh').read_text())


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--lock', type=Path, default=ROOT/'jq/artifacts.lock.json')
    p.add_argument('--output-dir', type=Path, default=ROOT/'jq')
    p.add_argument('--check', action='store_true')
    a = p.parse_args()
    content = build(json.loads(a.lock.read_text()))
    bridge=(ROOT/'jq/windows.ps1').read_text().replace('@JQ_BASH_PAYLOAD@',base64.b64encode(content.encode()).decode())
    for name, data in [('jq-install.sh', content), ('jq-install.ps1', bridge)]:
        target = a.output_dir/name
        if a.check:
            assert target.read_text() == data, 'stale jq entrypoint: '+name
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode='w', dir=target.parent, delete=False) as f:
                f.write(data); temporary = Path(f.name)
            temporary.chmod(0o755); temporary.replace(target)
    subprocess.run(['sh','-n',str(a.output_dir/'jq-install.sh')], check=True)


if __name__ == '__main__':
    main()
