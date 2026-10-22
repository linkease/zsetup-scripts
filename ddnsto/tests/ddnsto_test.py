#!/usr/bin/env python3
"""Safe DDNSTO dual-entry/platform/cleanup tests against the real HTTPS downloader."""
import hashlib
import http.server
import io
import json
import os
import re
import signal
import time
from pathlib import Path
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
ZSETUP = Path(sys.argv[1]).resolve()
TUNNEL = Path(sys.argv[2]).resolve()
DIRECT_ONLY = "--direct-only" in sys.argv[3:]
SCRIPT = ROOT / "ddnsto/install.sh"
BINARY = b'''#!/bin/sh
if [ "${1:-}" = -v ]; then echo "DDNSTO fixture"; exit 0; fi
printf "%s\\n" "$@" >> "$TEST_LOG"
if [ "${1:-}" = stop ]; then exit "${STOP_FAIL:-0}"; fi
if [ "${1:-}" = uninstall ]; then exit 0; fi
if [ "${START_FAIL:-0}" != 0 ] && [ ! -f "$SERVICE_ACTIVE.failed-once" ]; then
    touch "$SERVICE_ACTIVE.failed-once"
    exit "$START_FAIL"
fi
if [ "${1:-}" = -u ]; then
    mkdir -p "$DDNSTO_LINUX_CONFIG_DIR"
    printf fixture-config > "$DDNSTO_LINUX_CONFIG_DIR/ddnsto-config.json"
fi
touch "$SERVICE_ACTIVE"
printf '{"addr":"127.0.0.1:18334","pid":111,"startedAt":"fixture"}' > "$DDNSTO_LINUX_CONFIG_DIR/.ddnsto_http_addr.json"
'''


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
    global SCRIPT
    assert SCRIPT.is_file(), "DDNSTO unified entry is missing"
    # Verify released bytes before even executing --version. Product fixture
    # checksums may change below; the fixed bootstrap pin must never change.
    native_digest = '9563b8442a75957792bb82a2d98a736142fc52be57dd2dc42005490096897617'
    payload = ZSETUP.read_bytes()
    assert hashlib.sha256(payload).hexdigest() == native_digest, 'fixture requires released zsetup 0.5.0 x86_64 bytes'
    version_output = subprocess.check_output([str(ZSETUP), "--version"], text=True)
    native_version = re.search(r"\b\d+\.\d+\.\d+\b", version_output).group(0)
    assert native_version == '0.5.0', version_output
    # Use a CA-signed end-entity certificate. Rust TLS correctly rejects a CA
    # certificate used as a server leaf, which the old native tolerated.
    cert_tmp = tempfile.TemporaryDirectory(prefix="installer-loopback-tls-")
    cert_dir = Path(cert_tmp.name)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=DDNSTO fixture CA", "-addext", "basicConstraints=critical,CA:TRUE",
                    "-keyout", str(cert_dir / "ca.key"), "-out", str(cert_dir / "ca.crt")],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
                    "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
                    "-addext", "basicConstraints=critical,CA:FALSE",
                    "-keyout", str(cert_dir / "server.key"), "-out", str(cert_dir / "server.csr")],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["openssl", "x509", "-req", "-in", str(cert_dir / "server.csr"),
                    "-CA", str(cert_dir / "ca.crt"), "-CAkey", str(cert_dir / "ca.key"),
                    "-set_serial", "2", "-days", "1", "-copy_extensions", "copy",
                    "-out", str(cert_dir / "server.crt")],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert_dir / "server.crt", cert_dir / "server.key")
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="ddnsto-contract-") as tmp:
            root = Path(tmp)
            base = f"https://127.0.0.1:{server.server_address[1]}/binary"
            bodies = Handler.bodies
            # Hostile mutable metadata must never be consulted by DDNSTO's
            # fixed bootstrap. Keep it available so accidental use is detected.
            bodies["/binary/zsetup/stable"] = b'99.0.0\n'
            bodies[f"/binary/zsetup/{native_version}/zsetup-linux-x86_64"] = payload
            bodies[f"/binary/zsetup/{native_version}/SHA256SUMS"] = ('0' * 64 + '  zsetup-linux-x86_64\n').encode()
            archive = io.BytesIO()
            with tarfile.open(fileobj=archive, mode="w:gz") as tar:
                member = tarfile.TarInfo("ddnsto-standard-4.2.3/ddnsto.x86_64")
                member.size = len(BINARY)
                member.mode = 0o755
                tar.addfile(member, io.BytesIO(BINARY))
            bodies["/binary/ddnsto/linux-binary/ddnsto-standard-4.2.3.tar.gz"] = archive.getvalue()
            for variant in ("lite", "standard"):
                version = '4.2.2' if variant == 'lite' else '4.2.6'
                for ext in ("ipk", "apk"):
                    folder = variant + ("-apk" if ext == "apk" else "")
                    prefix = f"/binary/ddnsto/openwrt/{folder}/{version}/"
                    names = [f"ddnsto_{arch}.{ext}" for arch in ("x86_64", "aarch64", "arm", "mipsel")]
                    for name in names:
                        bodies[prefix + name] = b"package-fixture"
                    for name in [f'luci-app-ddnsto.{ext}', f'luci-i18n-ddnsto-zh-cn.{ext}']:
                        bodies['/binary/ddnsto/openwrt/' + name] = b'package-fixture'
            # Patch only pinned product bytes in a private fixture copy. No
            # runtime checksum bypass or test-only switch exists in production.
            source = SCRIPT.read_text()
            history = json.loads((ROOT / 'docs/ddnsto-artifacts-2026-10-08.json').read_text())
            for item in history['files']:
                path = '/binary/ddnsto/' + item['source_path']
                if path in bodies:
                    source = source.replace(item['sha256'], hashlib.sha256(bodies[path]).hexdigest())
            assert native_digest in source, 'product fixture must preserve the released bootstrap pin'
            SCRIPT = root / 'install.sh'
            SCRIPT.write_text(source)
            bodies['/binary/ddnsto/install.sh'] = source.encode()
            bindir = root / "bin"
            bindir.mkdir()
            for dependency in ("awk", "sed"):
                executable(bindir / dependency, '#!/bin/sh\nprintf "forbidden dependency\\n" >&2\nexit 99\n')
            package_manager = r'''#!/usr/bin/env python3
import os
import json
from pathlib import Path
import sys
name = Path(sys.argv[0]).name
args = sys.argv[1:]
fixture = Path(os.environ['OPENWRT_FIXTURE']).resolve()
database = fixture / 'package-db.json'
packages = json.loads(database.read_text())
if args in (['list-installed'], ['info']):
    print('\n'.join(p + ' - 0-fixture' if name == 'opkg' else p for p in packages))
    sys.exit(0)
if args[:2] == ['info', '-e']:
    sys.exit(0 if args[2] in packages else 1)
if args[:1] == ['search'] or '--who-owns' in args:
    managed = [os.environ[key] for key in ('DDNSTO_OPENWRT_BIN_PATH', 'DDNSTO_CONFIG_PATH', 'DDNSTO_SERVICE_PATH')]
    if 'ddnsto' not in packages or args[-1] not in managed or not Path(args[-1]).is_file():
        sys.exit(1)
    print('ddnsto - 0-fixture' if name == 'opkg' else 'ddnsto')
    sys.exit(0)
assert args[:1] in (['update'], ['install'], ['add'], ['remove'], ['del']), args
with Path(os.environ['TEST_LOG']).open('a') as log:
    log.write(name + ' ' + ' '.join(sys.argv[1:]) + '\n')
if sys.argv[1:2] not in (['install'], ['add']):
    sys.exit(0)
if os.environ.get('PKG_FAIL', '0') != '0':
    sys.exit(23)
package = Path(args[-1]).name
if package.endswith(('.ipk', '.apk')):
    package = package.rsplit('.', 1)[0]
if package.startswith('ddnsto_'):
    package = 'ddnsto'
if package not in packages:
    packages.append(package)
database.write_text(json.dumps(packages))
# Only the simulated DDNSTO package creates installed state. Dependency/LuCI
# packages do not pre-create a partial installation for the next test case.
if not any(Path(arg).name.startswith('ddnsto_') and arg.endswith(('.ipk', '.apk')) for arg in sys.argv[2:]):
    sys.exit(0)
for variable, content in (
    ('DDNSTO_OPENWRT_BIN_PATH', '#!/bin/sh\necho "DDNSTO fixture"\n'),
    ('DDNSTO_CONFIG_PATH', "config ddnsto\n option enabled '0'\n option index '0'\n"),
    ('DDNSTO_SERVICE_PATH', '#!/bin/sh\nprintf "service %s\\n" "$*" >> "$TEST_LOG"\n'),
):
    path = Path(os.environ[variable])
    assert path.resolve().is_relative_to(fixture), 'package write outside isolated case'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o600 if variable == 'DDNSTO_CONFIG_PATH' else 0o700)
'''
            executable(bindir / "opkg", package_manager)
            executable(bindir / "apk", package_manager)
            executable(bindir / "ddnsto", '#!/bin/sh\necho "DDNSTO fixture"\n')
            executable(bindir / "uci", r'''#!/usr/bin/env python3
import os
from pathlib import Path
import re
import sys
args = sys.argv[1:]
folder = Path(os.environ['DDNSTO_CONFIG_PATH']).parent
while args and args[0].startswith('-'):
    flag = args.pop(0)
    if flag in ('-c', '-t'):
        value = args.pop(0)
        if flag == '-c': folder = Path(value)
    else:
        assert flag == '-q', flag
path = folder / 'ddnsto'
assert path.resolve().is_relative_to(Path(os.environ['OPENWRT_FIXTURE']).resolve())
command = args[0]
if command == 'changes': sys.exit(0)
if not path.is_file(): sys.exit(1)
content = path.read_text()
if command == 'get':
    key = args[1]
    if key in ('ddnsto.@ddnsto[0]', 'ddnsto.@ddnsto[1]'):
        if content.count('config ddnsto') <= int(key[-2]): sys.exit(1)
        print('ddnsto'); sys.exit(0)
    match = re.search(r"option " + re.escape(key.split('.')[-1]) + r" '([^']*)'", content)
    if not match: sys.exit(1)
    print(match.group(1)); sys.exit(0)
assert command in ('set', 'commit'), command
with Path(os.environ['TEST_LOG']).open('a') as log:
    log.write('uci ' + ' '.join(args) + '\n')
if command == 'set':
    key, value = args[1].split('=', 1)
    key = key.split('.')[-1]
    line = "option " + key + " '" + value + "'"
    content, count = re.subn(r"option " + re.escape(key) + r" '[^']*'", lambda _: line, content)
    if not count: content += ' ' + line + '\n'
    path.write_text(content)
''')
            executable(bindir / "service", '#!/bin/sh\nprintf "service %s\\n" "$*" >> "$TEST_LOG"\n')
            executable(bindir / "pgrep", '#!/bin/sh\nexit 0\n')
            executable(bindir / "wget", '#!/bin/sh\nexit 97\n')
            # Bootstrap must see real filesystem ownership. Only business
            # privilege escalation is simulated; never elevate the host user.
            executable(bindir / "sudo", '#!/bin/sh\n[ "${1:-}" != -v ] || exit 0\nexec "$@"\n')
            # Indexed OpenWrt package tests bypass shell bootstrap and require
            # root to reach the fake package managers. Direct/bootstrap paths
            # retain the actual UID and all cache ownership/hash checks.
            executable(bindir / "id", '''#!/bin/sh
if [ "${1:-}" = -u ] && [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ] && [ "${ZSETUP_OS:-}" = openwrt ]; then
    printf '0\n'
else
    exec /usr/bin/id "$@"
fi
''')
            executable(bindir / "readlink", '#!/bin/sh\ncase "$1" in /proc/111/exe) printf "%s" "$DDNSTO_BIN_PATH" ;; *) /usr/bin/readlink "$@" ;; esac\n')
            executable(bindir / "systemctl", '''#!/bin/sh
case "$1" in
show-environment) exit 0 ;;
is-active) test -f "$SERVICE_ACTIVE" ;;
stop) [ "${STOP_FAIL:-0}" = 0 ] || exit "$STOP_FAIL"; rm -f "$SERVICE_ACTIVE" "$DDNSTO_LINUX_CONFIG_DIR/.ddnsto_http_addr.json" ;;
*) exit 1 ;;
esac
''')
            # Only shell bootstrap may fetch the fixed binary. Business
            # downloads use real zsetup with the local HTTPS fixture.
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
    case "$1" in http://127.0.0.1:18334/healthz) printf ok; exit 0 ;; https://*) url=$1 ;; esac
    shift
done
printf '%s\n' "$url" >> "$FETCH_LOG"
relative=${url#*://}; relative=${relative#*/}
cp "$BOOTSTRAP_WEB/$relative" "$out"
""")
            config = {
                "schema_version": 1, "config_version": "ddnsto-fixture-1",
                "source_groups": [{"id": "fixture", "primary_bases": [base]}],
                "stable_zsetup": {"version": native_version, "source_group": "fixture", "artifacts": [{"arch": "x86_64", "path": f"zsetup/{native_version}/zsetup-linux-x86_64", "sha256": hashlib.sha256(payload).hexdigest(), "size": len(payload)}]},
                "installers": [{"application": "ddnsto", "os": "*", "package_manager": "*", "arch": "*", "source_group": "fixture", "path": "ddnsto/install.sh", "sha256": hashlib.sha256(SCRIPT.read_bytes()).hexdigest(), "size": SCRIPT.stat().st_size, "background": False, "min_version": "0.2.4"}],
            }
            config_path = root / "config.json"
            config_path.write_text(json.dumps(config))
            env = os.environ | {
                "PATH": f"{bindir}:/usr/bin:/bin", "ZSETUP_BIN": str(ZSETUP),
                "ZSETUP_INSTALLER_MODE": "0",
                "ZSETUP_CA_FILE": str(cert_dir / "ca.crt"),
                "ZSETUP_SOURCE_BASES": base, "ZSETUP_SOURCE_FALLBACK": "",
                "ZSETUP_BOOTSTRAP_BASES": base, "ZSETUP_ROOT": str(root / "rescue"),
                "ZSETUP_WORK_DIR": str(root / "work"), "DDNSTO_BIN_PATH": str(root / "installed/ddnsto"),
                "DDNSTO_SERVICE_PATH": str(bindir / "service"), "DDNSTO_MEM_MB": "512",
                "DDNSTO_CONFIG_PATH": str(root / "legacy-config"),
                "DDNSTO_LOCK_DIR": str(root / "installer.lock"),
                "TEST_LOG": str(root / "log"), "FETCH_LOG": str(root / "fetch"),
                "BOOTSTRAP_WEB": str(bootstrap_web), "ZSETUP_CONFIG": str(config_path),
                "DDNSTO_LINUX_CONFIG_DIR": str(root / "service-config"), "SERVICE_ACTIVE": str(root / "service-active"),
                "ZSETUP_CONFIG_CACHE": str(root / "config-cache"), "ZSETUP_MANAGED_ROOT": str(root / "managed"),
            }
            # Guard the fixture's privilege boundary itself: simulating root
            # for indexed OpenWrt must never falsify bootstrap stat/UID checks.
            for mode, os_name, expected_uid in (
                ('0', 'openwrt', os.geteuid()),
                ('1', 'openwrt', 0),
                ('1', 'ubuntu', os.geteuid()),
            ):
                observed_uid = subprocess.check_output([str(bindir / 'id'), '-u'],
                    env=env | {'ZSETUP_INSTALLER_MODE': mode, 'ZSETUP_OS': os_name}, text=True).strip()
                assert observed_uid == str(expected_uid), (mode, os_name, observed_uid)
            (root / "installed").mkdir()
            (root / "rescue").mkdir(mode=0o700)
            def openwrt_fixture(overrides):
                # These are independent fresh-install matrix cases, not update
                # attempts. All managed paths must be absent at preflight; the
                # fake package manager materializes them only after verification.
                case = Path(tempfile.mkdtemp(prefix='openwrt-', dir=root))
                (case / 'package-db.json').write_text('[]')
                paths = {
                    'OPENWRT_FIXTURE': str(case),
                    'DDNSTO_OPENWRT_BIN_PATH': str(case / 'usr/sbin/ddnstod'),
                    'DDNSTO_CONFIG_PATH': str(case / 'etc/config/ddnsto'),
                    'DDNSTO_SERVICE_PATH': str(case / 'etc/init.d/ddnsto'),
                }
                assert all(not Path(path).exists() for key, path in paths.items() if key != 'OPENWRT_FIXTURE')
                return paths | overrides

            def run(args, overrides=None, indexed=False):
                if (overrides or {}).get('ZSETUP_OS') == 'openwrt':
                    overrides = openwrt_fixture(overrides)
                custom = env | (overrides or {})
                argv = [str(ZSETUP), "install", "ddnsto", "--foreground", "--"] if indexed and not DIRECT_ONLY else ["sh", str(SCRIPT)]
                result = subprocess.run(argv + args, env=custom, text=True, capture_output=True, timeout=60)
                return result
            token = "fixture token"
            openwrt_token = 'fixture-token'
            direct = run(["--token", token], {"ZSETUP_OS": "ubuntu", "ZSETUP_PACKAGE_MANAGER": "apt"})
            assert direct.returncode == 0, direct
            assert not (root / 'fetch').exists(), 'verified explicit native must not fetch metadata or binary'
            assert all(step in direct.stderr for step in ("[1/4]", "[2/4]", "[3/4]", "[4/4]")), direct.stderr
            assert "-u\nfixture token\n-daemon" in (root / "log").read_text()
            assert Handler.counts.get("/binary/ddnsto/install.sh", 0) == 0
            # A target with no installed native binary must bootstrap it itself.
            cold = run(["--action", "update"], {"ZSETUP_BIN": "", "ZSETUP_OS": "ubuntu", "ZSETUP_PACKAGE_MANAGER": "apt"})
            assert cold.returncode == 0, cold
            native_fetches = (root / 'fetch').read_text()
            assert native_fetches.splitlines() == [f'{base}/zsetup/0.5.0/zsetup-linux-x86_64'], native_fetches
            for directory in (root / 'rescue', root / 'rescue/bootstrap', root / 'rescue/rescue', root / 'rescue/rescue/0.5.0'):
                assert directory.stat().st_mode & 0o777 == 0o700, directory
            archive_path = "/binary/ddnsto/linux-binary/ddnsto-standard-4.2.3.tar.gz"
            count = Handler.counts[archive_path]
            listed = subprocess.run([str(ZSETUP), "install", "--list"], env=env, text=True, capture_output=True)
            assert listed.returncode == 0 and "ddnsto" in listed.stdout, listed
            indexed = run(["--action", "update"], indexed=True)
            assert indexed.returncode == 0, (indexed, Handler.counts,
                {str(p.relative_to(root)): p.read_text(errors="replace")[-4000:]
                 for p in (root / "managed").rglob("*") if p.is_file() and p.suffix in {".log", ".json"}})
            assert Handler.counts[archive_path] == count, "verified cache must be reused"
            assert "cached" in indexed.stderr, indexed.stderr
            installed = root / "installed/ddnsto"
            before = installed.read_bytes()
            start_failure = run(["--action", "update"], {"START_FAIL": "24"}, indexed=True)
            assert start_failure.returncode == 24 and "restoring previous binary" in start_failure.stderr, start_failure
            assert installed.read_bytes() == before
            stop_failure = run(["--action", "update"], {"STOP_FAIL": "25"}, indexed=True)
            assert stop_failure.returncode == 25, stop_failure
            assert installed.read_bytes() == before
            assert not list((root / "installed").glob(".ddnsto-backup.*"))
            for pm in ("opkg", "apk"):
                for arch in ("x86_64", "aarch64", "armv7", "mipsel"):
                    result = run(["--token", openwrt_token, "--force-version", "standard"], {"ZSETUP_INSTALLER_MODE": "1", "ZSETUP_OS": "openwrt", "ZSETUP_PACKAGE_MANAGER": pm, "ZSETUP_ARCH": arch})
                    assert result.returncode == 0, (pm, arch, result)
            lite = run([], {"ZSETUP_INSTALLER_MODE": "1", "ZSETUP_OS": "openwrt", "ZSETUP_PACKAGE_MANAGER": "opkg", "ZSETUP_ARCH": "x86_64"})
            assert lite.returncode == 0, lite
            assert "Lite" in lite.stderr, lite.stderr
            assert any("/lite/" in path for path in Handler.counts)
            # Business thresholds consume native facts; unknown memory preserves Standard.
            for memory, selected in (("899", "lite"), ("900", "standard"), ("unknown", "standard")):
                chosen = run([], {"ZSETUP_INSTALLER_MODE": "1", "ZSETUP_OS": "openwrt", "ZSETUP_PACKAGE_MANAGER": "opkg", "ZSETUP_ARCH": "x86_64", "DDNSTO_MEM_MB": "", "ZSETUP_MEMORY_TOTAL_MB": memory})
                assert chosen.returncode == 0 and f"Checking DDNSTO {selected} version" in chosen.stderr, chosen

            for args, override in ((["--token"], {}), (["--bogus"], {}), ([], {"ZSETUP_OS": "asuswrt", "ZSETUP_PACKAGE_MANAGER": "opkg"}), ([], {"ZSETUP_OS": "openwrt", "ZSETUP_PACKAGE_MANAGER": "opkg", "ZSETUP_ARCH": "mips"})):
                bad = run(args, {"ZSETUP_INSTALLER_MODE": "1"} | override)
                assert bad.returncode == 2, bad
            missing_token = run([], indexed=True)
            assert missing_token.returncode == 0 and 'operation=none' in missing_token.stdout, missing_token
            first_missing_token = run([], {"DDNSTO_BIN_PATH": str(root / 'fresh-client'),
                "DDNSTO_LINUX_CONFIG_DIR": str(root / 'fresh-config')}, indexed=True)
            assert first_missing_token.returncode == 2, first_missing_token
            # Published compatibility names execute the current installer and setup adapts its token argument.
            setup_env = env | openwrt_fixture({"ZSETUP_INSTALLER_MODE": "1", "ZSETUP_OS": "openwrt", "ZSETUP_PACKAGE_MANAGER": "opkg", "ZSETUP_ARCH": "x86_64"})
            setup_entry = root / "setup_ddnsto.sh"
            setup_entry.write_bytes(SCRIPT.read_bytes())
            setup = subprocess.run(["sh", str(setup_entry), openwrt_token], env=setup_env, text=True, capture_output=True, timeout=60)
            assert setup.returncode == 0, setup
            assert "uci set ddnsto.@ddnsto[0].token=" + openwrt_token in (root / "log").read_text()
            assert not list((root / "installed").glob(".ddnsto-backup.*"))
            # Kill shell while a business-owned dependency is waiting; its transaction must be reaped.
            blocked = root / "blocking-zsetup"
            executable(blocked, '#!/bin/sh\nif [ "${1:-}" = download ]; then : > "$BLOCK_READY"; sleep 1; exit 13; fi\nexit 97\n')
            ready = root / "ready"
            # Force a cold business download rather than the verified cache.
            env['ZSETUP_WORK_DIR'] = str(root / 'signal-work')
            proc = subprocess.Popen(["sh", str(SCRIPT), "--action", "update"], env=env | {"ZSETUP_INSTALLER_MODE": "1", "ZSETUP_OS": "ubuntu", "ZSETUP_PACKAGE_MANAGER": "apt", "ZSETUP_ARCH": "x86_64", "ZSETUP_BIN": str(blocked), "BLOCK_READY": str(ready)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            assert ready.exists()
            proc.send_signal(signal.SIGTERM)
            _out, _err = proc.communicate(timeout=5)
            assert proc.returncode == 143, (proc.returncode, _err)
            assert not list((root / "signal-work").glob(".transaction.*"))
            assert not (root / 'installer.lock').exists(), 'signal leaked operation lock'
            # Changed mutable LuCI bytes fail before any package manager mutation.
            path = '/binary/ddnsto/openwrt/luci-app-ddnsto.ipk'
            old_package = bodies[path]
            bodies[path] = b'changed-package'
            old_log = (root / "log").read_text()
            previous_requests = Handler.counts.get(path, 0)
            corrupt = run(["--force-version", "standard"], {"ZSETUP_INSTALLER_MODE": "1", "ZSETUP_OS": "openwrt", "ZSETUP_PACKAGE_MANAGER": "opkg", "ZSETUP_ARCH": "x86_64"})
            assert corrupt.returncode != 0, corrupt
            assert Handler.counts.get(path, 0) > previous_requests, 'corruption test must reach the real download verifier'
            assert (root / "log").read_text() == old_log
            bodies[path] = old_package
            failed = run(["--force-version", "standard"], {"ZSETUP_INSTALLER_MODE": "1", "ZSETUP_OS": "openwrt", "ZSETUP_PACKAGE_MANAGER": "opkg", "ZSETUP_ARCH": "x86_64", "PKG_FAIL": "23"})
            assert failed.returncode == 23, failed
            assert not list((root / "work").glob(".transaction.*"))
            assert not list((root / "installed").glob(".*candidate*"))
            assert not list((root / "rescue").rglob(".zsetup-download.*"))
            assert not any('/ddnsto/' in path and path.endswith(('VERSION', 'VERSION_LITE', 'SHA256SUMS')) for path in Handler.counts), Handler.counts
            assert (root / 'fetch').read_text() == native_fetches, 'bootstrap cache reuse must not fetch remote metadata'
            assert not any('/zsetup/' in path and path.endswith(('stable', 'SHA256SUMS')) for path in Handler.counts), Handler.counts
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=2)
        cert_tmp.cleanup()
    entries = "direct only (indexed path NOT tested)" if DIRECT_ONLY else "direct/index"
    print(f"DDNSTO: {entries}, opkg/apk x 4 arch, Linux, token, Lite/Standard, cache, progress and failures passed")


if __name__ == "__main__":
    main()
