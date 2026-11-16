"""Isolated native-first coordinator tests; never execute an installer/service."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'ddnsto/recommendation-native.sh'


class NativeEntry(unittest.TestCase):
    def run_case(self, corrupt=False, platform='Linux', arch='x86_64', native_rc=0):
        self.assertTrue(MODULE.exists(), 'native-first coordinator missing')
        with tempfile.TemporaryDirectory(prefix='native-entry-') as directory:
            work = Path(directory)
            native = work / 'fixture'
            native.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$EVENTS"\nexit "$NATIVE_RC"\n')
            pin = hashlib.sha256(native.read_bytes()).hexdigest()
            script = '''
set -eu
umask 077
. "$MODULE"
work=$WORK
asus_entry=0
uname() { if [ "$1" = -s ]; then echo "$OS"; else echo "$ARCH"; fi; }
fetch_bootstrap_metadata() { RESCUE_VERSION=0.5.0; EXPECTED_SHA256=$PIN; }
fetch() { if [ "$CORRUPT" = 1 ]; then printf bad > "$2"; else cp "$FIXTURE" "$2"; fi; }
hash_file() { sha256sum "$1" | cut -d ' ' -f 1; }
fail() { echo "$1" >&2; exit "$3"; }
ddnsto_recommend_native_prepare
if [ -n "$recommend_native" ]; then
    digest=$PIN size=42 base=https://example.invalid
    ddnsto_recommend_native_download
else
    echo legacy-path
fi
'''
            result = subprocess.run(['sh', '-c', script], text=True, capture_output=True,
                env=os.environ | dict(MODULE=str(MODULE), WORK=str(work), OS=platform,
                    ARCH=arch, PIN=pin, FIXTURE=str(native), EVENTS=str(work / 'events'),
                    CORRUPT=str(int(corrupt)), NATIVE_RC=str(native_rc)))
            events = (work / 'events').read_text() if (work / 'events').exists() else ''
            return result, events

    def test_native_receives_digest_exact_size_and_fresh_download(self):
        result, events = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        for item in ('download\n', '--sha256\n', '--size\n42\n', '--no-cache\n', '--max-bytes\n42\n'):
            self.assertIn(item, events)

    def test_bad_core_is_not_executed(self):
        result, events = self.run_case(corrupt=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, '')

    def test_native_failure_is_not_legacy_fallback(self):
        result, events = self.run_case(native_rc=11)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('download', events)
        self.assertNotIn('legacy-path', result.stdout)

    def test_unvalidated_platforms_keep_legacy_path(self):
        for platform, arch in [('Darwin', 'arm64'), ('Linux', 'mips'), ('Linux', 'armv7l')]:
            result, events = self.run_case(platform=platform, arch=arch)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'legacy-path\n')
            self.assertEqual(events, '')


if __name__ == '__main__':
    unittest.main()
