#!/usr/bin/env python3
"""Execute behavior tests; mocked service boundaries are not native canaries."""
from pathlib import Path
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent

if __name__ == "__main__":
    for test in ("operation_lock_test.py", "service_management_test.py", "rerun_test.py", "platform_selection_test.py", "plan_test.py", "docker_probe_test.py", "macos_behavior_test.py", "posix_input_test.py", "linux_service_test.py",
                 "entry_dispatch_test.py", "method_selection_test.py", "linux_lifecycle_test.py", "openwrt_lifecycle_test.py", "docker_lifecycle_test.py", "synology_download_test.py", "bootstrap_policy_test.py", "install_rules_test.py", "pinned_products_test.py"):
        subprocess.run([sys.executable, "-B", str(ROOT / test)], check=True)
    pwsh = os.environ.get("PWSH_BIN") or shutil.which("pwsh")
    if pwsh:
        for test in ("windows_repair_test.ps1", "windows_management_test.ps1", "windows_plan_test.ps1", "windows_behavior_test.ps1", "windows_bootstrap_test.ps1", "windows_lifecycle_test.ps1", "windows_menu_test.ps1"):
            subprocess.run([pwsh, "-NoProfile", "-File", str(ROOT / test)], check=True)
    else:
        print("SKIP Windows behavior: pwsh missing (set PWSH_BIN); not a Windows native pass")
