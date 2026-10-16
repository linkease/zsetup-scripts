#!/usr/bin/env python3
"""Do not bootstrap new storage installers with old native protocol versions."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as name:
    stable=Path(name)/'stable'
    for version,valid in [('0.2.4',False),('0.4.0',False),('0.4.99',False),('0.5.0',True),('0.5.1',True),('0.6.0',True),('1.0.0',True)]:
        stable.write_text(version+'\n')
        proc=subprocess.run(['sh','-eu','-c','. "$1"; read_stable_version "$2"','minimum',str(root/'lib/bootstrap.sh'),str(stable)])
        assert (proc.returncode==0)==valid,version
print('minimum native: old storage-incompatible releases refused, 0.5+ accepted')
