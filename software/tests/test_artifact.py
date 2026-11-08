import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ENTRY=Path(__file__).resolve().parents[1]/'task.sh'

class LocalArtifact(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.base=Path(self.temp.name).resolve();self.source=self.base/'candidate';self.source.write_text('#!/bin/sh\nprintf "compiled self test ready\\n"\n');self.source.chmod(0o755)
        arch={'x86_64':'amd64','aarch64':'arm64'}[platform.machine()]
        self.req={'software':'built-example','targetId':'artifact-test','method':'artifact','version':'1.0.0','prefixBase':str(self.base),'artifact':{'path':str(self.source),'sha256':hashlib.sha256(self.source.read_bytes()).hexdigest(),'platform':'linux-'+arch,'verifyArgs':['--self-test'],'expectedOutput':'compiled self test ready'}}
        self.env={**os.environ,'ZSETUP_TASK_TARGET_ID':'artifact-test'}
    def call(self,op='plan'):
        f=self.base/'request.json';f.write_text(json.dumps(self.req));r=subprocess.run(['bash',str(ENTRY),op,str(f)],env=self.env,text=True,capture_output=True);return r,json.loads(r.stdout)
    def planapply(self,op='apply'):
        self.req.pop('plan',None);r,b=self.call();self.assertEqual(r.returncode,0,r.stderr+r.stdout);self.req['plan']=b['details'];return self.call(op)
    def test_local_artifact_lifecycle_verifies_and_preserves_foreign_files(self):
        r,b=self.call();self.assertEqual(r.returncode,0,r.stderr+r.stdout);self.assertFalse((self.base/'built-example').exists())
        r,b=self.planapply();self.assertEqual(r.returncode,0,r.stderr+r.stdout);self.assertEqual(b['reason'],'installed');command=Path(b['details']['command']);self.assertTrue(command.is_file())
        r,b=self.planapply();self.assertEqual(r.returncode,0,r.stderr+r.stdout);self.assertEqual(b['reason'],'reused')
        prefix=self.base/'built-example';(prefix/'user.conf').write_text('keep');self.req['intent']='remove';self.req.pop('artifact');r,b=self.planapply('remove');self.assertEqual(r.returncode,0,r.stderr+r.stdout);self.assertFalse(command.exists());self.assertEqual((prefix/'user.conf').read_text(),'keep')
    def test_source_change_after_plan_blocks_before_creation(self):
        r,b=self.call();self.assertEqual(r.returncode,0,r.stderr+r.stdout);self.req['plan']=b['details'];self.source.write_text('changed');r,b=self.call('apply');self.assertEqual(r.returncode,21,r.stderr+r.stdout);self.assertEqual(b['reason'],'artifact-digest-mismatch');self.assertFalse((self.base/'built-example').exists())
    def test_failed_new_binary_preserves_old_command(self):
        r,b=self.planapply();self.assertEqual(r.returncode,0,r.stderr+r.stdout);command=Path(b['details']['command']);before=command.read_bytes();self.source.write_text('#!/bin/sh\nexit 9\n');self.req['artifact']['sha256']=hashlib.sha256(self.source.read_bytes()).hexdigest();self.req['version']='2.0.0';r,b=self.planapply();self.assertEqual(r.returncode,22,r.stderr+r.stdout);self.assertEqual(b['nativeExitCode'],9);self.assertEqual(command.read_bytes(),before)
    def test_foreign_prefix_is_preserved(self):
        prefix=self.base/'built-example';prefix.mkdir();(prefix/'foreign').write_text('mine');r,b=self.call();self.assertEqual(r.returncode,21,r.stderr+r.stdout);self.assertEqual(b['reason'],'artifact-prefix-unowned');self.assertEqual((prefix/'foreign').read_text(),'mine')
    def test_remove_preserves_version_foreign_file_and_allows_same_binary_reinstall(self):
        r,b=self.planapply();self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        directory=self.base/'built-example/versions/1.0.0';(directory/'user.note').write_text('keep')
        self.req['intent']='remove';r,b=self.planapply('remove');self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        self.assertFalse((directory/'program').exists());self.assertEqual((directory/'user.note').read_text(),'keep')
        self.req.pop('intent');r,b=self.planapply();self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        self.assertEqual((directory/'user.note').read_text(),'keep')

    def test_wrong_platform_is_explicit_handoff(self):
        self.req['artifact']['platform']='windows-amd64';r,b=self.call();self.assertEqual(r.returncode,20,r.stderr+r.stdout);self.assertEqual(b['reason'],'artifact-platform-mismatch')

if __name__=='__main__':unittest.main()
