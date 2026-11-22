#!/usr/bin/env python3
"""Build the portable jq installer from reviewed release metadata, without binaries."""
import argparse
import base64
import json
from pathlib import Path
import re
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parent
APP = SOURCE.parent
ROOT = Path(__file__).resolve().parents[3]


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
            (SOURCE/'business.sh').read_text() + '\n' + (SOURCE/'main.sh').read_text())


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--lock', type=Path, default=SOURCE/'artifacts.lock.json')
    p.add_argument('--output-dir', type=Path)
    p.add_argument('--check', action='store_true')
    a = p.parse_args()
    content = build(json.loads(a.lock.read_text()))
    bridge=(SOURCE/'windows.ps1').read_text().replace('@JQ_BASH_PAYLOAD@',base64.b64encode(content.encode()).decode())
    output_dir = a.output_dir
    names = ('jq-install.sh', 'jq-install.ps1')
    if output_dir is None:
        version = json.loads((APP / 'app.json').read_text())['version']
        output_dir = APP / version
        names = ('installer.sh', 'installer.ps1')
    for name, data in zip(names, (content, bridge)):
        target = output_dir/name
        if a.check:
            assert target.read_text() == data, 'stale jq entrypoint: '+name
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode='w', dir=target.parent, delete=False) as f:
                f.write(data); temporary = Path(f.name)
            temporary.chmod(0o755); temporary.replace(target)
    subprocess.run(['sh','-n',str(output_dir/names[0])], check=True)


if __name__ == '__main__':
    main()
