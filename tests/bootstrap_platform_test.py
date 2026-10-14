#!/usr/bin/env python3
import os,pathlib,subprocess,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class Platform(unittest.TestCase):
    def test_os_and_arch_choose_the_matching_artifact_and_stable_pointer(self):
        for system,arch,artifact,stable in [('Linux','x86_64','zsetup-linux-x86_64','zsetup/stable'),('Darwin','x86_64','zsetup-macos-x86_64','zsetup/stable-macos'),('Darwin','arm64','zsetup-macos-aarch64','zsetup/stable-macos')]:
            with tempfile.TemporaryDirectory() as name:
                root=pathlib.Path(name);fake=root/'uname'
                fake.write_text('#!/bin/sh\ncase "$1" in -s) echo '+system+';; -m) echo '+arch+';; *) exit 2;; esac\n');fake.chmod(0o755)
                env={**os.environ,'PATH':str(root)+os.pathsep+os.environ['PATH']}
                command='. "'+str(ROOT/'lib/bootstrap.sh')+'"; bootstrap_arch; printf "%s\\n" "$ZSETUP_ARTIFACT" "$ZSETUP_STABLE_PATH"'
                result=subprocess.run(['sh','-c',command],env=env,capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(result.stdout.splitlines(),[artifact,stable])
if __name__=='__main__':unittest.main()
