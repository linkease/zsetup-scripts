#!/usr/bin/env python3
"""Collect the exact historical CDN layout through zsetup, without requiring upstream digests."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="collect-ddnsto-") as temporary:
    root = Path(temporary)
    web = root / "web"
    web.mkdir()
    files = {"openwrt/VERSION": b"4.2.6\n", "openwrt/VERSION_LITE": b"4.2.2\n"}
    for variant, version in (("standard", "4.2.6"), ("lite", "4.2.2")):
        for ext in ("ipk", "apk"):
            folder = variant + ("-apk" if ext == "apk" else "")
            for arch in ("x86_64", "aarch64", "arm", "mipsel"):
                files[f"openwrt/{folder}/{version}/ddnsto_{arch}.{ext}"] = b"fixture main package"
    for ext in ("ipk", "apk"):
        for name in ("luci-app-ddnsto", "luci-i18n-ddnsto-zh-cn"):
            files[f"openwrt/{name}.{ext}"] = b"fixture root UI package"
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        for arch in ("x86_64", "aarch64"):
            content = b"fixture, do not execute"
            member = tarfile.TarInfo(f"ddnsto-standard-4.2.3/ddnsto.{arch}")
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
    files["linux-binary/ddnsto-standard-4.2.3.tar.gz"] = stream.getvalue()
    for name, body in files.items():
        path = web / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(body)
    binary = root / "zsetup"
    binary.write_text('''#!/usr/bin/env python3
import os,json,sys,shutil
from pathlib import Path
args=sys.argv[1:]
if args == ['--version']:
 print('zsetup 0.2.4'); sys.exit(0)
assert args[0]=='download', args
with open(os.environ['COMMAND_LOG'],'a') as stream: stream.write(json.dumps(args)+'\\n')
output=Path(args[args.index('-o')+1])
url=next(value for value in args if value.startswith('https://dl.istoreos.com/'))
relative=url.split('/binary/ddnsto/',1)[1]
if relative==os.environ.get('FAIL_PATH'): sys.exit(13)
output.parent.mkdir(parents=True,exist_ok=True)
shutil.copyfile(Path(os.environ['WEB_ROOT'])/relative,output)
''')
    binary.chmod(0o755)
    output = root / "artifacts"
    env = os.environ | {"WEB_ROOT": str(web), "COMMAND_LOG": str(root / "commands")}
    command = ["python3", "-B", str(ROOT / "ddnsto/collect-artifacts.py"), "--zsetup-bin", str(binary), "--output", str(output)]
    subprocess.run(command, env=env, check=True)
    inventory = json.loads((output / "artifacts.json").read_text())
    assert len(inventory["files"]) == 27
    for record in inventory["files"]:
        assert hashlib.sha256((output / record["path"]).read_bytes()).hexdigest() == record["sha256"]
    for ext in ("ipk", "apk"):
        folder = "standard" + ("-apk" if ext == "apk" else "")
        assert (output / f"openwrt/{folder}/4.2.6/luci-app-ddnsto.{ext}").read_bytes() == files[f"openwrt/luci-app-ddnsto.{ext}"]
    commands = [json.loads(line) for line in (root / "commands").read_text().splitlines()]
    assert len(commands) == 23
    for args in commands:
        assert args[args.index('--fallback-url')+1].startswith('https://fw.koolcenter.com/')
        for primary in ('https://dl.istoreos.com/', 'https://fw.d4ctech.com/', 'https://fw20.koolcenter.com/'):
            assert any(value.startswith(primary) for value in args)
        assert not any(value.startswith('http://') for value in args)
    # One-command packaging composes collection and the existing config generator.
    zroot = root / "zsetup-root"
    (zroot / "dist/release").mkdir(parents=True)
    (zroot / "scripts").mkdir()
    checker = zroot / "scripts/check-release-artifacts.sh"
    checker.write_text("#!/bin/sh\nexit 0\n"); checker.chmod(0o755)
    original_generator = Path("/projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup/scripts/generate-product-config.py")
    (zroot / "scripts/generate-product-config.py").symlink_to(original_generator)
    release = zroot / "dist/release"
    records = []
    for arch in ("x86_64", "aarch64", "armv7", "mipsel"):
        name = f"zsetup-linux-{arch}"
        (release / name).write_bytes(binary.read_bytes()); (release / name).chmod(0o755)
        records.append({"name": name, "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "size": binary.stat().st_size})
    (release / "release-manifest.json").write_text(json.dumps({"version": "0.2.4", "source_commit": "fixture", "artifacts": records}))
    (release / "SHA256SUMS").write_text(''.join(f"{r['sha256']}  {r['name']}\n" for r in records))
    subprocess.run(["git", "init", "-q", str(zroot)], check=True)
    subprocess.run(["git", "-C", str(zroot), "add", "."], check=True)
    subprocess.run(["git", "-C", str(zroot), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "fixture"], check=True)
    package = root / "release"
    packaged = subprocess.run(["python3", "-B", str(ROOT / "scripts/package-release.py"), "--zsetup-root", str(zroot), "--collect-ddnsto", "--output", str(package)], env=env, capture_output=True, text=True)
    assert packaged.returncode == 0, packaged
    assert (package / "binary/ddnsto/openwrt/standard/4.2.6/SHA256SUMS").is_file()
    assert json.loads((package / "scripts-release-manifest.json").read_text())["readiness"] == "artifacts-verified-canary-required"
    before = (output / "artifacts.json").read_bytes()
    failed = subprocess.run(command, env=env | {"FAIL_PATH": "openwrt/standard/4.2.6/ddnsto_x86_64.ipk"}, capture_output=True)
    assert failed.returncode != 0
    assert (output / "artifacts.json").read_bytes() == before
    assert not list(root.glob('.ddnsto-collect-*'))
    # A changed mutable UI with unchanged main version cannot replace a previously captured snapshot.
    (web / "openwrt/luci-app-ddnsto.ipk").write_bytes(b"changed UI package")
    changed = subprocess.run(command, env=env, capture_output=True)
    assert changed.returncode != 0 and b"different bytes" in changed.stderr
    assert (output / "artifacts.json").read_bytes() == before
print("Legacy DDNSTO collection: URLs, versions, 27 files, digests, immutable snapshots and failure cleanup passed")
