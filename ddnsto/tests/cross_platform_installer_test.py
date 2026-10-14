#!/usr/bin/env python3
"""Execute behavior tests; mocked service boundaries are not native canaries."""
from pathlib import Path
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent

if __name__ == "__main__":
    for test in ("macos_behavior_test.py", "posix_input_test.py", "linux_service_test.py"):
        subprocess.run([sys.executable, "-B", str(ROOT / test)], check=True)
    pwsh = os.environ.get("PWSH_BIN") or shutil.which("pwsh")
    if pwsh:
        for test in ("windows_behavior_test.ps1", "windows_bootstrap_test.ps1"):
            subprocess.run([pwsh, "-NoProfile", "-File", str(ROOT / test)], check=True)
    else:
        print("SKIP Windows behavior: pwsh missing (set PWSH_BIN); not a Windows native pass")
