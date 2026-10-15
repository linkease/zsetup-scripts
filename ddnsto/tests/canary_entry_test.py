"""Validate canary inputs without starting Docker or contacting a server."""
import os
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).with_name('github_linux_canary.sh')
SHA = 'a' * 64


class CanaryEntry(unittest.TestCase):
    def check_entry(self, url, digest=SHA):
        return subprocess.run(['sh', str(SCRIPT), '--check-entry'],
                              env={**os.environ, 'ENTRY_URL': url, 'ENTRY_SHA': digest},
                              capture_output=True, text=True)

    def test_accepts_immutable_test_site_url(self):
        for version in ('0.1.9', '0.1.10'):
            with self.subTest(version=version):
                result = self.check_entry(f'https://web.toany.net/ddnsto-install/{version}/20261015-abc123/install.sh')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('ENTRY_CONTRACT_OK', result.stdout)

    def test_keeps_fixed_github_commit_support(self):
        result = self.check_entry('https://raw.githubusercontent.com/linkease/zsetup-scripts/' + 'a' * 40 + '/ddnsto/install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_mutable_insecure_or_external_url_and_bad_hash(self):
        for url in (
            'http://web.toany.net/ddnsto-install/0.1.9/build/install.sh',
            'https://evil.invalid/ddnsto-install/0.1.9/build/install.sh',
            'https://web.toany.net/install/',
            'https://web.toany.net/ddnsto-install/0.1.9/../install.sh',
            'https://web.toany.net/ddnsto-install/0.1.9/latest/install.sh',
            'https://raw.githubusercontent.com/linkease/zsetup-scripts/main/ddnsto/install.sh',
        ):
            with self.subTest(url=url):
                self.assertNotEqual(self.check_entry(url).returncode, 0)
        self.assertNotEqual(self.check_entry('https://web.toany.net/ddnsto-install/0.1.9/20261015-abc123/install.sh', 'bad').returncode, 0)

    def test_entry_is_verified_before_cloud_access_is_blocked_and_execution(self):
        script = SCRIPT.read_text()
        verified = script.index('sha256sum -c -')
        firewall = script.index('iptables -A OUTPUT')
        self.assertLess(verified, firewall, 'fetch the fixed entry before restricting egress')
        download_hosts = script.split('hosts=[', 1)[1].split(']', 1)[0]
        self.assertNotIn('web.toany.net', download_hosts)
        self.assertNotIn('raw.githubusercontent.com', download_hosts)
        execution = script.index('# Execute only the already verified entry')
        self.assertNotIn('curl -fsSL', script[execution:], 'do not reopen entry-host egress while client runs')
        self.assertIn('CLOUD_EGRESS_BLOCKED', script)
        self.assertIn('iptables -I OUTPUT 1', script)


if __name__ == '__main__':
    unittest.main()
