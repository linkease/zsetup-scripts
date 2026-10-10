#!/usr/bin/env python3
"""Native PS5.1 dependency bootstrap; local TLS/files only, no business actions."""
import argparse, base64, collections, hashlib, http.server, json, os, pathlib
import ssl, struct, subprocess, sys, tempfile, threading, traceback
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests"))
from tls_fixture import generate_certificate

ROOT = pathlib.Path(__file__).resolve().parents[2]

def main():
    p = argparse.ArgumentParser()
    p.add_argument("binary", type=pathlib.Path)
    p.add_argument("--report", type=pathlib.Path)
    a = p.parse_args()
    assert (ROOT / "lib/bootstrap.ps1").is_file(), "shared Windows bootstrap is not implemented"
    assert os.name == "nt", "native Windows required; compiling is not evidence"
    binary = a.binary.resolve()
    data = binary.read_bytes()
    version = subprocess.check_output([str(binary), "--version"], text=True).strip().removeprefix("zsetup ")
    sha = hashlib.sha256(data).hexdigest()
    artifact = "zsetup-windows-i686.exe"
    script = ROOT / "lib/bootstrap.ps1"
    ps = str(pathlib.Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
    cases = []
    with tempfile.TemporaryDirectory(prefix="zsetup-bootstrap-中文 空格-") as directory:
        root = pathlib.Path(directory)
        generate_certificate(root)
        routes = {}
        hits = collections.Counter()
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                hits[self.path] += 1
                value = routes.get(self.path)
                if value is None:
                    self.send_error(404); return
                self.send_response(200)
                self.send_header("Content-Length", str(len(value)))
                self.end_headers(); self.wfile.write(value)
        servers = []
        for secure in (True, False):
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            if secure:
                ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                ctx.load_cert_chain(root / "server.crt", root / "server.key")
                server.socket = ctx.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever)
            thread.start(); servers.append((server,thread))
        https = f"https://127.0.0.1:{servers[0][0].server_port}"
        plaintext_base = f"https://127.0.0.1:{servers[1][0].server_port}" # bootstrap must first try HTTPS
        def serve(prefix, v=version, payload=data, digest=sha, sums=True):
            routes[prefix+"/zsetup/stable-windows"] = (v+"\n").encode()
            if sums: routes[prefix+f"/zsetup/{v}/SHA256SUMS"] = (digest+"  "+artifact+"\n").encode()
            routes[prefix+f"/zsetup/{v}/{artifact}"] = payload
        def run(name, bases, *, fallback="", work=None, ca=True, confirm=None):
            work = work or root/name
            config = {"script":str(script), "bases":bases, "fallback":fallback, "work":str(work)}
            encoded_config = base64.b64encode(json.dumps(config).encode()).decode()
            code = "$ProgressPreference='SilentlyContinue';[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);"
            code += "$c=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+encoded_config+"'))|ConvertFrom-Json;. $c.script;"
            code += "$script:BootstrapPrimaryBases=@($c.bases);$script:BootstrapFallbackBase=$c.fallback;"
            code += "try {$env:ZSETUP_ROOT=$c.work;$active=Get-ZsetupBootstrap;[Console]::WriteLine($active);exit 0}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}"
            env = {**os.environ,"ZSETUP_ROOT":str(work)}
            for key in ("ZSETUP_BIN","ZSETUP_BOOTSTRAP_BASES","ZSETUP_CONFIRM_FILE","ZSETUP_CA_FILE"): env.pop(key,None)
            if ca: env["ZSETUP_CA_FILE"]=str(root/"ca.crt")
            if confirm:
                f = root/(name+".answer");f.write_text(confirm+"\n");env["ZSETUP_CONFIRM_FILE"]=str(f)
            argv=[ps,"-NoProfile","-NonInteractive","-EncodedCommand",base64.b64encode(code.encode("utf-16-le")).decode()]
            return subprocess.run(argv,env=env,capture_output=True,timeout=55),work
        def check(name, fn):
            try:
                fn();cases.append(dict(case=name,passed=True))
            except Exception:
                cases.append(dict(case=name,passed=False,error=traceback.format_exc()))
        def success_cache():
            serve("/good")
            r,w=run("good",[https+"/good"]);assert r.returncode==0,(r.stdout,r.stderr)
            expected=w/"rescue"/version/"zsetup.exe";assert expected.read_bytes()==data
            hit=hits[f"/good/zsetup/{version}/{artifact}"]
            r,_=run("again",[https+"/good"],work=w);assert r.returncode==0,(r.stdout,r.stderr)
            assert hits[f"/good/zsetup/{version}/{artifact}"]==hit,"verified cache redownloaded"
            expected.write_bytes(b"corrupt")
            r,_=run("repair",[https+"/good"],work=w);assert r.returncode==0,(r.stdout,r.stderr)
            assert hits[f"/good/zsetup/{version}/{artifact}"]==hit+1 and expected.read_bytes()==data
            assert not list(w.rglob("*.candidate*")) and not list(w.rglob("*.stdout*"))
        def fallback_order():
            serve("/last")
            r,_=run("fallback",[https+"/missing1",https+"/missing2",https+"/missing3"],fallback=https+"/last")
            assert r.returncode==0,(r.stdout,r.stderr)
            assert all(hits[p+"/zsetup/stable-windows"]==1 for p in ("/missing1","/missing2","/missing3","/last"))
        def reject(name, prefix, payload=data, digest=sha, v=version, sums=True):
            serve(prefix,v,payload,digest,sums)
            w=root/name;target=w/"rescue"/v/"zsetup.exe";target.parent.mkdir(parents=True);target.write_bytes(b"preserved old file")
            r,_=run(name,[https+prefix],work=w)
            assert r.returncode==1,(r.stdout,r.stderr)
            assert target.read_bytes()==b"preserved old file"
            assert not list(w.rglob("*.candidate*")),"candidate leaked"
        def wrong_arch():
            payload=bytearray(data);offset=struct.unpack_from("<I",payload,0x3c)[0];struct.pack_into("<H",payload,offset+4,0x8664)
            reject("arch","/arch",bytes(payload),hashlib.sha256(payload).hexdigest())
        def denied_tls():
            serve("/untrusted")
            r,_=run("untrusted",[https+"/untrusted"],ca=False)
            assert r.returncode==1 and hits["/untrusted/zsetup/stable-windows"]==0,(r.stdout,r.stderr)
            serve("/wrongname")
            r,_=run("wrongname",[https.replace("127.0.0.1","localhost")+"/wrongname"])
            assert r.returncode==1 and hits["/wrongname/zsetup/stable-windows"]==0,(r.stdout,r.stderr)
        def http_confirmation():
            serve("/plain")
            before=sum(hits.values())
            r,_=run("plain-no",[plaintext_base+"/plain"],confirm="n");assert r.returncode==1,(r.stdout,r.stderr)
            assert sum(hits.values())==before,"HTTP used without consent"
            r,_=run("plain-noninteractive",[plaintext_base+"/plain"]);assert r.returncode==1,(r.stdout,r.stderr)
            assert sum(hits.values())==before
            r,w=run("plain-yes",[plaintext_base+"/plain"],confirm="yes");assert r.returncode==0,(r.stdout,r.stderr)
            assert (w/"rescue"/version/"zsetup.exe").read_bytes()==data
            assert b"accepted" in r.stderr.lower(),r.stderr
        try:
            check("native-win32-bootstrap-unicode-verified-cache-and-corruption-repair",success_cache)
            check("three-primary-exhaustion-before-final-fallback",fallback_order)
            check("wrong-digest-preserves-old-cache-and-cleans-candidate",lambda:reject("digest","/digest",digest="0"*64))
            check("missing-checksum-refuses-first-execution",lambda:reject("sums","/sums",sums=False))
            check("wrong-complete-version-refuses-activation",lambda:reject("version","/version",v="0.3.1"))
            check("non-i386-pe-refused-before-execution",wrong_arch)
            check("untrusted-root-and-hostname-mismatch-refused",denied_tls)
            check("http-bootstrap-denied-without-explicit-consent-and-accepted-once",http_confirmation)
        finally:
            for server,thread in servers:server.shutdown();server.server_close();thread.join(timeout=5);assert not thread.is_alive()
    report=dict(platform="Windows native PS5.1 HTTPS bootstrap",native_execution=True,passed=sum(c["passed"] for c in cases),cases=cases)
    print(json.dumps(report,ensure_ascii=False,indent=2))
    if a.report:a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    return 0 if all(c["passed"] for c in cases) else 1
if __name__=="__main__":raise SystemExit(main())
