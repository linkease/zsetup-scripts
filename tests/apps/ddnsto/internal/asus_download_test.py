import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[4] / 'sources/ddnsto'


class AsusDownload(unittest.TestCase):
    def test_metadata_transport_without_command_builtin(self):
        with tempfile.TemporaryDirectory() as directory:
            native = Path(directory) / 'native-0.6.4-aarch64/zsetup'
            native.parent.mkdir()
            native.write_text('verified')
            native.chmod(0o700)
            script = f'''
set -eu
. "{ROOT.parents[1]}/lib/bootstrap.sh"
. "{ROOT}/auto-asus.sh"
ASUS_STATE=$FIXTURE ASUS_ARCH=aarch64
type() {{ if [ "$1" = command ]; then return 1; else builtin type "$@"; fi; }}
command() {{ return 127; }}
bootstrap_arch() {{ ZSETUP_ARCH=aarch64; ZSETUP_ARTIFACT=zsetup-linux-aarch64; ZSETUP_STABLE_PATH=zsetup/stable; }}
ddnsto_asus_mktemp() {{ mktemp -d "$1/metadata.XXXXXX"; }}
curl() {{
    while [ "$1" != -o ]; do shift; done
    case "$3" in
      */zsetup/stable) printf '0.6.4\\n' > "$2" ;;
      */zsetup/0.6.4/SHA256SUMS) printf '%064d  zsetup-linux-aarch64\\n' 0 > "$2" ;;
      *) return 99 ;;
    esac
}}
ddnsto_asus_private_dir() {{ test -d "$1"; }}
ddnsto_asus_safe_file() {{ test -f "$1"; }}
ddnsto_asus_hash() {{ printf '%064d\\n' 0; }}
ddnsto_asus_native
test "$ASUS_ZSETUP" = "$FIXTURE/native-0.6.4-aarch64/zsetup"
'''
            result = subprocess.run(['bash', '-c', script], text=True, capture_output=True,
                                    env=os.environ | {'FIXTURE': directory})
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_shared_bootstrap_metadata_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            native = fixture / 'native-0.6.4-aarch64/zsetup'
            native.parent.mkdir()
            native.write_text('verified')
            native.chmod(0o700)
            script = f'''
set -eu
. "{ROOT.parents[1]}/lib/bootstrap.sh"
. "{ROOT}/auto-asus.sh"
ASUS_STATE=$FIXTURE ASUS_ARCH=aarch64
bootstrap_arch() {{ ZSETUP_ARCH=aarch64; ZSETUP_ARTIFACT=zsetup-linux-aarch64; ZSETUP_STABLE_PATH=zsetup/stable; }}
ddnsto_asus_mktemp() {{ mktemp -d "$1/metadata.XXXXXX"; }}
bootstrap_fetch_from_base() {{
    case "$3" in
      zsetup/stable) printf '0.6.4\\n' > "$4" ;;
      zsetup/0.6.4/SHA256SUMS) printf '%064d  zsetup-linux-aarch64\\n' 0 > "$4" ;;
      *) return 99 ;;
    esac
}}
ddnsto_asus_private_dir() {{ test -d "$1"; }}
ddnsto_asus_safe_file() {{ test -f "$1"; }}
ddnsto_asus_hash() {{ printf '%064d\\n' 0; }}
ddnsto_asus_native
test "$ASUS_ZSETUP" = "$FIXTURE/native-0.6.4-aarch64/zsetup"
'''
            result = subprocess.run(['sh', '-c', script], text=True, capture_output=True,
                                    env=os.environ | {'FIXTURE': directory})
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_native_cache_is_rehashed_and_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            script = f'''
set -eu
umask 077
. "{ROOT}/auto-asus.sh"
ASUS_STATE=$FIXTURE ASUS_ARCH=aarch64
bootstrap_arch() {{ :; }}
fetch_bootstrap_metadata() {{ RESCUE_VERSION=$FIXTURE_VERSION; EXPECTED_SHA256=$(printf '%064d' 0); }}
ddnsto_asus_private_dir() {{ mkdir -p "$1"; }}
ddnsto_asus_safe_file() {{ [ -f "$1" ] && [ ! -L "$1" ]; }}
ddnsto_asus_mktemp() {{ mktemp -d "$1/attempt.XXXXXX"; }}
ddnsto_asus_hash() {{ [ "$(cat "$1")" = native ] && printf '%064d\\n' 0 || echo bad; }}
ddnsto_asus_transport() {{ echo fetch >> "$FIXTURE/events"; printf native > "$2"; }}
ddnsto_asus_native
first=$ASUS_ZSETUP
ddnsto_asus_native
[ "$first" = "$ASUS_ZSETUP" ]
[ "$(wc -l < "$FIXTURE/events")" = 1 ]
printf changed > "$ASUS_ZSETUP"
if ddnsto_asus_native; then exit 99; fi
'''
            result = subprocess.run(['sh', '-c', script], text=True, capture_output=True,
                                    env=os.environ | {'FIXTURE': directory, 'FIXTURE_VERSION': '0.6.5'})
            self.assertEqual(result.returncode, 0, result.stderr)

    def run_fetch(self, channel, corrupt=False):
        self.assertTrue((ROOT / 'auto-asus.sh').exists(), 'ASUS downloader is not implemented')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native = root / 'native'
            native.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$FIXTURE/args"\n'
                              '[ "$CORRUPT" = 0 ] || exit 11\nprintf payload > "$3"\n')
            native.chmod(0o700)
            script = f'''
set -eu
. "{ROOT}/asus-platform.sh"
. "{ROOT}/auto-asus.sh"
ASUS_STATE=$FIXTURE ASUS_CHANNEL=$CHANNEL ASUS_ARCH=aarch64
ddnsto_asus_native() {{ ASUS_ZSETUP="$FIXTURE/native"; echo native >> "$FIXTURE/events"; }}
ddnsto_asus_transport() {{ echo legacy >> "$FIXTURE/events"; printf payload > "$2"; }}
ddnsto_asus_hash() {{ echo hash >> "$FIXTURE/events"; [ "$CORRUPT" = 0 ] && printf '%s' "$asus_digest" || echo bad; }}
# Product size is checked independently in real code; fixture represents a
# bounded native/HTTPS download with a known seven-byte inert body.
ddnsto_asus_package() {{ printf '%s\\n' "https://asusgo.koolcenter.com/$1/ddnsto/ddnsto.tar.gz" 4.2.8 arm384 7 fixture-digest; }}
ddnsto_asus_fetch "$FIXTURE/package.tar.gz"
'''
            result = subprocess.run(['sh', '-c', script], text=True, capture_output=True,
                                    env=os.environ | {'FIXTURE': directory, 'CHANNEL': channel, 'CORRUPT': str(int(corrupt))})
            events = (root / 'events').read_text().splitlines()
            args = (root / 'args').read_text() if (root / 'args').exists() else ''
            return result, events, args

    def test_modern_channels_use_native_digest_download(self):
        for channel in ('rogsoft', 'mtksoft', 'ipq32soft', 'ipq64soft', 'qcasoft'):
            result, events, args = self.run_fetch(channel)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events, ['native'])
            self.assertIn('--sha256\nfixture-digest', args)
            self.assertIn('--size\n7\n', args)
            self.assertIn('--max-bytes\n7\n', args)
            self.assertIn(f'https://asusgo.koolcenter.com/{channel}/ddnsto/ddnsto.tar.gz', args)

    def test_armsoft_uses_authorized_legacy_transport(self):
        result, events, _ = self.run_fetch('armsoft')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ['legacy', 'hash'])

    def test_changed_bytes_are_rejected_in_both_paths(self):
        for channel in ('rogsoft', 'armsoft'):
            result, _, _ = self.run_fetch(channel, corrupt=True)
            self.assertNotEqual(result.returncode, 0)

    def test_native_rejection_never_falls_back_to_legacy(self):
        result, events, _ = self.run_fetch('rogsoft', corrupt=True)
        self.assertEqual(result.returncode, 11)
        self.assertEqual(events, ['native'])


if __name__ == '__main__':
    unittest.main()
