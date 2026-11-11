from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AsusEntry(unittest.TestCase):
    def test_explicit_asus_constraint_and_help(self):
        script = '. "$1"; ddnsto_error() { echo "$*" >&2; }; ddnsto_parse_args --platform asus --plan; ddnsto_usage'
        result = subprocess.run(['sh', '-eu', '-c', script, 'test', str(ROOT / 'managed-cli.sh')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('armsoft', result.stdout)

    def test_appliance_is_not_generic_linux(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'koolshare').mkdir()
            (root / 'bin').mkdir()
            (root / 'bin/nvram').write_text('#!/bin/sh\n')
            (root / 'bin/nvram').chmod(0o755)
            result = subprocess.run(['sh', '-c', '. "$1"; ddnsto_appliance_platform "$2"',
                                     'test', str(ROOT / 'managed-cli.sh'), directory], capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), 'asus')

    def test_default_route_never_bootstraps_generic_linux(self):
        script = f'. "{ROOT}/auto-install.sh"\n' + '''
detected_platform=asus
ddnsto_asus_ensure() { echo ASUS; }
bootstrap_and_run() { exit 99; }
ddnsto_ensure_execute
'''
        result = subprocess.run(['sh', '-eu', '-c', script], capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout.strip()), (0, 'ASUS'))

    def test_asus_preflight_is_allowed_by_default_flow(self):
        script = f'. "{ROOT}/auto-install.sh"\n' + '''
detected_platform=asus TOKEN=fixture REQUESTED_METHOD=auto FORCE_VERSION= VERIFY_STATUS=0
ddnsto_ensure_preflight
'''
        result = subprocess.run(['sh', '-eu', '-c', script], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
