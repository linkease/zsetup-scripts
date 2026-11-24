"""Package ownership after opkg retains an existing conffile outside .list."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
STATUS = """Package: ddnsto
Version: 4.2.8~8664-r1
Status: install user installed
Conffiles:
 /etc/config/ddnsto 521664440d383bfba7a222d8ee31439788d0b7deb704db415e611e233d9d33c4
Installed-Time: 1795489805
"""


class ConffileOwnership(unittest.TestCase):
    def run_owner(self, status=STATUS, search='', target='/etc/config/ddnsto'):
        script = f'''
. "{ROOT}/sources/ddnsto/openwrt-lifecycle.sh"
package_manager=opkg config=/etc/config/ddnsto
opkg() {{
    case "$1" in
      search) printf '%s' "$SEARCH" ;;
      status) test "$2" = ddnsto && printf '%s' "$STATUS" ;;
      *) return 99 ;;
    esac
}}
ddnsto_ow_owned "$TARGET"
'''
        return subprocess.run(['sh', '-eu', '-c', script], capture_output=True,
                              env=os.environ | dict(STATUS=status, SEARCH=search, TARGET=target))

    def test_preserved_config_uses_installed_conffile_record(self):
        self.assertEqual(self.run_owner().returncode, 0)

    def test_never_overrides_other_owner_or_accepts_other_files(self):
        self.assertNotEqual(self.run_owner(search='foreign - 1.0').returncode, 0)
        self.assertNotEqual(self.run_owner(target='/usr/sbin/ddnstod').returncode, 0)

    def test_rejects_incomplete_ambiguous_or_uninstalled_metadata(self):
        for status in ('', STATUS.replace(' installed', ' not-installed'),
                       STATUS.replace('Package: ddnsto', 'Package: foreign'),
                       STATUS.replace('/etc/config/ddnsto', '/etc/config/other'),
                       STATUS + STATUS,
                       STATUS.replace('521664440d383bfba7a222d8ee31439788d0b7deb704db415e611e233d9d33c4', 'invalid')):
            with self.subTest(status=status):
                self.assertNotEqual(self.run_owner(status=status).returncode, 0)


if __name__ == '__main__':
    unittest.main()
