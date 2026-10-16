"""Persistent launchers via real HTTPS/native zsetup; products and PVE are stubs."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
NATIVE = str(Path(sys.argv[1]).resolve())
NATIVE_VERSION = subprocess.check_output([NATIVE, "--version"], text=True).strip().removeprefix("zsetup ")
sys.path.insert(0, str(ROOT / "tests"))
from tls_fixture import generate_certificate

class Handler(http.server.BaseHTTPRequestHandler):
    bodies = {}; counts = {}
    def do_GET(self):
        self.counts[self.path] = self.counts.get(self.path, 0) + 1
        body = self.bodies.get(self.path)
        if body is None: self.send_error(404); return
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *_): pass

# /projects is a real persistent filesystem, deliberately unlike container aufs
# or SSD build scratch. Only small isolated test products are installed here.
(ROOT / "dist").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="storage-launchers-", dir=ROOT / "dist") as name:
    root = Path(name); generate_certificate(root)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); tls.load_cert_chain(root / "server.crt", root / "server.key")
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever); thread.start()
    try:
        base = f"https://127.0.0.1:{server.server_port}/binary"
        fake = root / "fake"; fake.mkdir()
        for app in ["fastnet", "fastpve"]:
            folder = root / app; folder.mkdir(); home = folder / "home"; home.mkdir()
            prefix = folder / "中文 program"
            work = folder / "staging"
            product = b'#!/bin/sh\nif [ "${1:-}" = version ]; then exit "${VERSION_FAIL:-0}"; fi\nprintf "<%s>" "$@" > "$TEST_OUTPUT"\nexit "${PRODUCT_EXIT:-0}"\n'
            filename = "FastNet-1.2.3.amd64" if app == "fastnet" else "FastPVE-1.2.3"
            key = "FASTNET_AMD64_SHA256" if app == "fastnet" else "FASTPVE_SHA256"
            Handler.bodies[f"/binary/{app}/version.txt"] = f"VERSION=1.2.3\n{key}={hashlib.sha256(product).hexdigest()}\n".encode()
            Handler.bodies[f"/binary/{app}/{filename}"] = product
            script = ROOT / app / f"{app}-install.sh"
            entry = f"{app}/storage-test/{app}-install.sh"
            Handler.bodies[f"/binary/{entry}"] = script.read_bytes()
            config = folder / "config.json"
            config.write_text(json.dumps({"schema_version":1,"config_version":"storage-test","source_groups":[{"id":"fixture","primary_bases":[base]}],
                "stable_zsetup":{"version":NATIVE_VERSION,"source_group":"fixture","artifacts":[{"arch":"x86_64","path":"unused","sha256":"00"*32,"size":1}]},
                "installers":[{"application":app,"os":"*","package_manager":"*","arch":"*","source_group":"fixture","path":entry,"sha256":hashlib.sha256(script.read_bytes()).hexdigest(),"size":script.stat().st_size,"background":False,"min_version":NATIVE_VERSION}]}))
            stable = folder / "stable"; stable.write_text(NATIVE_VERSION + "\n")
            for command, body in [("id", "echo 0"), ("pveversion", "echo fixture")]:
                path = fake / command; path.write_text("#!/bin/sh\n" + body + "\n"); path.chmod(0o755)
            curl = fake / "curl"
            curl.write_text('''#!/bin/sh
out=; url=
while [ "$#" -gt 0 ]; do
 [ "$1" != -o ] || { shift; out=$1; shift; continue; }
 case "$1" in https://*) url=$1 ;; esac
 shift
done
case "$url" in */zsetup/stable) cp "$TEST_STABLE" "$out" ;; *) exit 97 ;; esac
''')
            curl.chmod(0o755)
            env = {**os.environ, "HOME": str(home), "PATH": f"{fake}:/usr/bin:/bin", "ZSETUP_INSTALLER_MODE": "1", "ZSETUP_BIN": NATIVE,
                   "ZSETUP_ARCH": "x86_64", "ZSETUP_PACKAGE_MANAGER": "apt", "ZSETUP_SOURCE_BASES": base,
                   "ZSETUP_CA_FILE": str(root / "ca.crt"), "ZSETUP_SOURCE_FALLBACK": "", "ZSETUP_WORK_DIR": str(work), "TEST_OUTPUT": str(folder / "args"),
                   "ZSETUP_CONFIG": str(config), "ZSETUP_CONFIG_CACHE": str(folder / "config-cache"), "ZSETUP_MANAGED_ROOT": str(folder / "managed"),
                   "ZSETUP_ROOT": str(folder / "bootstrap"), "ZSETUP_BOOTSTRAP_BASES": base, "TEST_STABLE": str(stable)}
            argv = ["sh", str(script), "--installer-prefix", str(prefix), "--installer-work-dir", str(work), "--", "中文 space", "", "--opaque"]
            result = subprocess.run(argv, env={**env, "ZSETUP_INSTALLER_MODE":"0"}, capture_output=True, text=True, timeout=10)
            assert result.returncode == 0, result
            binary = prefix / "versions/1.2.3/bin" / app
            assert binary.read_bytes() == product
            assert (prefix / "current").is_symlink()
            if app == "fastnet": assert (home / ".local/bin/fastnet").resolve() == binary
            assert not Handler.counts.get(f"/binary/{entry}"), "running script fetched itself"
            assert (folder / "args").read_text() == "<中文 space><><--opaque>"
            assert not list(work.iterdir()), list(work.iterdir())
            before = Handler.counts[f"/binary/{app}/{filename}"]
            indexed = [NATIVE, "install", app, "--foreground", "--", *argv[2:]]
            result = subprocess.run(indexed, env=env, capture_output=True, text=True, timeout=10)
            assert result.returncode == 0 and Handler.counts[f"/binary/{app}/{filename}"] == before, result
            assert Handler.counts[f"/binary/{entry}"] == 1
            result = subprocess.run(argv, env={**env, "PRODUCT_EXIT": "37"}, capture_output=True, text=True, timeout=10)
            assert result.returncode == 37, result
            # New version failure preserves the activated old version and lease cleanup.
            Handler.bodies[f"/binary/{app}/version.txt"] = Handler.bodies[f"/binary/{app}/version.txt"].replace(b"1.2.3", b"1.2.4")
            Handler.bodies[f"/binary/{app}/{filename.replace('1.2.3', '1.2.4')}"] = product
            result = subprocess.run(argv, env={**env, "VERSION_FAIL": "41"}, capture_output=True, text=True, timeout=10)
            assert result.returncode == 41 and (prefix / "current").resolve() == binary, result
            assert not (prefix / "versions/1.2.4").exists() and not list(work.iterdir())
            for version in ["1.2.4", "1.2.5"]:
                Handler.bodies[f"/binary/{app}/version.txt"] = f"VERSION={version}\n{key}={hashlib.sha256(product).hexdigest()}\n".encode()
                Handler.bodies[f"/binary/{app}/{filename.replace('1.2.3', version)}"] = product
                result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=10)
                assert result.returncode == 0, result
            assert {p.name for p in (prefix / "versions").iterdir()} == {"1.2.4", "1.2.5"}
            changed = product + b"# changed\n"
            Handler.bodies[f"/binary/{app}/version.txt"] = f"VERSION=1.2.5\n{key}={hashlib.sha256(changed).hexdigest()}\n".encode()
            Handler.bodies[f"/binary/{app}/{filename.replace('1.2.3', '1.2.5')}"] = changed
            result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=10)
            assert result.returncode == 11 and (prefix / "current").read_bytes() == product, result
            # Registry paths cannot redirect writes into somebody else's file.
            victim = folder / "victim"; victim.write_text("untouched")
            (prefix / ".managed").unlink(); (prefix / ".managed").symlink_to(victim)
            result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=10)
            assert result.returncode == 2 and victim.read_text() == "untouched", result
    finally:
        server.shutdown(); server.server_close(); thread.join()
print("Persistent launchers: real HTTPS, literal arguments, version activation, reuse, failure preservation and cleanup passed")
