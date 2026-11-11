"""Guide contract checks; never download or execute a real installer."""
import os
from pathlib import Path
import re
import subprocess
import unittest


GUIDE = Path(__file__).resolve().parents[1] / 'agent/install.md'


class AgentGuideTest(unittest.TestCase):
    def test_required_boundaries_and_complete_document(self):
        text = GUIDE.read_text(encoding='utf-8')
        for required in ['仅测试环境', '用户一次明确确认', 'Agent 沙箱', 'Windows',
                         '不检查云端在线', '最多重试一次', '不得自动换绑',
                         '读取失败', '目前没有自动生成远程访问', '本地启动状态']:
            self.assertIn(required, text)
        version = re.search(r'文档版本：([0-9.]+)', text).group(1)
        self.assertTrue(text.rstrip().endswith(f'<!-- DDNSTO-AGENT-INSTALL-END v{version} -->'))

    def test_shell_recipe_passes_token_as_data(self):
        command = re.search(r'```sh\n(.*?)\n```', GUIDE.read_text(), re.S).group(1)
        token = "quote' spaces ; $(exit 99) `exit 98`"
        stub = "curl() { printf '%s\\n' 'test \"$1\" = --token && test \"$2\" = \"$EXPECTED_TOKEN\"'; }; "
        result = subprocess.run(['sh', '-c', stub + command], env={**os.environ, 'DDNSTO_TOKEN': token, 'EXPECTED_TOKEN': token})
        self.assertEqual(result.returncode, 0)

    def test_download_failure_stops(self):
        command = re.search(r'```sh\n(.*?)\n```', GUIDE.read_text(), re.S).group(1)
        result = subprocess.run(['sh', '-c', 'curl() { return 22; }; ' + command])
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
