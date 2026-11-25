import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'sources/ddnsto/entry-progress.sh'


class Progress(unittest.TestCase):
    def test_wait_reports_stage_and_preserves_failure(self):
        result = subprocess.run(['sh', '-c', '. "$1"; ddnsto_entry_wait 测试阶段 sh -c "exit 11"', 'test', str(MODULE)],
            text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 11, result.stderr)
        self.assertIn('测试阶段', result.stderr)
        self.assertIn('下一步', result.stderr)

    def test_wait_reports_slow_stage_without_percentage(self):
        result = subprocess.run(['sh', '-c', '. "$1"; ddnsto_entry_wait 测试阶段 sleep 1.2', 'test', str(MODULE)],
            env=os.environ | {'DDNSTO_PROGRESS_INTERVAL': '1'}, text=True, capture_output=True, timeout=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('仍在处理', result.stderr)
        self.assertNotIn('%', result.stderr)

    def test_entry_announces_before_bootstrap(self):
        entry = (ROOT / 'apps/ddnsto/install.sh').read_text()
        self.assertIn('ddnsto_entry_wait', entry)
        self.assertIn('正在准备安装工具', entry)
        self.assertIn('正在获取安装信息', entry)


if __name__ == '__main__':
    unittest.main()
