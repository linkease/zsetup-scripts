#!/usr/bin/env python3
"""Safe DDNSTO dual-entry/platform/cleanup tests against the real HTTPS downloader."""
import hashlib
import http.server
import io
import json
import os
import signal
import time
from pathlib import Path
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
ZSETUP = Path(sys.argv[1]).resolve()
TUNNEL = Path(sys.argv[2]).resolve()
CERT = TUNNEL / "runtime-zig/third-part/mbedtls/framework/data_files"
SCRIPT = ROOT / "apps/ddnsto/install.sh"
BINARY = b'#!/bin/sh\nif [ "${1:-}" = -v ]; then echo "DDNSTO fixture"; exit 0; fi\nprintf "%s\\n" "$@" >> "$TEST_LOG"\nif [ "${1:-}" = -u ]; then exit "${START_FAIL:-0}"; fi\n'


def executable(path, content):
    path.write_text(content)
    path.chmod(0o755)


class Handler(http.server.BaseHTTPRequestHandler):
    bodies = {}
    counts = {}
    broken = set()
    def do_GET(self):
        cls = type(self)
        cls.counts[self.path] = cls.counts.get(self.path, 0) + 1
        body = cls.bodies.get(self.path)
        if self.path in cls.broken or body is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass


def main():
    assert SCRIPT.is_file(), "DDNSTO unified entry is missing"
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(CERT / "server5.crt", CERT / "server5.key")
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="ddnsto-contract-") as tmp:
            root = Path(tmp)
            base = f"https://localhost:{server.server_address[1]}/binary"
            bodies = Handler.bodies
            bodies["/binary/ddnsto/install.sh"] = SCRIPT.read_bytes()
            bodies["/binary/zsetup/stable"] = b"0.2.3\n"
            payload = ZSETUP.read_bytes()
            bodies["/binary/zsetup/0.2.3/zsetup-linux-x86_64"] = payload
            bodies["/binary/zsetup/0.2.3/SHA256SUMS"] = f"{hashlib.sha256(payload).hexdigest()}  zsetup-linux-x86_64\n".encode()
            archive = io.BytesIO()
            with tarfile.open(fileobj=archive, mode="w:gz") as tar:
                member = tarfile.TarInfo("ddnsto-standard-4.2.3/ddnsto.x86_64")
                member.size = len(BINARY)
                member.mode = 0o755
                tar.addfile(member, io.BytesIO(BINARY))
            bodies["/binary/ddnsto/linux-binary/ddnsto-standard-4.2.3.tar.gz"] = archive.getvalue()
            bodies["/binary/ddnsto/linux-binary/SHA256SUMS"] = f"{hashlib.sha256(archive.getvalue()).hexdigest()}  ddnsto-standard-4.2.3.tar.gz\n".encode()
            for variant in ("lite", "standard"):
                bodies[f"/binary/ddnsto/openwrt/{'VERSION_LITE' if variant == 'lite' else 'VERSION'}"] = b"4.2.3\n"
                for ext in ("ipk", "apk"):
                    folder = variant + ("-apk" if ext == "apk" else "")
                    prefix = f"/binary/ddnsto/openwrt/{folder}/4.2.3/"
                    names = [f"ddnsto_{arch}.{ext}" for arch in ("x86_64", "aarch64", "arm", "mipsel")]
                    names += [f"luci-app-ddnsto.{ext}", f"luci-i18n-ddnsto-zh-cn.{ext}"]
                    for name in names:
                        bodies[prefix + name] = b"package-fixture"
                    bodies[prefix + "SHA256SUMS"] = "".join(f"{hashlib.sha256(bodies[prefix+name]).hexdigest()}  {name}\n" for name in names).encode()
            bindir = root / "bin"
            bindir.mkdir()
            executable(bindir / "opkg", '#!/bin/sh\nprintf "opkg %s\\n" "$*" >> "$TEST_LOG"\n[ "${1:-}" != install ] || [ "${PKG_FAIL:-0}" = 0 ] || exit 23\n')
            executable(bindir / "apk", '#!/bin/sh\nprintf "apk %s\\n" "$*" >> "$TEST_LOG"\n[ "${1:-}" != add ] || [ "${PKG_FAIL:-0}" = 0 ] || exit 23\n')
            executable(bindir / "ddnsto", '#!/bin/sh\necho "DDNSTO fixture"\n')
            executable(bindir / "uci", '#!/bin/sh\nprintf "uci %s\\n" "$*" >> "$TEST_LOG"\n')
            executable(bindir / "service", '#!/bin/sh\nprintf "service %s\\n" "$*" >> "$TEST_LOG"\n')
            executable(bindir / "pgrep", '#!/bin/sh\nexit 0\n')
            executable(bindir / "wget", '#!/bin/sh\nexit 97\n')
            # Only shell bootstrap may fetch metadata/binary. Subsequent requests use real zsetup.
            bootstrap_web = root / "bootstrap-web"
            for path, data in bodies.items():
                if "/zsetup/" in path:
                    dest = bootstrap_web / path.lstrip("/")
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(data)
            executable(bindir / "curl", r"""#!/bin/sh
out=; url=
while [ "$#" -gt 0 ]; do
    [ "$1" != -o ] || { shift; out=$1; shift; continue; }
    case "$1" in https://*) url=$1 ;; esac
    shift
done
printf '%s\n' "$url" >> "$FETCH_LOG"
relative=${url#*://}; relative=${relative#*/}
cp "$BOOTSTRAP_WEB/$relative" "$out"
""")
            config = {
                "schema_version": 1, "config_version": "ddnsto-fixture-1",
                "source_groups": [{"id": "fixture", "primary_bases": [base]}],
                "stable_zsetup": {"version": "0.2.3", "source_group": "fixture", "artifacts": [{"arch": "x86_64", "path": "zsetup/unused", "sha256": "00"*32, "size": 1}]},
                "installers": [{"application": "ddnsto", "os": "*", "package_manager": "*", "arch": "*", "source_group": "fixture", "path": "ddnsto/install.sh", "sha256": hashlib.sha256(SCRIPT.read_bytes()).hexdigest(), "size": SCRIPT.stat().st_size, "background": False, "min_version": "0.2.3"}],
            }
            config_path = root / "config.json"
            config_path.write_text(json.dumps(config))
            env = os.environ | {
                "PATH": f"{bindir}:/usr/bin:/bin", "ZSETUP_BIN": str(ZSETUP),
                "ZSETUP_CA_FILE": str(CERT / "test-ca2.crt"),
                "ZSETUP_SOURCE_BASES": base, "ZSETUP_SOURCE_FALLBACK": "",
                "ZSETUP_BOOTSTRAP_BASES": base, "ZSETUP_ROOT": str(root / "rescue"),
                "ZSETUP_WORK_DIR": str(root / "work"), "DDNSTO_BIN_PATH": str(root / "installed/ddnsto"),
                "DDNSTO_SERVICE_PATH": str(bindir / "service"), "DDNSTO_MEM_MB": "512",
                "DDNSTO_CONFIG_PATH": str(root / "legacy-config"),
                "TEST_LOG": str(root / "log"), "FETCH_LOG": str(root / "fetch"),
                "BOOTSTRAP_WEB": str(bootstrap_web), "ZSETUP_CONFIG": str(config_path),
                "ZSETUP_CONFIG_CACHE": str(root / "config-cache"), "ZSETUP_MANAGED_ROOT": str(root / "managed"),
            }
            (root / "installed").mkdir()
            def run(args, overrides=None, indexed=False):
                custom = env | (overrides or {})
                argv = [str(ZSETUP), "install", "ddnsto", "--foreground", "--"] if indexed else ["sh", str(SCRIPT)]
                result = subprocess.run(argv + args, env=custom, text=True, capture_output=True, timeout=60)
                return result
            token = "fixture token"
            direct = run(["--token", token], {"ZSETUP_OS": "ubuntu", "ZSETUP_PACKAGE_MANAGER": "apt"})
            assert direct.returncode == 0, direct
            assert all(step in direct.stderr for step in ("[1/4]", "[2/4]", "[3/4]", "[4/4]")), direct.stderr
            assert "-u\nfixture token\n-daemon" in (root / "log").read_text()
            assert Handler.counts.get("/binary/ddnsto/install.sh", 0) == 0
            archive_path = "/binary/ddnsto/linux-binary/ddnsto-standard-4.2.3.tar.gz"
            count = Handler.counts[archive_path]
            indexed = run(["--token", token], indexed=True)
            assert indexed.returncode == 0, indexed
            assert Handler.counts[archive_path] == count, "verified cache must be reused"
            assert "cached" in indexed.stderr, indexed.stderr
            installed = root / "installed/ddnsto"
            before = installed.read_bytes()
            start_failure = run(["--token", token], {"START_FAIL": "24"}, indexed=True)
            assert start_failure.returncode == 24 and "restoring previous binary" in start_failure.stderr, start_failure
            assert installed.read_bytes() == before
            for pm in ("opkg", "apk"):
                for arch in ("x86_64", "aarch64", "armv7", "mipsel"):
                    result = run(["--token", token, "--force-version", "standard"], {"ZSETUP_INSTALLER_MODE": "1", "ZSETUP_OS": "openwrt", "ZSETUP_PACKAGE_MANAGER": pm, "ZSETUP_ARCH": arch})
                    assert result.returncode == 0, (pm, arch, result)
            lite = run([], {"ZSETUP_INSTALLER_MODE": "1", "ZSETUP_OS": "openwrt", "ZSETUP_PACKAGE_MANAGER": "opkg", "ZSETUP_ARCH": "x86_64"})
            assert lite.returncode == 0, lite
            assert "Lite" in lite.stderr, lite.stderr
            assert any("/lite/" in path for path in Handler.counts)
            for args, override in ((["--token"], {}), (["--bogus"], {}), ([], {"ZSETUP_OS": "asuswrt", "ZSETUP_PACKAGE_MANAGER": "opkg"}), ([], {"ZSETUP_OS": "openwrt", "ZSETUP_PACKAGE_MANAGER": "opkg", "ZSETUP_ARCH": "mips"})):
                bad = run(args, {"ZSETUP_INSTALLER_MODE": "1"} | override)
                assert bad.returncode == 2, bad
            missing_token = run([], indexed=True)
            assert missing_token.returncode == 2, missing_token
            # Root legacy names execute the same installer and setup adapts its token argument.
            setup_env = env | {"ZSETUP_INSTALLER_MODE": "1", "ZSETUP_OS": "openwrt", "ZSETUP_PACKAGE_MANAGER": "opkg", "ZSETUP_ARCH": "x86_64"}
            setup = subprocess.run(["sh", str(ROOT / "setup_ddnsto.sh"), token], env=setup_env, text=True, capture_output=True, timeout=60)
            assert setup.returncode == 0, setup
            assert "uci set ddnsto.@ddnsto[0].token=fixture token" in (root / "log").read_text()
            assert not list((root / "installed").glob(".ddnsto-backup.*"))
            # Kill shell while a business-owned dependency is waiting; its transaction must be reaped.
            blocked = root / "blocking-zsetup"
            executable(blocked, '#!/bin/sh\nif [ "${1:-}" = download ]; then : > "$BLOCK_READY"; sleep 1; exit 13; fi\nexit 97\n')
            ready = root / "ready"
            proc = subprocess.Popen(["sh", str(SCRIPT), "--token", token], env=env | {"ZSETUP_INSTALLER_MODE": "1", "ZSETUP_OS": "ubuntu", "ZSETUP_PACKAGE_MANAGER": "apt", "ZSETUP_ARCH": "x86_64", "ZSETUP_BIN": str(blocked), "BLOCK_READY": str(ready)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            assert ready.exists()
            proc.send_signal(signal.SIGTERM)
            _out, _err = proc.communicate(timeout=5)
            assert proc.returncode == 143, (proc.returncode, _err)
            assert not list((root / "work").glob(".transaction.*"))
            # Metadata checksum mismatch fails before any package manager mutation.
            prefix = "/binary/ddnsto/openwrt/standard/4.2.3/"
            old_sums = bodies[prefix + "SHA256SUMS"]
            bodies[prefix + "SHA256SUMS"] = old_sums.replace(hashlib.sha256(b"package-fixture").hexdigest().encode(), b"0"*64)
            old_log = (root / "log").read_text()
            corrupt = run(["--force-version", "standard"], {"ZSETUP_INSTALLER_MODE": "1", "ZSETUP_OS": "openwrt", "ZSETUP_PACKAGE_MANAGER": "opkg", "ZSETUP_ARCH": "x86_64"})
            assert corrupt.returncode != 0, corrupt
            assert (root / "log").read_text() == old_log
            bodies[prefix + "SHA256SUMS"] = old_sums
            failed = run(["--force-version", "standard"], {"ZSETUP_INSTALLER_MODE": "1", "ZSETUP_OS": "openwrt", "ZSETUP_PACKAGE_MANAGER": "opkg", "ZSETUP_ARCH": "x86_64", "PKG_FAIL": "23"})
            assert failed.returncode == 23, failed
            assert not list((root / "work").glob(".transaction.*"))
            assert not list((root / "installed").glob(".*candidate*"))
            assert not list((root / "rescue").rglob(".zsetup-download.*"))
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=2)
    print("DDNSTO: direct/index, opkg/apk x 4 arch, Linux, token, Lite/Standard, cache, progress and failures passed")


if __name__ == "__main__":
    main()
