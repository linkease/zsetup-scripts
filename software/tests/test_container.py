import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ENTRY=Path(__file__).resolve().parents[1]/"task.sh"
IMAGE="nginx@sha256:0985e772fb9f729e6fa0980da05fca5d9c468e870eed43071545afa9d2e27d94"

class ContainerContract(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.base=self.root/"apps";self.base.mkdir()
        self.bin=self.root/"bin";self.bin.mkdir();self.mutations=self.root/"mutations"
        docker=self.bin/"docker"
        docker.write_text("""#!/usr/bin/env python3
import json,sys,os
args=sys.argv[1:]
if args[:2]==['--context','default']:args=args[2:]
if args[:2]==['context','inspect']:
 print(json.dumps([{'Endpoints':{'docker':{'Host':os.environ.get('SIM_ENDPOINT','unix:///var/run/docker.sock')}}}]))
elif args[0]=='info':
 print(json.dumps({'ID':'fixture-daemon','Name':open('/proc/sys/kernel/hostname').read().strip(),'DockerRootDir':os.environ['SIM_DATA'],'Architecture':'x86_64','OSType':'linux'}))
elif args[:2]==['container','inspect']:
 print('Error: No such container',file=sys.stderr);sys.exit(1)
elif args[:2]==['image','inspect']:
 print('Error: No such image',file=sys.stderr);sys.exit(1)
elif args[0]=='ps':print('')
else:
 open(os.environ['SIM_MUTATIONS'],'a').write(' '.join(args)+'\\n');sys.exit(7)
""")
        docker.chmod(0o755)
        self.request={'software':'nginx-static','targetId':'container-test','method':'container','container':{'image':IMAGE,'baseDir':str(self.base),'dataBytes':1048576,'start':True}}
        self.env={**os.environ,'PATH':str(self.bin)+os.pathsep+os.environ['PATH'],'SIM_DATA':str(self.base),'SIM_MUTATIONS':str(self.mutations),'ZSETUP_TASK_TARGET_ID':'container-test'}

    def call(self,op='plan'):
        file=self.root/'request.json';file.write_text(json.dumps(self.request));r=subprocess.run(['bash',str(ENTRY),op,str(file)],env=self.env,text=True,capture_output=True)
        return r,json.loads(r.stdout)

    def test_plan_is_read_only_and_declares_security_storage_health(self):
        r,b=self.call();self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        d=b['details'];self.assertEqual(d['method'],'container');self.assertEqual(d['image']['reference'],IMAGE)
        self.assertEqual(d['security']['user'],'101:101');self.assertTrue(d['security']['readOnlyRoot'])
        self.assertEqual(d['endpointPolicy'],'loopback-ephemeral');self.assertEqual(d['dataRollback'],'separate-file-backup-required')
        self.assertEqual(len(d['storagePlan']['volumes']),1);self.assertFalse(self.mutations.exists());self.assertEqual(list(self.base.iterdir()),[])

    def test_remote_daemon_context_is_refused_before_any_mutation(self):
        self.env['SIM_ENDPOINT']='tcp://example.invalid:2375';r,b=self.call();self.assertEqual(r.returncode,21);self.assertEqual(b['reason'],'nonlocal-docker-context');self.assertFalse(self.mutations.exists())

    def test_unreviewed_mutable_image_tag_is_refused(self):
        self.request['container']['image']='nginx:alpine';r,b=self.call();self.assertEqual(r.returncode,20);self.assertEqual(b['reason'],'container-image-recipe-required');self.assertFalse(self.mutations.exists())

    def test_unowned_application_directory_is_preserved(self):
        r,b=self.call();self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        app=Path(b['details']['appDir']);app.mkdir();(app/'foreign').write_text('mine')
        r,b=self.call();self.assertEqual(r.returncode,21);self.assertEqual(b['reason'],'container-directory-unowned');self.assertEqual((app/'foreign').read_text(),'mine')

    def test_start_requires_explicit_request(self):
        self.request['container']['start']=False;r,b=self.call();self.assertEqual(r.returncode,21);self.assertEqual(b['reason'],'container-start-not-selected');self.assertFalse(self.mutations.exists())

    def test_apply_without_reviewed_plan_never_calls_docker_mutation(self):
        r,b=self.call('apply');self.assertEqual(r.returncode,21);self.assertEqual(b['reason'],'missing-plan');self.assertFalse(self.mutations.exists())

if __name__=='__main__':unittest.main()
