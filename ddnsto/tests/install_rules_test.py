"""Keep declarative capabilities aligned with maintained pins, without core source."""
import json
from pathlib import Path
import re
import subprocess
import unittest

APP = Path(__file__).resolve().parents[1]


class InstallRulesTest(unittest.TestCase):
    def setUp(self):
        path = APP / 'install-rules.json'
        self.assertTrue(path.is_file(), 'DDNSTO declarative install rules are missing')
        self.rules = json.loads(path.read_text())

    def test_candidate_and_unsupported_boundaries(self):
        self.assertEqual(self.rules['schema_version'], 1)
        self.assertEqual(self.rules['product'], 'ddnsto')
        self.assertEqual(self.rules['status'], 'engineering-candidate')
        self.assertIs(self.rules.get('candidate'), True)
        self.assertFalse(self.rules['production_ready'])
        self.assertFalse(self.rules['cloud_online_verified'])
        self.assertEqual(set(self.rules['unsupported_platforms']), {'qnap', 'unraid'})
        self.assertEqual(self.rules['unsupported_methods'], [])
        self.assertEqual(set(self.rules['platforms']), {'linux', 'openwrt', 'macos', 'windows', 'synology'})
        for platform in self.rules['platforms'].values():
            self.assertFalse(platform['native_canary_verified'])
            self.assertTrue(platform['executors'])

    def test_native_actions_and_linux_configure_requirement(self):
        actions = ['install', 'update', 'status', 'start', 'stop', 'restart',
                   'repair', 'configure', 'uninstall']
        for name in ('linux', 'openwrt', 'macos', 'windows'):
            platform = self.rules['platforms'][name]
            self.assertEqual(platform.get('actions'), actions)
            self.assertEqual(platform['method'], 'native')
        self.assertEqual(self.rules['platforms']['linux']['action_requirements'], {'configure': ['jq']})
        self.assertIn('command -v jq', (APP / 'linux-lifecycle.sh').read_text())

    def test_synology_download_manual_handoff_and_pins(self):
        self.assertIn('synology', self.rules['platforms'])
        synology = self.rules['platforms']['synology']
        self.assertEqual(synology['architectures'], ['x86_64', 'armv7'])
        self.assertIn('aarch64', synology['unsupported_architectures'])
        self.assertEqual(synology['dsm_minimum_builds'], {'6': 5940, '7': 41890})
        self.assertEqual(synology['client_versions'], {'spk': '4.2.7-4'})
        self.assertEqual(synology['method'], 'download')
        self.assertEqual(synology['executors'], ['spk-download-manual-handoff'])
        self.assertEqual(synology['actions'], ['download', 'install'])
        self.assertEqual(synology['action_results'], {
            'download': {'exit_code': 0, 'installation_performed': False, 'manual_handoff_required': True},
            'install': {'exit_code': 20, 'installation_performed': False, 'manual_handoff_required': True},
        })
        # Use the helper's reviewed published pins, not locally rebuilt SPKs.
        source = (APP / 'synology-download.sh').read_text()
        pins = re.findall(r'(arm|x86):([67])\) digest=([a-f0-9]{64})', source)
        self.assertEqual(len(pins), 4)
        expected = {}
        for family, dsm, digest in pins:
            expected[f'synology/ddnsto_{family}-dsm{dsm}.spk'] = digest
        self.assertEqual(synology['artifacts'], expected)
        self.assertIn('package_version=' + synology['client_versions']['spk'], source)
        for dsm, minimum in synology['dsm_minimum_builds'].items():
            self.assertIn(dsm + ') minimum=' + str(minimum), source)

    def test_docker_restricted_executor_actions_and_digest(self):
        self.assertIn('docker', self.rules.get('method_capabilities', {}))
        docker = self.rules['method_capabilities']['docker']
        self.assertEqual(docker['platforms'], ['linux'])
        self.assertEqual(docker['architectures'], ['x86_64'])
        self.assertEqual(docker['engine_platform'], 'linux/amd64')
        self.assertEqual(docker['engine_requirements'], {
            'endpoint': 'local-unix-socket', 'rootless': False, 'desktop': False})
        self.assertEqual(docker['required_explicit_inputs'], ['network', 'device-name'])
        self.assertEqual(docker['networks'], ['bridge', 'host'])
        self.assertEqual(docker['token_policy'], 'validated-safe-value-private-env-file')
        self.assertEqual(docker['actions'], ['install', 'update', 'status', 'start', 'stop', 'restart', 'uninstall', 'repair'])
        self.assertEqual(docker['unsupported_actions'], ['configure'])
        self.assertEqual(docker['client_version'], '4.2.6')
        self.assertEqual(docker['image'], 'linkease/ddnsto@sha256:f70d2afbb0da6b21ff8865a4f3d9869775360bfbec1fff03474e5478a702ad30')
        self.assertIn('ddocker_image=' + docker['image'], (APP / 'docker-lifecycle.sh').read_text())
        self.assertTrue(docker['candidate'])
        self.assertFalse(docker['native_canary_verified'])
        self.assertFalse(docker['identity_persistence_verified'])
        self.assertEqual(docker['update_policy'], 'same-pin-no-op-recreation-blocked')
        self.assertEqual(docker['repair_policy'], 'start-existing-owned-container-only')
        self.assertEqual(docker['reinstall_policy'], 'blocked-identity-unverified')
        self.assertFalse(docker['full_lifecycle_supported'])
        self.assertEqual(docker['write_privilege'], 'root-shell-required')
        self.assertEqual(docker['interactive_inputs'], 'fresh-no-conflict-only-visible-token-name-network')

    def test_platform_architectures_and_native_executors(self):
        expected = {
            'linux': (['x86_64', 'aarch64'], ['systemd', 'openrc']),
            'openwrt': (['x86_64', 'aarch64', 'armv7', 'mipsel'], ['opkg', 'apk']),
            'macos': (['x86_64', 'aarch64'], ['launchd-user']),
            'windows': (['x86_64'], ['scheduled-task-system']),
        }
        for name, (arches, executors) in expected.items():
            self.assertEqual(self.rules['platforms'][name]['architectures'], arches)
            self.assertEqual(self.rules['platforms'][name]['executors'], executors)

    def test_linux_lifecycle_is_systemd_only(self):
        linux = self.rules['platforms']['linux']
        self.assertEqual(linux.get('lifecycle_requirements'), {
            'actions': ['start', 'stop', 'restart', 'repair', 'configure', 'uninstall'],
            'executors': ['systemd'],
        })
        self.assertEqual(linux['limitations']['openrc'], {
            'supported_actions': ['install', 'update', 'status'],
            'unsupported_actions': ['start', 'stop', 'restart', 'repair', 'configure', 'uninstall'],
        })

    def test_client_versions_match_maintained_product_pins(self):
        pins = (APP / 'product-pins.sh').read_text()
        platforms = self.rules['platforms']
        for variant in ('standard', 'lite'):
            version = subprocess.check_output(['/bin/sh', '-c',
                '. "$1"; ddnsto_pinned_version "$2"', 'test', str(APP / 'product-pins.sh'), variant], text=True).strip()
            self.assertEqual(platforms['openwrt']['client_versions'][variant], version)
        version = platforms['linux']['client_versions']['standard']
        self.assertIn('linux-binary/ddnsto-standard-' + version + '.tar.gz)', pins)
        for platform, filename in (('macos', 'install-macos.sh'), ('windows', 'install.ps1')):
            source = (APP / filename).read_text()
            pattern = (r'VERSION=\$\{DDNSTO_VERSION:-([^}]+)\}' if platform == 'macos'
                       else r"\[string\]\$Version = '([^']+)'")
            default_version = re.search(pattern, source).group(1)
            self.assertEqual(platforms[platform]['client_versions'], {'standard': default_version})

    def test_zsetup_release_records_match_maintained_pins(self):
        releases = self.rules['zsetup_releases']
        for platform in ('linux', 'openwrt'):
            self.assertEqual(self.rules['platforms'][platform]['zsetup_release'], 'linux-0.5.0')
        for key, release in releases.items():
            source = (APP / release['pin_source']).read_text()
            self.assertIn(release['version'], source)
            for artifact, digest in release['artifacts'].items():
                self.assertRegex(digest, r'^[0-9a-f]{64}$')
                self.assertIn(digest, source)
                if key == 'linux-0.5.0':
                    arch = artifact.removeprefix('zsetup-linux-')
                    result = subprocess.check_output(['/bin/sh', '-c',
                        '. "$1"; ZSETUP_ARCH=$2; fetch_bootstrap_metadata https x x; printf "%s" "$EXPECTED_SHA256"',
                        'test', str(APP / release['pin_source']), arch], text=True)
                    self.assertEqual(result, digest)
                else:
                    self.assertIn(artifact, source)
                    if key == 'macos-0.3.0':
                        self.assertIn('native=' + artifact + '; native_sha=' + digest, source)
        self.assertEqual(set(releases), {'linux-0.5.0', 'macos-0.3.0', 'windows-0.4.0'})


if __name__ == '__main__':
    unittest.main()
