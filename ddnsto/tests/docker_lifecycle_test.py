#!/usr/bin/env python3
"""Isolated Docker/UID boundary fixtures; never elevate or use a real engine."""
import json
import os
import pty
import select
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'docker-lifecycle.sh'
IMAGE = 'linkease/ddnsto@sha256:f70d2afbb0da6b21ff8865a4f3d9869775360bfbec1fff03474e5478a702ad30'
CID = 'a' * 64
IID = 'sha256:' + 'b' * 64

# Stateful external-CLI substitute. Unknown commands fail; no real engine fallback.
DOCKER = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['FIXTURE'])
a = sys.argv[1:]
with (p/'calls').open('a') as f: f.write(json.dumps(a)+'\n')
if a[:2] == ['context', 'inspect']:
 print(os.environ['ENDPOINT']); sys.exit()
assert a[:2] == ['--host', os.environ['ENDPOINT']], a
assert not os.environ.get('DOCKER_CONTEXT'), 'context was not cleared'
a = a[2:]
state = p/'container.json'
c = json.loads(state.read_text()) if state.exists() else None
def save(): state.write_text(json.dumps(c))
def val(flag): return a[a.index(flag)+1]
if a[0] == 'info': print(os.environ.get('ENGINE','linux|x86_64|Ubuntu|[]'))
elif a[:2] == ['image','inspect']: print('sha256:'+'b'*64)
elif a[0] == 'pull':
 assert a[-1] == os.environ['PIN']
 if os.environ.get('FAIL_PULL'): sys.exit(7)
elif a[0] == 'ps':
 if os.environ.get('FAIL_PS'): sys.exit(8)
 if any(x.startswith('label=') for x in a):
  if os.environ.get('EXTRA_OWNED'): print('c'*64)
  elif c: print(c['id'])
  sys.exit()
 if c: print(c['id'])
elif a[0] == 'create':
 assert not c
 env = pathlib.Path(val('--env-file')).read_text().splitlines()
 c = dict(id='a'*64, running=False, image=a[-1], imageid='sha256:'+'b'*64,
          network=val('--network'), mount=val('--mount').split('src=')[1].split(',')[0],
          env=env, labels=['maintainer=Janson <janson@linkease.com>']+[a[i+1] for i,x in enumerate(a) if x=='--label'])
 save(); print(c['id'])
elif a[0] == 'inspect':
 if os.environ.get('FAIL_INSPECT'): sys.exit(10)
 assert c and a[-1] == c['id']
 fmt=val('--format')
 if fmt == '{{.State.Running}}': print(str(c['running']).lower())
 else:
  lines=['image='+c['image'], 'imageid='+c['imageid'], 'name=/ddnsto-managed',
   'network='+c['network'], 'restart=unless-stopped', 'user=', 'privileged=false',
   'attached_network='+c['network'],
   'cmd=["/usr/bin/ddnsto-monitor.sh"]', 'entrypoint=null', 'readonly=false', 'pid=',
   'ipc=private', 'caps=0|0', 'security=0', 'devices=0', 'ports=0',
   'groups=0', 'volumesfrom=0', 'device_requests=0', 'network_links=0',
   'mount=bind|'+c['mount']+'|/ddnsto-config|true|rprivate',
   'env=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
   'env=TZ=Asia/Shanghai', 'env=LOG_LEVEL=2']
  lines += ['env='+e for e in c['env']] + ['label='+x for x in c['labels']]
  lines += c.get('extra',[])
  print('\n'.join(lines))
elif a[0] in ['start','stop','restart']:
 assert c and a[-1] == c['id']
 if os.environ.get('FAIL_START') and a[0] != 'stop': sys.exit(9)
 c['running'] = a[0] != 'stop'; save()
elif a[0] == 'rm':
 assert c and not c['running'] and a[-1] == c['id']
 state.unlink()
else: raise AssertionError(a)
'''


class DockerLifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(self.sock.close)
        self.sock.bind(str(self.root/'engine.sock'))
        self.endpoint = 'unix://' + str(self.root/'engine.sock')
        tool = self.root/'docker'
        tool.write_text(DOCKER)
        tool.chmod(0o755)
        # Model root authorization without elevating this test process. Keep
        # real mode/link checks; translate only the fixture owner's UID to 0.
        for name, script in {
            'id': '#!/usr/bin/env python3\nimport os, sys\n'
                  'if sys.argv[1:] == ["-u"]: print(os.environ.get("FIXTURE_UID", "0"))\n'
                  'else: os.execv("/usr/bin/id", ["id"] + sys.argv[1:])\n',
            'stat': '#!/usr/bin/env python3\nimport os, subprocess, sys\n'
                    'r = subprocess.run(["/usr/bin/stat"] + sys.argv[1:], capture_output=True, text=True)\n'
                    'out = r.stdout\n'
                    'if len(sys.argv)>2 and sys.argv[1]=="-c" and sys.argv[2].startswith("%u:"):\n'
                    '    prefix=str(os.getuid())+":"\n'
                    '    if out.startswith(prefix): out="0:"+out[len(prefix):]\n'
                    'sys.stdout.write(out); sys.stderr.write(r.stderr); sys.exit(r.returncode)\n',
        }.items():
            path = self.root / name
            path.write_text(script)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root)+':/usr/bin:/bin',
            FIXTURE=str(self.root), ENDPOINT=self.endpoint, PIN=IMAGE,
            DOCKER_HOST='', DOCKER_CONTEXT='', REQUESTED_METHOD='docker',
            detected_platform='linux', DDNSTO_DOCKER_STATE_DIR=str(self.root/'private'),
            DDNSTO_BIN_PATH=str(self.root/'native'), DDNSTO_LINUX_CONFIG_DIR=str(self.root/'native-config'))

    def command(self, plan=False):
        return ['sh', '-eu', '-c', '. "$1"; . "$2"; ' +
                ('ddnsto_docker_plan' if plan else 'ddnsto_docker_lifecycle'),
                'fixture', str(SOURCE.parent / 'business.sh'), str(SOURCE)]

    def invoke(self, action='install', plan=False, **kw):
        self.assertTrue(SOURCE.exists(), 'missing Docker lifecycle implementation')
        env = dict(self.env, ACTION=action, **kw)
        return subprocess.run(self.command(plan), env=env, text=True, capture_output=True,
                              stdin=subprocess.DEVNULL, start_new_session=True, timeout=15)

    def interactive(self, action='install', answers=(), **kw):
        pid, terminal = pty.fork()
        if pid == 0:
            os.execvpe('sh', self.command(), dict(self.env, ACTION=action, **kw))
        output = b''
        sent = set()
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if not select.select([terminal], [], [], 0.1)[0]:
                    continue
                try:
                    part = os.read(terminal, 4096)
                except OSError:
                    break
                if not part:
                    break
                output += part
                for prompt, answer in answers:
                    if prompt in output and prompt not in sent:
                        os.write(terminal, answer + b'\n')
                        sent.add(prompt)
            else:
                os.kill(pid, 15)
                self.fail('unexpected prompt or blocked interactive installer: ' + output.decode())
        finally:
            os.close(terminal)
            _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status), output.decode(), sent

    def test_fresh_interactive_prompts_visible_token_name_and_network(self):
        answers = [(b'DDNSTO token:', b'visible-fixture-token'),
                   (b'Docker device name:', b'fixture_nas'),
                   (b'Docker network [bridge/host]:', b'bridge')]
        code, output, sent = self.interactive(answers=answers)
        self.assertEqual(code, 0, output)
        self.assertEqual(sent, {prompt for prompt, _ in answers})
        self.assertIn('visible-fixture-token', output)
        self.assertEqual((self.root/'private/container.env').read_text(),
                         'TOKEN=visible-fixture-token\nDEVICE_NAME=fixture_nas\n')
        self.assertNotIn('visible-fixture-token', json.dumps(self.calls()))

    def test_interactive_only_prompts_for_missing_fields(self):
        code, output, sent = self.interactive(TOKEN='supplied-token', DEVICE_NAME='supplied-name',
            answers=[(b'Docker network [bridge/host]:', b'host')])
        self.assertEqual(code, 0, output)
        self.assertEqual(sent, {b'Docker network [bridge/host]:'})
        self.assertNotIn('DDNSTO token:', output)
        self.assertNotIn('Docker device name:', output)

    def test_invalid_interactive_answers_fail_before_any_mutation(self):
        for inputs, answers in [
            ({}, [(b'DDNSTO token:', b'')]),
            ({'TOKEN': 'safe-token'}, [(b'Docker device name:', b'bad name')]),
            ({'TOKEN': 'safe-token', 'DEVICE_NAME': 'safe-name'},
             [(b'Docker network [bridge/host]:', b'')]),
        ]:
            with self.subTest(inputs=inputs):
                code, output, sent = self.interactive(answers=answers, **inputs)
                self.assertEqual(code, 2, output)
                self.assertEqual(sent, {prompt for prompt, _ in answers})
        self.assertFalse(self.mutations())
        self.assertFalse((self.root/'private').exists())

    def test_nonroot_write_actions_fail_before_prompts_with_root_shell_guidance(self):
        for action in ['install', 'update', 'start', 'stop', 'restart', 'repair', 'uninstall']:
            with self.subTest(action=action):
                r = self.invoke(action, FIXTURE_UID='1000', TOKEN='t', DEVICE_NAME='n', NETWORK='bridge')
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertIn('sudo -i', r.stderr)
                self.assertIn('root', r.stderr)
        self.assertFalse(self.calls())
        self.assertFalse((self.root/'private').exists())

    def test_nonroot_status_and_plan_remain_readonly(self):
        r = self.invoke('status', FIXTURE_UID='1000')
        self.assertNotEqual(r.returncode, 0)  # no container, not a privilege rejection
        self.assertNotIn('sudo', r.stderr)
        self.assertTrue(self.calls())
        r = self.invoke(plan=True, FIXTURE_UID='1000')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.mutations())

    @unittest.skipIf(os.geteuid() == 0, 'requires an actual unprivileged test process')
    def test_real_nonroot_uid_cannot_write_even_with_complete_inputs(self):
        command = self.command()
        command[3] = 'id() { /usr/bin/id "$@"; }; ' + command[3]
        result = subprocess.run(command, env=dict(self.env, ACTION='install', TOKEN='safe-token',
            DEVICE_NAME='safe-name', NETWORK='bridge'), text=True, capture_output=True,
            stdin=subprocess.DEVNULL, start_new_session=True, timeout=15)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('sudo -i', result.stderr)
        self.assertFalse(self.calls())
        self.assertFalse((self.root/'private').exists())

    def test_existing_container_never_prompts_or_reads_token_file(self):
        self.install()
        before = len(self.mutations())
        for action in ['install', 'update', 'status']:
            code, output, _ = self.interactive(action)
            self.assertEqual(code, 0, output)
            self.assertNotIn('DDNSTO token:', output)
            self.assertNotIn('Docker device name:', output)
        fifo = self.root/'token-fifo'
        os.mkfifo(fifo)
        code, output, _ = self.interactive(TOKEN_FILE=str(fifo))
        self.assertNotEqual(code, 0)
        self.assertNotIn('DDNSTO token:', output)
        self.assertEqual(len(self.mutations()), before)

    def test_conflicts_and_retained_state_never_prompt(self):
        for kwargs in [dict(EXTRA_OWNED='1'), dict(FAIL_PS='1')]:
            code, output, _ = self.interactive(**kwargs)
            self.assertNotEqual(code, 0)
            self.assertNotIn('DDNSTO token:', output)
        (self.root/'native').write_text('native-conflict')
        code, output, _ = self.interactive()
        self.assertNotEqual(code, 0)
        self.assertNotIn('DDNSTO token:', output)
        (self.root/'native').unlink()
        (self.root/'private').mkdir(mode=0o700)
        code, output, _ = self.interactive()
        self.assertNotEqual(code, 0)
        self.assertNotIn('DDNSTO token:', output)
        self.assertFalse(self.mutations())

    def calls(self):
        p = self.root/'calls'
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []

    def mutations(self):
        return [a for a in self.calls() if a[0]=='--host' and a[2] in ('pull','create','start','stop','restart','rm','update','rename')]

    def install(self):
        r = self.invoke(TOKEN='fixture-token', DEVICE_NAME='nas_a', NETWORK='bridge')
        self.assertEqual(r.returncode,0,r.stderr)
        return r

    def test_install_pins_image_and_persists_private_inputs(self):
        r=self.install()
        self.assertIn('container_running=true',r.stdout)
        self.assertIn('cloud_status=unverified',r.stdout)
        self.assertNotIn('healthy',r.stdout)
        p=self.root/'private'
        self.assertEqual((p.stat().st_mode & 0o777),0o700)
        self.assertEqual(((p/'container.env').stat().st_mode & 0o777),0o600)
        self.assertTrue((p/'identity').is_dir())
        self.assertNotIn('fixture-token',json.dumps(self.calls())+r.stdout+r.stderr)
        create=next(a for a in self.calls() if 'create' in a)
        self.assertEqual(create[-1],IMAGE)
        self.assertIn('unless-stopped',create)

    def test_plan_is_readonly_and_does_not_read_token_file(self):
        r=self.invoke(plan=True,TOKEN_FILE='/does/not/exist')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('installation_performed=false',r.stdout)
        self.assertFalse((self.root/'private').exists())
        self.assertFalse(self.mutations())

    def test_remote_context_never_contacted(self):
        self.env.update(DOCKER_CONTEXT='remote',ENDPOINT='ssh://other')
        r=self.invoke(plan=True)
        self.assertNotEqual(r.returncode,0)
        self.assertTrue(all(a[0]=='context' for a in self.calls()))

    def test_engine_and_platform_rejections(self):
        for engine in ['linux|x86_64|Docker Desktop|[]','linux|x86_64|Ubuntu|[name=rootless]',
                       'linux|aarch64|Ubuntu|[]','windows|x86_64|Windows|[]']:
            with self.subTest(engine=engine):
                r=self.invoke(plan=True,ENGINE=engine)
                self.assertNotEqual(r.returncode,0)
        r=self.invoke(plan=True,detected_platform='synology')
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(self.mutations())

    def test_fresh_requires_network_name_and_safe_token(self):
        for inputs in [dict(), dict(DEVICE_NAME='nas',NETWORK='bridge'),
                       dict(TOKEN='t',DEVICE_NAME='nas'),dict(TOKEN='t',NETWORK='bridge'),
                       dict(TOKEN='t bad',DEVICE_NAME='nas',NETWORK='host'),
                       dict(TOKEN='t',DEVICE_NAME='bad *',NETWORK='bridge'),
                       dict(TOKEN='t',DEVICE_NAME='nas',NETWORK='other'),
                       dict(TOKEN='t',DEVICE_NAME='nas',NETWORK='bridge',DEVICE_IDX='7')]:
            with self.subTest(inputs=inputs):
                self.assertNotEqual(self.invoke(**inputs).returncode,0)
        self.assertFalse(self.mutations())
        self.assertFalse((self.root/'private').exists())

    def test_native_and_symlink_conflicts(self):
        (self.root/'native').write_text('existing')
        self.assertNotEqual(self.invoke(TOKEN='t',DEVICE_NAME='n',NETWORK='bridge').returncode,0)
        (self.root/'native').unlink()
        (self.root/'private').symlink_to(self.root, target_is_directory=True)
        self.assertNotEqual(self.invoke(TOKEN='t',DEVICE_NAME='n',NETWORK='bridge').returncode,0)
        self.assertFalse(self.mutations())

    def test_rerun_and_same_pin_update_do_not_recreate(self):
        self.install(); before=len(self.mutations())
        for action in ['install','update']:
            r=self.invoke(action)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertIn('operation=none',r.stdout)
        self.assertEqual(len(self.mutations()),before)

    def test_conflicting_owned_container_is_not_an_empty_host(self):
        r=self.invoke(TOKEN='t',DEVICE_NAME='n',NETWORK='bridge',EXTRA_OWNED='1')
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(self.mutations())

    def test_uninstall_retained_state_cannot_be_silently_recreated(self):
        self.install()
        self.assertEqual(self.invoke('uninstall').returncode,0)
        before=len(self.mutations())
        r=self.invoke()
        self.assertNotEqual(r.returncode,0)
        self.assertIn('identity',r.stderr)
        self.assertEqual(len(self.mutations()),before)

    def test_altered_mount_network_image_token_or_identity_rejected(self):
        self.install(); p=self.root/'container.json'; original=json.loads(p.read_text())
        before=len(self.mutations())
        for key,value in [('mount','/foreign'),('network','host'),('image','foreign:latest'),
                          ('imageid','sha256:'+'c'*64),('env',['TOKEN=other','DEVICE_NAME=nas_a']),
                          ('id','d'*64),('labels',[])]:
            with self.subTest(key=key):
                p.write_text(json.dumps(original|{key:value}))
                r=self.invoke('uninstall')
                self.assertNotEqual(r.returncode,0)
        self.assertEqual(len(self.mutations()),before)

    def test_sensitive_state_permissions_are_enforced(self):
        self.install(); p=self.root/'private'/'container.env'
        before=len(self.mutations()); p.chmod(0o644)
        self.assertNotEqual(self.invoke('start').returncode,0)
        p.chmod(0o600)
        (self.root/'private'/'identity').chmod(0o777)
        self.assertNotEqual(self.invoke('start').returncode,0)
        self.assertEqual(len(self.mutations()),before)

    def test_management_rejects_credentials_and_inspect_failure(self):
        self.install(); before=len(self.mutations())
        for kwargs in [dict(TOKEN='replacement'),dict(NETWORK='host'),dict(FAIL_INSPECT='1')]:
            r=self.invoke('stop',**kwargs)
            self.assertNotEqual(r.returncode,0)
        self.assertEqual(len(self.mutations()),before)

    def test_pull_failure_does_not_create_state(self):
        r=self.invoke(TOKEN='t',DEVICE_NAME='n',NETWORK='bridge',FAIL_PULL='1')
        self.assertEqual(r.returncode,11)
        self.assertFalse((self.root/'private').exists())
        self.assertFalse(any('create' in a for a in self.calls()))

    def test_explicit_remote_host_and_context_precedence(self):
        r=self.invoke(plan=True,DOCKER_HOST='tcp://remote:2375')
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(self.calls())
        r=self.invoke(plan=True,DOCKER_CONTEXT='local',DOCKER_HOST='tcp://remote:2375')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue(any(a[:2]==['--host',self.endpoint] for a in self.calls()))

    def test_malformed_info_missing_security_fields_rejected(self):
        for engine in ['linux|x86_64|Ubuntu|', 'linux|x86_64|Ubuntu|null', 'linux|x86_64|Ubuntu|garbage']:
            with self.subTest(engine=engine):
                self.assertNotEqual(self.invoke(plan=True,ENGINE=engine).returncode,0)

    def test_extra_network_or_unterminated_env_data_rejected(self):
        self.install(); p=self.root/'container.json'; original=json.loads(p.read_text())
        before=len(self.mutations())
        p.write_text(json.dumps(original|{'extra':['attached_network=foreign']}))
        self.assertNotEqual(self.invoke('stop').returncode,0)
        p.write_text(json.dumps(original))
        with (self.root/'private'/'container.env').open('a') as f: f.write('EXTRA=hidden')
        self.assertNotEqual(self.invoke('stop').returncode,0)
        self.assertEqual(len(self.mutations()),before)

    def test_preparsed_token_file_is_not_reread(self):
        r=self.invoke(TOKEN='parsed-token',TOKEN_FILE='/not/read/by/executor',DEVICE_NAME='nas',NETWORK='bridge')
        self.assertEqual(r.returncode,0,r.stderr)

    def test_openwrt_options_are_rejected_before_pull(self):
        for kwargs in [dict(FORCE_VERSION='standard'),dict(VERIFY_STATUS='1')]:
            self.assertNotEqual(self.invoke(TOKEN='t',DEVICE_NAME='n',NETWORK='bridge',**kwargs).returncode,0)
        self.assertFalse(self.mutations())

    def test_method_and_native_config_constraints(self):
        r=self.invoke(plan=True,REQUESTED_METHOD='native')
        self.assertNotEqual(r.returncode,0)
        (self.root/'native-config').mkdir()
        self.assertNotEqual(self.invoke(TOKEN='t',DEVICE_NAME='n',NETWORK='host').returncode,0)
        self.assertFalse(self.mutations())

    def test_lifecycle_and_uninstall_keep_state(self):
        self.install()
        private=self.root/'private'
        (private/'identity'/'fixture-id').write_text('preserve-me')
        original=(private/'container.env').read_bytes()
        for action, running in [('stop','false'),('status','false'),('start','true'),('restart','true'),('repair','true')]:
            r=self.invoke(action)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertIn('container_running='+running,r.stdout)
        r=self.invoke('uninstall')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse((self.root/'container.json').exists())
        self.assertEqual((private/'container.env').read_bytes(),original)
        self.assertEqual((private/'identity'/'fixture-id').read_text(),'preserve-me')

    def test_tampered_container_rejected_before_mutation(self):
        self.install(); before=len(self.mutations())
        p=self.root/'container.json'; c=json.loads(p.read_text())
        c['extra']=['label=foreign=true']; p.write_text(json.dumps(c))
        for action in ['install','update','start','stop','restart','uninstall','repair']:
            self.assertNotEqual(self.invoke(action).returncode,0)
        self.assertEqual(len(self.mutations()),before)

    def test_failed_query_is_not_absence(self):
        r=self.invoke(TOKEN='t',DEVICE_NAME='n',NETWORK='host',FAIL_PS='1')
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(self.mutations())

    def test_failed_start_retains_repairable_container_and_private_state(self):
        r=self.invoke(TOKEN='t',DEVICE_NAME='n',NETWORK='host',FAIL_START='1')
        self.assertNotEqual(r.returncode,0)
        self.assertTrue((self.root/'private'/'container.env').is_file())
        self.assertTrue((self.root/'container.json').exists())
        r=self.invoke('repair')
        self.assertEqual(r.returncode,0,r.stderr)

    def test_missing_container_repair_and_update_fail_closed(self):
        self.install(); (self.root/'container.json').unlink()
        before=len(self.mutations())
        for action in ['repair','update','install']:
            r=self.invoke(action)
            self.assertNotEqual(r.returncode,0)
        self.assertEqual(len(self.mutations()),before)


if __name__=='__main__': unittest.main()
