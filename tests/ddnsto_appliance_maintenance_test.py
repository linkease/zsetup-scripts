"""Device regressions: no actual packages, services, mounts or root files changed."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'sources/ddnsto'


class ApplianceMaintenance(unittest.TestCase):
    def run_shell(self, text):
        return subprocess.run(['sh', '-eu', '-c', text], capture_output=True, text=True)

    def test_synology_status_dispatch_never_bootstraps(self):
        main = (SOURCE / 'main.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        result = self.run_shell(main + '''
ddnsto_parse_args() { ACTION=status; PLAN_ONLY=0; REQUESTED_METHOD=native; }
ddnsto_local_platform() { detected_platform=synology; }
ddnsto_validate_platform_options() { :; }
ddnsto_business_environment_preflight() { :; }
ddnsto_synology_status() { echo local-status; }
ddnsto_synology_entry() { echo wrong-download-path; return 99; }
ddnsto_entry_install --action status
''')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.strip(), 'local-status')

    def test_synology_status_is_local_and_distinguishes_unverified_running(self):
        with tempfile.TemporaryDirectory() as directory:
            pkg = Path(directory)
            (pkg / 'INFO').write_text('package="ddnsto"\n')
            source = (SOURCE / 'auto-synology.sh').read_text().replace('/var/packages/ddnsto', directory)
            for state, stable, expected, rc in [('running', True, 'running', 0),
                                               ('stopped', False, 'stopped', 0),
                                               ('running', False, 'unverified', 13)]:
                result = self.run_shell(source + f'''
id() {{ echo 0; }}
ddnsto_flow_error() {{ echo "$1" >&2; return 2; }}
ddnsto_synology_check_paths() {{ :; }}
ddnsto_synopkg() {{ [ "$1" = status ] || exit 99; echo '{{"status":"{state}"}}'; }}
ddnsto_synology_running() {{ {'true' if stable else 'false'}; }}
bootstrap_zsetup_path() {{ exit 98; }}
ddnsto_synology_storage() {{ exit 97; }}
ddnsto_synology_status
''')
                self.assertEqual(result.returncode, rc, result.stderr)
                self.assertIn('local_service=' + expected, result.stdout)

    def test_asus_known_links_are_scanned_but_arbitrary_links_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ks = root / 'koolshare'
            (ks / 'scripts').mkdir(parents=True)
            (ks / 'init.d').mkdir()
            script = ks / 'scripts/ddnsto_config.sh'
            script.write_text('#!/bin/sh\nexit 99\n')
            script.chmod(0o755)
            link = ks / 'init.d/S70ddnsto.sh'
            link.symlink_to(script)
            source = (SOURCE / 'managed-cli.sh').read_text().replace('/koolshare', str(ks))
            storage = (SOURCE / 'asus-storage.sh').read_text()
            body = storage + '\n' + source + '''
# Fixture user models firmware uid 0; retain real file type/mode/link checks.
_ddnsto_asus_ls() { LC_ALL=C ls -nd "$1" | awk '{$3=0; print}'; }
ddnsto_error() { echo "$*" >&2; }
detected_platform=asus; BUSINESS_ENV=production
ddnsto_business_environment_preflight
'''
            result = self.run_shell(body)
            self.assertEqual(result.returncode, 0, result.stderr)
            script.write_text('DDNSTO_TEST_SERVER_ASSIGNMENT_JSON=custom\n')
            self.assertNotEqual(self.run_shell(body).returncode, 0)
            script.write_text('#!/bin/sh\n')
            script.chmod(0o777)
            self.assertNotEqual(self.run_shell(body).returncode, 0)
            script.chmod(0o755)
            link.unlink()
            other = root / 'arbitrary'
            other.write_text('#!/bin/sh\n')
            link.symlink_to(other)
            self.assertNotEqual(self.run_shell(body).returncode, 0)
            link.unlink()
            link.symlink_to(script)
            script.unlink()
            self.assertNotEqual(self.run_shell(body).returncode, 0, 'dangling known link must fail')


if __name__ == '__main__':
    unittest.main()
