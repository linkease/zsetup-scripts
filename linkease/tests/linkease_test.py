#!/usr/bin/env python3
"""Maintained business regressions now use protected paths in private namespaces.

Historical flat-path expectations are retained in git; coverage mapping lives
in docs/2026-10-16-regression-coverage.md. No host service/package mutation.
"""
import os
from pathlib import Path
import subprocess
import sys
root=Path(__file__).resolve().parents[2]
env=os.environ|{'ZSETUP_TEST_APP':'linkease'}
for suite in ['service_storage_test.py','package_storage_test.py']:
    subprocess.run([sys.executable,'-B',str(root/'tests'/suite),sys.argv[1]],env=env,check=True)
print('linkease maintained regression suites passed')
