"""A real CA and server-only leaf accepted by both Zig and canonical webpki."""
from pathlib import Path
import subprocess

def generate_certificate(directory: Path) -> None:
    def run(*args):
        subprocess.run(['openssl', *map(str,args)],check=True,capture_output=True)
    run('req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=fixture CA',
        '-addext','basicConstraints=critical,CA:TRUE','-keyout',directory/'ca.key','-out',directory/'ca.crt')
    run('req','-new','-newkey','rsa:2048','-nodes','-subj','/CN=127.0.0.1',
        '-keyout',directory/'server.key','-out',directory/'server.csr')
    (directory/'extensions').write_text('subjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\n')
    run('x509','-req','-in',directory/'server.csr','-CA',directory/'ca.crt','-CAkey',directory/'ca.key',
        '-CAcreateserial','-out',directory/'server.crt','-days','1','-extfile',directory/'extensions')
