"""Default macOS workflow, with no host services or network access."""
import unittest
import macos_behavior_test as macos


class MacDefault(unittest.TestCase):
    setUp = macos.MacInstaller.setUp
    tool = macos.MacInstaller.tool
    run_script = macos.MacInstaller.run_script
    run_menu = macos.MacInstaller.run_menu
    receipt = macos.MacInstaller.receipt
    # Inherit fixture helpers, not the historical menu contract.
    def test_default_same_account_starts_disabled_offline(self):
        self.assertEqual(self.run_script().returncode, 0)
        cfg = self.config / 'ddnsto.yaml'
        cfg.write_text(cfg.read_text() + 'routerName: custom\n')
        before = cfg.read_bytes()
        identity = self.config / '.ddnsto_boot.cfg'
        identity.write_text('identity')
        self.assertEqual(self.run_script(('--action', 'stop')).returncode, 0)
        result = self.run_script(FAIL_DOWNLOAD='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('启动成功', result.stdout)
        self.assertTrue((self.root / 'running').exists())
        self.assertFalse((self.root / 'disabled').exists())
        self.assertEqual(cfg.read_bytes(), before)
        self.assertEqual(identity.read_text(), 'identity')
        self.assertGreaterEqual((self.root / 'observations').read_text().count('observation'), 6)

    def test_default_upgrades_old_but_never_downgrades_newer(self):
        self.assertEqual(self.run_script().returncode, 0)
        for version, downloads in [('4.2.7', 2), ('4.10.0', 2), ('5.0.0', 2)]:
            self.receipt(version)
            result = self.run_script()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.root / 'download.log').read_text().count('download'), downloads)
            if version == '4.2.7':
                self.assertIn('DDNSTO 4.2.8:', result.stdout)
        result = self.run_script(('--action', 'update'), FAIL_DOWNLOAD='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('启动成功', result.stdout)

    def test_default_rejects_untrusted_receipts_and_config(self):
        self.assertEqual(self.run_script().returncode, 0)
        cfg = self.config / 'ddnsto.yaml'
        marker = self.config / '.installer-macos-v1'
        receipt = self.config / '.installer-macos-version'
        self.receipt('4.2.8')
        for path, content in [(cfg, "userToken: 'foreign'\n"),
                              (cfg, cfg.read_text() + "userToken: 'test-token'\n"),
                              (cfg, cfg.read_text() + '"user\\u0054oken": foreign\n'),
                              (marker, 'legacy'), (receipt, 'unknown')]:
            old = path.read_bytes()
            path.write_text(content)
            calls = (self.root / 'service.log').read_bytes()
            result = self.run_script()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_text(), content)
            self.assertNotIn('test-token', result.stdout + result.stderr)
            self.assertIn('下一步', result.stderr)
            self.assertIn('code=', result.stderr)
            self.assertEqual((self.root / 'service.log').read_bytes(), calls)
            path.write_bytes(old)
        for path in (cfg, marker, receipt):
            path.chmod(0o666)
            result = self.run_script()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.stat().st_mode & 0o777, 0o666)
            path.chmod(0o600)

    def test_default_requires_token_even_with_terminal(self):
        code, output = self.run_menu('')
        self.assertNotEqual(code, 0)
        self.assertNotIn('DDNSTO token:', output)
        self.assertNotIn('Choose', output)

    def test_default_refuses_root_without_touching_service(self):
        result = self.run_script(TEST_UID='0')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'service.log').exists())

    def test_default_unstable_pid_is_not_success(self):
        result = self.run_script(UNSTABLE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('安装成功', result.stdout)
        self.assertFalse((self.config / '.installer-macos-version').exists())

    def test_default_legacy_identity_without_receipts_is_not_fresh(self):
        self.config.mkdir()
        identity = self.config / '.ddnsto_boot.cfg'
        identity.write_text('legacy')
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'download.log').exists())
        self.assertEqual(identity.read_text(), 'legacy')

    def test_default_rejects_symlink_ancestor(self):
        real = self.root / 'real'
        real.mkdir()
        alias = self.root / 'alias'
        alias.symlink_to(real, target_is_directory=True)
        result = self.run_script(DDNSTO_CONFIG_DIR=str(alias / 'config'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(real.iterdir()), [])

    def test_default_rejects_shared_writable_parent(self):
        self.root.chmod(0o777)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.config.exists())

    def test_default_retained_newer_version_never_reinstalls_older(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.receipt('5.0.0')
        self.assertEqual(self.run_script(('--action', 'uninstall')).returncode, 0)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.install / 'ddnsto').exists())

    def test_default_does_not_relabel_legacy_binary_during_repair(self):
        self.assertEqual(self.run_script().returncode, 0)
        receipt = self.config / '.installer-macos-version'
        receipt.unlink()
        result = self.run_script(('--action', 'repair'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(receipt.exists())
        self.assertNotEqual(self.run_script().returncode, 0)

    def test_default_version_change_during_download_never_downgrades(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.receipt('4.2.7')
        native = (self.bin / 'zsetup').read_text()
        self.tool('zsetup', '''
if [ "$1" = download ]; then
 sed 's/^4.2.7 /5.0.0 /' "$DDNSTO_CONFIG_DIR/.installer-macos-version" > "$TEST_ROOT/receipt"
 cp "$TEST_ROOT/receipt" "$DDNSTO_CONFIG_DIR/.installer-macos-version"
fi
''' + native)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.config / '.installer-macos-version').read_text().startswith('5.0.0 '))

    def test_default_does_not_accept_foreign_process_after_start(self):
        launchctl = (self.bin / 'launchctl').read_text()
        self.tool('launchctl', '''
if [ -f "$TEST_ROOT/observations" ]; then export FOREIGN_PROGRAM=/foreign; fi
''' + launchctl)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('安装成功', result.stdout)
        self.assertNotIn('bootout', (self.root / 'service.log').read_text())

    def test_default_does_not_accept_nonrunning_state_with_pid(self):
        launchctl = (self.bin / 'launchctl').read_text()
        self.tool('launchctl', launchctl.replace("print)\n", "print)\necho 'state = waiting'\n"))
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)

    def test_default_failure_restores_version_receipt(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.receipt('4.2.7')
        receipt = self.config / '.installer-macos-version'
        before = receipt.read_bytes()
        result = self.run_script(FAIL_START='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt.read_bytes(), before)
        self.assertTrue((self.root / 'running').exists())

    def test_default_token_file_restarts_same_account_without_logging(self):
        token_file = self.root / 'token'
        token_file.write_text("quoted'credential\n")
        for _ in range(2):
            result = self.run_script(('--token-file', str(token_file)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("quoted'credential", result.stdout + result.stderr)

    def test_default_requires_logged_in_gui_domain(self):
        launchctl = (self.bin / 'launchctl').read_text()
        self.tool('launchctl', '''
if [ "$1" = print ] && [ "$2" = gui/501 ]; then exit 3; fi
''' + launchctl)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'download.log').exists())

    def test_default_explicit_ensure_matches_default(self):
        for _ in range(2):
            result = self.run_script(('--action', 'ensure', '--token', 'test-token'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('Choose', result.stdout + result.stderr)


if __name__ == '__main__':
    # Run only the new cases; historical coverage runs separately.
    names = [name for name in MacDefault.__dict__ if name.startswith('test_default_')]
    result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(MacDefault(n) for n in names))
    raise SystemExit(not result.wasSuccessful())
