import os
from pathlib import Path
import subprocess
import unittest

ROOT=Path(__file__).resolve().parents[1]
class BashCompatibility(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('ZSETUP_TEST_BASH32'), 'requires explicit real Bash 3.2')
    def test_all_shared_modules_parse_on_the_minimum_bash(self):
        bash=os.environ['ZSETUP_TEST_BASH32']
        version=subprocess.check_output([bash,'-c','printf %s "$BASH_VERSION"'],text=True)
        self.assertTrue(version.startswith('3.2.'), version)
        for script in ROOT.glob('*.sh'):
            with self.subTest(script=script.name):
                result=subprocess.run([bash,'-n',str(script)],text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stderr)
