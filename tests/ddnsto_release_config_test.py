"""Release configuration is compiled offline; target devices need no parser."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ReleaseConfigurationTests(unittest.TestCase):
    def builder(self):
        path = ROOT / 'scripts/build-ddnsto-products.py'
        self.assertTrue(path.is_file(), 'missing single-source release compiler')
        spec = importlib.util.spec_from_file_location('products', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def config(self):
        return json.loads((ROOT / 'apps/ddnsto/source/platform-releases.json').read_text())

    def test_checked_in_outputs_match_configuration(self):
        builder = self.builder()
        for name, content in builder.render(ROOT, self.config()).items():
            self.assertEqual((ROOT / 'apps/ddnsto/source' / name).read_text(), content, name)

    def test_powershell_bom_is_only_at_start(self):
        content = self.builder().render(ROOT, self.config())['install.ps1']
        self.assertTrue(content.startswith('\ufeff'))
        self.assertNotIn('\ufeff', content[1:])

    def test_platform_versions_are_independent(self):
        builder = self.builder()
        original = self.config()
        baseline = builder.render(ROOT, original)
        for platform, output in [('macos', 'install-macos.sh'), ('windows', 'install.ps1'),
                                 ('linux', 'business.sh'), ('synology', 'auto-synology.sh'),
                                 ('asus', 'asus-transaction.sh')]:
            config = copy.deepcopy(original)
            config['platforms'][platform]['client_version'] = '9.8.7'
            if platform == 'synology':
                config['platforms'][platform]['package_version'] = '9.8.7-9'
            rendered = builder.render(ROOT, config)
            self.assertIn('9.8.7', rendered[output], platform)
            for other, path in [('macos', 'install-macos.sh'), ('windows', 'install.ps1'),
                                ('synology', 'auto-synology.sh'), ('asus', 'asus-transaction.sh')]:
                if other != platform:
                    self.assertEqual(rendered[path], baseline[path], (platform, other))

    def test_linux_and_openwrt_pins_are_not_coupled(self):
        builder = self.builder()
        config = self.config()
        config['platforms']['linux']['client_version'] = '9.8.7'
        config['platforms']['openwrt']['client_version'] = '8.7.6'
        rendered = builder.render(ROOT, config)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'pins.sh'
            path.write_text(rendered['product-pins.sh'])
            result = subprocess.run(['sh', '-c', '. "$1"; ddnsto_pinned_version standard linux; '
                                     'ddnsto_pinned_version standard; ddnsto_pinned_version lite',
                                     'test', str(path)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ['9.8.7', '8.7.6', '8.7.6'])

    def test_malformed_version_and_digest_fail_closed(self):
        builder = self.builder()
        for field, value in [('client_version', '1.2.3; touch /tmp/unsafe'),
                             ('client_version', '01.2.3'), ('archive_sha256', 'bad')]:
            config = self.config()
            config['platforms']['macos'][field] = value
            with self.assertRaises(ValueError):
                builder.render(ROOT, config)

    def test_missing_platform_and_mismatched_package_fail_closed(self):
        builder = self.builder()
        config = self.config()
        del config['platforms']['linux']
        with self.assertRaises(ValueError):
            builder.render(ROOT, config)
        config = self.config()
        config['platforms']['synology']['package_version'] = '1.0.0-7'
        with self.assertRaises(ValueError):
            builder.render(ROOT, config)

    def test_rebuilt_macos_plan_uses_its_own_version(self):
        builder = self.builder()
        config = self.config()
        config['platforms']['macos']['client_version'] = '9.8.7'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            uname = root / 'uname'
            uname.write_text('#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n')
            uname.chmod(0o755)
            installer = root / 'install.sh'
            installer.write_text(builder.render(ROOT, config)['install-macos.sh'])
            result = subprocess.run(['sh', str(installer), '--plan'], text=True,
                                    capture_output=True, env=os.environ | {'PATH': directory + ':' + os.environ['PATH']})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('client_version=9.8.7', result.stdout)

    def test_check_rejects_stale_output_without_rewriting(self):
        builder = self.builder()
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / 'apps/ddnsto/source/templates', root / 'ddnsto/templates')
            shutil.copyfile(ROOT / 'apps/ddnsto/source/platform-releases.json', root / 'ddnsto/platform-releases.json')
            builder.generate(root)
            output = root / 'ddnsto/install.ps1'
            output.write_text('stale')
            with self.assertRaises(ValueError):
                builder.generate(root, check=True)
            self.assertEqual(output.read_text(), 'stale')

    def test_missing_template_rejected(self):
        builder = self.builder()
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / 'apps/ddnsto/source/templates', root / 'ddnsto/templates')
            (root / 'ddnsto/templates/asus-service.sh.in').unlink()
            with self.assertRaises(ValueError):
                builder.render(root, self.config())
    def test_compatibility_gate_is_not_promoted_by_release(self):
        builder = self.builder()
        config = self.config()
        config['platforms']['linux']['client_version'] = '9.8.7'
        builder.render(ROOT, config)
        source = (ROOT / 'apps/ddnsto/source/managed-service.sh').read_text()
        self.assertIn('[ "${version_num:-}" = 4.2.8 ]', source)


if __name__ == '__main__':
    unittest.main()
