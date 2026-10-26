"""Nested product installers through real HTTPS and native zsetup; no host services."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import signal
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
NATIVE = Path(sys.argv.pop(1)).resolve()
VERSION = subprocess.check_output([str(NATIVE), "--version"], text=True).strip().removeprefix("zsetup ")
sys.path.insert(0, str(ROOT / "tests"))
from tls_fixture import generate_certificate


class Handler(http.server.BaseHTTPRequestHandler):
    bodies = {}
    counts = {}
    slow = None
    started = threading.Event()

    def do_GET(self):
        self.counts[self.path] = self.counts.get(self.path, 0) + 1
        body = self.bodies.get(self.path)
        if body is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            if self.path == self.slow:
                self.started.set()
                for offset in range(0, len(body), 1024):
                    self.wfile.write(body[offset:offset + 1024])
                    self.wfile.flush()
                    time.sleep(0.03)
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

    def log_message(self, *_):
        pass


class BinaryInstall(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / "dist").mkdir(exist_ok=True)
        cls.tmp = tempfile.TemporaryDirectory(prefix="kspeeder-binaries-", dir=ROOT / "dist")
        cls.root = Path(cls.tmp.name)
        generate_certificate(cls.root)
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cls.root / "server.crt", cls.root / "server.key")
        cls.server.socket = tls.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever)
        cls.thread.start()
        cls.base = f"https://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.tmp.cleanup()

    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(dir=self.root))
        self.home = self.folder / "home"
        self.home.mkdir()
        self.prefix = self.folder / "中文 software"
        self.work = self.folder / "staging"
        self.marker = self.folder / "unexpected-command"
        Handler.bodies = {}
        Handler.counts = {}
        Handler.slow = None
        Handler.started.clear()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("ZSETUP_", "KSPEEDER_"))}
        self.env.update(HOME=str(self.home), ZSETUP_INSTALLER_MODE="1", ZSETUP_BIN=str(NATIVE),
                        ZSETUP_OS="ubuntu", ZSETUP_ARCH="x86_64", ZSETUP_SOURCE_BASES=self.base + "/binary",
                        ZSETUP_SOURCE_FALLBACK="", KSPEEDER_PRODUCT_BASES=self.base,
                        ZSETUP_CA_FILE=str(self.root / "ca.crt"), TEST_MARKER=str(self.marker))

    def product(self, app, version="1.2.3", reported=None, arch="amd64", body=None):
        if body is None:
            body = (f'#!/bin/sh\nif [ "${{1:-}}" = version ]; then printf "%s\\n" "{reported or version} commit=fixture"; exit 0; fi\n'
                    'printf "%s\\n" "$*" > "$TEST_MARKER"\nexit 93\n').encode()
        filename = f"ks-cli-linux-{arch}" if app == "ks-cli" else f"iStoreEnhance-linux.{arch}"
        metadata = "ks-cli-version.txt" if app == "ks-cli" else "version.txt"
        Handler.bodies[f"/bin/{metadata}"] = f"VERSION={version}\nSHA256_linux_{arch}={hashlib.sha256(body).hexdigest()}\n".encode()
        Handler.bodies[f"/bin/{filename}"] = body
        return filename, body

    def argv(self, app):
        return ["sh", str(ROOT / "kspeeder" / app / f"{app}-install.sh"),
                "--installer-prefix", str(self.prefix), "--installer-work-dir", str(self.work)]

    def run_install(self, app, code=0, extra=(), env=None):
        result = subprocess.run([*self.argv(app), *extra], env=self.env | (env or {}),
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertFalse(self.marker.exists(), "installer started the service or an arbitrary product command")
        return result

    def current(self):
        return self.prefix / "current"

    def test_both_products_install_only_and_native_index(self):
        for app in ("ks-cli", "kspeeder"):
            with self.subTest(app=app):
                self.setUp()
                _, body = self.product(app)
                self.run_install(app)
                binary = self.prefix / f"versions/1.2.3/bin/{app}"
                self.assertEqual(binary.read_bytes(), body)
                self.assertEqual((self.home / ".local/bin" / app).resolve(), binary)
                entry = ROOT / "kspeeder" / app / f"{app}-install.sh"
                path = f"{app}/0.1.0/{app}-install.sh"
                Handler.bodies[f"/binary/{path}"] = entry.read_bytes()
                config = self.folder / "config.json"
                config.write_text(json.dumps({"schema_version": 1, "config_version": "fixture",
                    "source_groups": [{"id": "fixture", "primary_bases": [self.base + "/binary"]}],
                    "stable_zsetup": {"version": VERSION, "source_group": "fixture", "artifacts": [
                        {"arch": "x86_64", "path": "unused", "sha256": "00" * 32, "size": 1}]},
                    "installers": [{"application": app, "os": "*", "package_manager": "*", "arch": "*",
                        "source_group": "fixture", "path": path, "sha256": hashlib.sha256(entry.read_bytes()).hexdigest(),
                        "size": entry.stat().st_size, "background": False, "min_version": VERSION}]}))
                result = subprocess.run([str(NATIVE), "install", app, "--foreground", "--", *self.argv(app)[2:]],
                    env=self.env | {"ZSETUP_CONFIG": str(config), "ZSETUP_CONFIG_CACHE": str(self.folder / "lkg"),
                                    "ZSETUP_MANAGED_ROOT": str(self.folder / "managed")}, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(binary.read_bytes(), body)
                self.assertFalse(self.marker.exists())
                self.assertFalse(list(self.work.iterdir()))

    def test_version_mismatch_and_digest_failure_preserve_old(self):
        self.product("ks-cli")
        self.run_install("ks-cli")
        old = self.current().resolve()
        self.product("ks-cli", "1.2.4", reported="9.9.9")
        self.run_install("ks-cli", 11)
        self.assertEqual(self.current().resolve(), old)
        self.assertFalse((self.prefix / "versions/1.2.4").exists())
        name, _ = self.product("ks-cli", "1.2.4")
        Handler.bodies[f"/bin/{name}"] = b"broken payload"
        self.run_install("ks-cli", 11)
        self.assertEqual(self.current().resolve(), old)
        self.assertFalse(list(self.work.iterdir()))

    def test_cache_is_rehashed_and_same_version_cannot_change_identity(self):
        name, body = self.product("ks-cli")
        self.run_install("ks-cli")
        binary = self.current().resolve()
        count = Handler.counts[f"/bin/{name}"]
        self.run_install("ks-cli")
        self.assertEqual(Handler.counts[f"/bin/{name}"], count)
        binary.write_bytes(body.replace(b"commit=fixture", b"commit=corrupt"))
        self.run_install("ks-cli")
        self.assertEqual(binary.read_bytes(), body)
        self.product("ks-cli", body=body + b"# changed\n")
        self.run_install("ks-cli", 11)
        self.assertEqual(binary.read_bytes(), body)

    def test_upgrade_keeps_previous_version(self):
        for version in ("1.2.3", "1.2.4", "1.2.5"):
            self.product("kspeeder", version)
            self.run_install("kspeeder")
        self.assertEqual({p.name for p in (self.prefix / "versions").iterdir()}, {"1.2.4", "1.2.5"})
        self.assertIn("1.2.4", os.readlink(self.prefix / "previous"))

    def test_unsupported_targets_and_business_args_do_not_download(self):
        self.product("ks-cli")
        for override in ({"ZSETUP_OS": "openwrt"}, {"ZSETUP_OS": "windows"}, {"ZSETUP_ARCH": "mipsel"}):
            self.run_install("ks-cli", 2, env=override)
        self.run_install("ks-cli", 2, extra=("--", "service", "install"))
        self.run_install("ks-cli", 2, extra=("--installer-scope", "system"))
        self.assertFalse(Handler.counts)

    def test_architecture_mapping(self):
        for arch, artifact in (("aarch64", "arm64"), ("armv7", "arm")):
            with self.subTest(arch=arch):
                self.setUp()
                name, _ = self.product("ks-cli", arch=artifact)
                self.run_install("ks-cli", env={"ZSETUP_ARCH": arch})
                self.assertEqual(Handler.counts[f"/bin/{name}"], 1)

    def test_missing_metadata_and_shell_text_are_not_executed(self):
        Handler.bodies["/bin/ks-cli-version.txt"] = b"VERSION=1.2.3\n"
        self.run_install("ks-cli", 11)
        Handler.bodies["/bin/ks-cli-version.txt"] = f'VERSION=$(touch {self.marker})\nSHA256_linux_amd64={"00" * 32}\n'.encode()
        self.run_install("ks-cli", 11)
        self.assertEqual(set(Handler.counts), {"/bin/ks-cli-version.txt"})

    def test_foreign_command_is_preserved(self):
        command = self.home / ".local/bin/ks-cli"
        command.parent.mkdir(parents=True)
        command.write_text("foreign installation")
        self.product("ks-cli")
        self.run_install("ks-cli", 2)
        self.assertEqual(command.read_text(), "foreign installation")
        self.assertFalse(Handler.counts)

    def test_cancellation_keeps_old_binary_and_cleans_transaction(self):
        self.product("ks-cli")
        self.run_install("ks-cli")
        old = self.current().resolve()
        body = b"#!/bin/sh\n" + b"#" * 262144
        name, _ = self.product("ks-cli", "1.2.4", body=body)
        Handler.slow = f"/bin/{name}"
        proc = subprocess.Popen(self.argv("ks-cli"), env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(Handler.started.wait(10))
            proc.send_signal(signal.SIGTERM)
            out, err = proc.communicate(timeout=15)
            self.assertEqual(proc.returncode, 143, out + err)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()
        self.assertEqual(self.current().resolve(), old)
        self.assertFalse(list(self.work.iterdir()))

    def test_help_is_offline(self):
        result = subprocess.run([*self.argv("ks-cli")[:2], "--help"], env=self.env | {"ZSETUP_INSTALLER_MODE": "0"},
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--installer-prefix", result.stdout)
        self.assertFalse(Handler.counts)

    def test_one_key_bootstrap_uses_same_logic_without_refetching_itself(self):
        self.product("ks-cli")
        Handler.bodies["/binary/zsetup/stable"] = (VERSION + "\n").encode()
        Handler.bodies[f"/binary/zsetup/{VERSION}/SHA256SUMS"] = (
            hashlib.sha256(NATIVE.read_bytes()).hexdigest() + "  zsetup-linux-x86_64\n").encode()
        entry = ROOT / "kspeeder/ks-cli/ks-cli-install.sh"
        result = subprocess.run(["sh", "-c", entry.read_text(), "ks-cli", *self.argv("ks-cli")[2:]],
            env=self.env | {"ZSETUP_INSTALLER_MODE": "0", "ZSETUP_ROOT": str(self.folder / "bootstrap"),
                "ZSETUP_BOOTSTRAP_BASES": self.base + "/binary", "CURL_CA_BUNDLE": str(self.root / "ca.crt")},
            capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.current().is_symlink())
        self.assertFalse(any("ks-cli-install.sh" in path for path in Handler.counts))
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
