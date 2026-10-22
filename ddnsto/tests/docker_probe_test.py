#!/usr/bin/env python3
"""Read-only Docker probe with isolated CLI and Unix socket boundaries."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DockerProbe(unittest.TestCase):
    def probe(self, endpoint=None, info='linux|x86_64|Ubuntu', context='', host='', fail=False):
        source = ROOT / 'ddnsto/docker-probe.sh'
        self.assertTrue(source.exists(), 'missing read-only Docker probe')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sock = socket.socket(socket.AF_UNIX)
            self.addCleanup(sock.close)
            sock.bind(str(root / 'docker.sock'))
            actual_endpoint = endpoint or 'unix://' + str(root / 'docker.sock')
            tool = root / 'docker'
            tool.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$PROBE_LOG"
case "$1" in
context) printf '%s\\n' "$PROBE_ENDPOINT" ;;
--host) [ "$3" = info ] || exit 99
    [ "$PROBE_FAIL" = 0 ] || exit 1
    printf '%s\\n' "$PROBE_INFO" ;;
*) exit 98 ;;
esac
''')
            tool.chmod(0o755)
            env = os.environ | dict(PATH=str(root) + ':/usr/bin:/bin', DOCKER_CONTEXT=context,
                DOCKER_HOST=host, PROBE_ENDPOINT=actual_endpoint, PROBE_INFO=info,
                PROBE_FAIL=str(int(fail)), PROBE_LOG=str(root / 'calls'))
            r = subprocess.run(['sh', '-eu', '-c', '. "$1"; ddnsto_probe_docker', 'test', str(source)],
                               env=env, text=True, capture_output=True, timeout=10)
            calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
            return r, calls

    def test_local_linux_engine_is_only_a_probe_not_install_support(self):
        r, calls = self.probe()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), 'local-linux-engine')
        self.assertIn('info', calls)
        self.assertNotIn('pull', calls)
        self.assertNotIn('run', calls)

    def test_remote_context_is_not_contacted(self):
        r, calls = self.probe(endpoint='ssh://private-server', context='remote')
        self.assertEqual(r.stdout.strip(), 'remote-endpoint')
        self.assertNotIn('info', calls)
        self.assertNotIn('private-server', r.stdout + r.stderr)

    def test_context_takes_precedence_over_host(self):
        r, calls = self.probe(endpoint='ssh://remote', context='selected', host='unix:///var/run/docker.sock')
        self.assertEqual(r.stdout.strip(), 'remote-endpoint')
        self.assertIn('selected', calls)

    def test_explicit_remote_host_not_contacted(self):
        r, calls = self.probe(host='tcp://127.0.0.1:2375')
        self.assertEqual(r.stdout.strip(), 'remote-endpoint')
        self.assertEqual(calls, '')

    def test_inaccessible_engine(self):
        r, _ = self.probe(fail=True)
        self.assertEqual(r.stdout.strip(), 'engine-unreachable')

    def test_desktop_not_treated_as_linux_host(self):
        r, _ = self.probe(info='linux|x86_64|Docker Desktop')
        self.assertEqual(r.stdout.strip(), 'desktop-engine-unverified')

    def test_windows_daemon_rejected(self):
        r, _ = self.probe(info='windows|x86_64|Windows Server')
        self.assertEqual(r.stdout.strip(), 'unsupported-engine')

    def test_nonexistent_unix_socket(self):
        r, calls = self.probe(endpoint='unix:///does-not-exist/ddnsto-docker.sock')
        self.assertEqual(r.stdout.strip(), 'socket-unavailable')
        self.assertNotIn('info', calls)


if __name__ == '__main__':
    unittest.main()
