import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ENTRY=Path(__file__).resolve().parents[1]/'task.sh'


class BackupContract(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve();self.source=self.root/'source';self.source.mkdir()
        (self.source/'config').write_text('preserve me')
        self.base=self.root/'backups';self.base.mkdir()
        self.tool=self.root/'linkspace'
        self.tool.write_text('#!/bin/sh\nif [ "$1:$2" = backup:version ]; then printf \'{"result":{"version":"test"}}\\n\'; exit 0; fi\nprintf "backup backend failed\\n" >&2\nexit 9\n')
        self.tool.chmod(0o755)
        self.request={'software':'jq','targetId':'backup-test','backup':{'scope':'application-config','source':str(self.source),'baseDir':str(self.base),'requiredBytes':1048576,'consistency':'file-level'}}

    def call(self,op):
        p=self.root/'request.json';p.write_text(json.dumps(self.request))
        r=subprocess.run(['bash',str(ENTRY),op,str(p)],env={**os.environ,'ZSETUP_TASK_TARGET_ID':'backup-test','LINKSPACE_BIN':str(self.tool)},text=True,capture_output=True)
        return r,json.loads(r.stdout)

    def test_plan_does_not_create_repository_or_scan_source(self):
        r,body=self.call('backup-plan')
        self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        self.assertEqual(body['effects'],[])
        self.assertEqual(body['details']['consistency'],'file-level')
        self.assertEqual(list(self.base.iterdir()),[])
        self.assertEqual((self.source/'config').read_text(),'preserve me')

    def test_backup_destination_must_not_be_inside_source(self):
        self.request['backup']['source']=str(self.root)
        r,body=self.call('backup-plan')
        self.assertEqual(r.returncode,21)
        self.assertEqual(body['reason'],'backup-source-destination-overlap')

    def test_file_backup_does_not_claim_database_consistency(self):
        self.request['backup']['requiresApplicationConsistency']=True
        r,body=self.call('backup-plan')
        self.assertEqual(r.returncode,20)
        self.assertEqual(body['reason'],'application-consistency-hook-required')

    def test_failed_required_backup_does_not_begin_installation(self):
        self.request.update({'method':'owner','version':'1.8.2','prefixBase':str(self.root),'backupRequired':True})
        r,body=self.call('plan');self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        self.request['plan']=body['details']
        r,body=self.call('apply')
        self.assertEqual(r.returncode,22)
        self.assertEqual(body['reason'],'backup-failed')
        self.assertEqual(body['nativeExitCode'],9)
        self.assertFalse((self.root/'jq').exists())


if __name__=='__main__':unittest.main()
