"""Business environment is persisted in launchd, not inferred from a web origin."""
import json
import plistlib
import macos_behavior_test


class MacEnvironment(macos_behavior_test.MacInstaller):
    def assert_production(self):
        plist = plistlib.loads((self.agents / 'com.ddnsto.client.plist').read_bytes())
        assignment = json.loads(plist['EnvironmentVariables']['DDNSTO_TEST_SERVER_ASSIGNMENT_JSON'])
        self.assertEqual(assignment['serverDomain'], 'kooldns.cn')

    def test_legacy_plist_without_boot_defaults_to_production(self):
        self.assertEqual(self.run_script().returncode, 0)
        path = self.agents / 'com.ddnsto.client.plist'
        original = path.read_text()
        path.write_text(''.join(line for line in original.splitlines(keepends=True)
            if '<key>EnvironmentVariables</key>' not in line))
        (self.root / 'loaded.plist').write_bytes(path.read_bytes())
        before = (self.config / 'ddnsto.yaml').read_bytes()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_production()
        self.assertEqual((self.config / 'ddnsto.yaml').read_bytes(), before)

    def test_legacy_retained_without_boot_defaults_to_production(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.run_script(('--action', 'uninstall')).returncode, 0)
        marker = self.config / '.installer-macos-v1'
        marker.write_text('ddnsto-macos-v1-retained\n')
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_production()

    def test_legacy_plist_with_boot_defaults_to_production(self):
        self.assertEqual(self.run_script(BOOT_IDENTITY='1').returncode, 0)
        identity = self.config / '.ddnsto_boot.cfg'
        identity_before = identity.read_bytes()
        config_before = (self.config / 'ddnsto.yaml').read_bytes()
        path = self.agents / 'com.ddnsto.client.plist'
        path.write_text(''.join(line for line in path.read_text().splitlines(keepends=True)
            if '<key>EnvironmentVariables</key>' not in line))
        (self.root / 'loaded.plist').write_bytes(path.read_bytes())
        result = self.run_script(FAIL_DOWNLOAD='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_production()
        self.assertEqual(identity.read_bytes(), identity_before)
        self.assertEqual((self.config / 'ddnsto.yaml').read_bytes(), config_before)

    def test_missing_plist_and_job_with_boot_repair_defaults_to_production(self):
        self.assertEqual(self.run_script(BOOT_IDENTITY='1').returncode, 0)
        identity = self.config / '.ddnsto_boot.cfg'
        identity_before = identity.read_bytes()
        config_before = (self.config / 'ddnsto.yaml').read_bytes()
        (self.agents / 'com.ddnsto.client.plist').unlink()
        (self.root / 'running').unlink()
        result = self.run_script(('--action', 'repair'), FAIL_DOWNLOAD='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_production()
        self.assertTrue((self.root / 'running').exists())
        self.assertEqual(identity.read_bytes(), identity_before)
        self.assertEqual((self.config / 'ddnsto.yaml').read_bytes(), config_before)

    def test_legacy_retained_with_boot_defaults_to_production(self):
        self.assertEqual(self.run_script(BOOT_IDENTITY='1').returncode, 0)
        identity = self.config / '.ddnsto_boot.cfg'
        identity_before = identity.read_bytes()
        config_before = (self.config / 'ddnsto.yaml').read_bytes()
        self.assertEqual(self.run_script(('--action', 'uninstall')).returncode, 0)
        (self.config / '.installer-macos-v1').write_text('ddnsto-macos-v1-retained\n')
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_production()
        self.assertEqual(identity.read_bytes(), identity_before)
        self.assertEqual((self.config / 'ddnsto.yaml').read_bytes(), config_before)

    def test_missing_plist_with_legacy_loaded_job_defaults_to_production(self):
        self.assertEqual(self.run_script().returncode, 0)
        path = self.agents / 'com.ddnsto.client.plist'
        loaded = plistlib.loads(path.read_bytes())
        del loaded['EnvironmentVariables']
        (self.root / 'loaded.plist').write_bytes(plistlib.dumps(loaded))
        path.unlink()
        result = self.run_script(('--action', 'repair'), FAIL_DOWNLOAD='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_production()

    def test_omitted_environment_requires_confirmation_to_leave_test(self):
        self.assertEqual(self.run_script(('--env', 'test', '--token', 'test-token')).returncode, 0)
        path = self.agents / 'com.ddnsto.client.plist'
        before = path.read_bytes()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('switch-environment', result.stderr)
        self.assertEqual(path.read_bytes(), before)
        result = self.run_script(('--switch-environment', '--token', 'test-token'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_production()

    def test_missing_plist_preserves_loaded_test_switch_confirmation(self):
        self.assertEqual(self.run_script(('--env', 'test', '--token', 'test-token')).returncode, 0)
        path = self.agents / 'com.ddnsto.client.plist'
        path.unlink()
        result = self.run_script(('--action', 'repair'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('switch-environment', result.stderr)
        self.assertFalse(path.exists())
        result = self.run_script(('--action', 'repair', '--switch-environment'), FAIL_DOWNLOAD='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_production()

    def test_missing_plist_does_not_adopt_foreign_loaded_environment(self):
        self.assertEqual(self.run_script().returncode, 0)
        path = self.agents / 'com.ddnsto.client.plist'
        path.unlink()
        before = (self.root / 'service.log').read_text()
        result = self.run_script(('--action', 'repair'), FOREIGN_BUSINESS_ENV='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(path.exists())
        calls = (self.root / 'service.log').read_text()[len(before):].splitlines()
        self.assertFalse(set(calls) & {'bootout', 'bootstrap', 'enable', 'disable'})

    def test_test_environment_persists_assignment(self):
        result = self.run_script(('--env', 'test', '--token', 'test-token'))
        self.assertEqual(result.returncode, 0, result.stderr)
        plist = plistlib.loads((self.agents / 'com.ddnsto.client.plist').read_bytes())
        assignment = json.loads(plist['EnvironmentVariables']['DDNSTO_TEST_SERVER_ASSIGNMENT_JSON'])
        self.assertEqual(assignment['legacyControlAddr'], 'tunnel.toany.net:4445')
        self.assertEqual(assignment['controlWssURLs'], ['wss://web.toany.net:9445/ws/control'])
        repeated = self.run_script(('--env', 'test', '--token', 'test-token'))
        self.assertEqual(repeated.returncode, 0, repeated.stderr)

    def test_switch_requires_confirmation_and_preserves_config(self):
        self.assertEqual(self.run_script().returncode, 0)
        config = (self.config / 'ddnsto.yaml').read_bytes()
        result = self.run_script(('--env', 'test', '--token', 'test-token'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('switch-environment', result.stderr)
        result = self.run_script(('--env', 'test', '--switch-environment', '--token', 'test-token'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.config / 'ddnsto.yaml').read_bytes(), config)
        plist = plistlib.loads((self.agents / 'com.ddnsto.client.plist').read_bytes())
        assignment = json.loads(plist['EnvironmentVariables']['DDNSTO_TEST_SERVER_ASSIGNMENT_JSON'])
        self.assertEqual(assignment['legacyControlAddr'], 'tunnel.toany.net:4445')
        self.assertIn('bootout', (self.root / 'service.log').read_text())

    def test_invalid_environment_before_download(self):
        result = self.run_script(('--env', 'custom', '--token', 'test-token'))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'download.log').exists())

    def test_switch_back_to_production_overrides_test_boot_assignment(self):
        result = self.run_script(('--env', 'test', '--token', 'test-token'))
        self.assertEqual(result.returncode, 0, result.stderr)
        identity = self.config / '.ddnsto_boot.cfg'
        identity.write_bytes(b'encrypted-test-assignment-and-rid')
        identity.chmod(0o600)
        before = (self.root / 'service.log').read_text().count('bootout')
        result = self.run_script(('--env', 'production', '--switch-environment', '--token', 'test-token'))
        self.assertEqual(result.returncode, 0, result.stderr)
        plist = plistlib.loads((self.agents / 'com.ddnsto.client.plist').read_bytes())
        assignment = json.loads(plist['EnvironmentVariables']['DDNSTO_TEST_SERVER_ASSIGNMENT_JSON'])
        self.assertEqual(assignment['legacyControlAddr'], 'tunnel.kooldns.cn:4445')
        self.assertNotIn('controlWssURLs', assignment)
        self.assertEqual(identity.read_bytes(), b'encrypted-test-assignment-and-rid')
        self.assertGreater((self.root / 'service.log').read_text().count('bootout'), before)

    def test_foreign_loaded_environment_is_not_reported_as_success(self):
        self.assertEqual(self.run_script().returncode, 0)
        result = self.run_script(FOREIGN_BUSINESS_ENV='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('安装成功', result.stdout)

    def test_test_environment_survives_retained_reinstall(self):
        self.assertEqual(self.run_script(('--env', 'test', '--token', 'test-token'), BOOT_IDENTITY='1').returncode, 0)
        self.assertEqual(self.run_script(('--env', 'test', '--action', 'uninstall')).returncode, 0)
        self.assertNotEqual(self.run_script().returncode, 0)
        result = self.run_script(('--env', 'test', '--token', 'test-token'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.config / '.ddnsto_boot.cfg').read_bytes(), b'identity')
        plist = plistlib.loads((self.agents / 'com.ddnsto.client.plist').read_bytes())
        self.assertIn('tunnel.toany.net', plist['EnvironmentVariables']['DDNSTO_TEST_SERVER_ASSIGNMENT_JSON'])

    def test_custom_config_shapes_are_refused_during_management(self):
        self.assertEqual(self.run_script().returncode, 0)
        config = self.config / 'ddnsto.yaml'
        original = config.read_text()
        for extra in ('"bootConfigPath": /custom/identity\n',
                      'remote_addr: custom.example\n',
                      '{"remoteAddr":"custom.example"}\n'):
            config.write_text(original + extra)
            result = self.run_script(('--action', 'restart'))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(config.read_text(), original + extra)
