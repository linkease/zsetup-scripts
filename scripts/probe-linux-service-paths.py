#!/usr/bin/env python3
"""Inspect real business service generation in a disposable user namespace.

No host service action: chroot, private mounts/PIDs/network, read-only system
tools, private /etc, fake systemctl. Products never enter a release package.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASES = ["https://dl.istoreos.com/binary", "https://fw.d4ctech.com/binary", "https://fw20.koolcenter.com/binary"]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zsetup", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--application", choices=["ddnsto", "linkease"])
    parser.add_argument("--scope", choices=["system", "user"], default="system")
    parser.add_argument("--init-system", choices=["systemd", "sysv"], default="systemd")
    parser.add_argument("--repeat-register", action="store_true")
    parser.add_argument("--replace-before-repeat", action="store_true")
    parser.add_argument("--native-owner", action="store_true")
    args = parser.parse_args()
    native = str(args.zsetup.resolve())
    previous = json.loads(args.report.read_text())["probes"] if args.report.exists() else []
    rows = [row for row in previous if args.application and row["application"] != args.application]
    measurements = json.loads((ROOT / "docs/2026-10-16-storage-measurements.json").read_text())["observations"]
    with tempfile.TemporaryDirectory(prefix="business-service-probe-") as name:
        work = Path(name)
        for app, version, member, invocation in [
            ("ddnsto", "4.2.3", "ddnsto-standard-4.2.3/ddnsto.x86_64", ["-u", "storage-probe-invalid-token", "-daemon"]),
            ("linkease", "1.7.5", "linkease-binary-1.7.5/linkease.x86_64", ["--serviceControl", "install"]),
        ]:
            if args.application and app != args.application: continue
            row = next(r for r in measurements if r["application"] == app and r["kind"] == "tar")
            archive = work / f"{app}.tar.gz"
            subprocess.run([native, "download", "--quiet", "-o", str(archive), "--sha256", row["sha256"], "--max-bytes", "134217728", "--min-free-bytes", "67108864", "--overall-timeout", "120s", *[f"{base}/{row['path']}" for base in BASES], "--fallback-url", f"https://fw.koolcenter.com/binary/{row['path']}"], check=True)
            jail = work / app
            program = jail / f"opt/linkease/{app}/versions/{version}/bin/{app}"
            program.parent.mkdir(parents=True)
            subprocess.run([native, "capture", "-o", str(program), "--max-bytes", "67108864", "--", "tar", "-xOzf", str(archive), member], check=True)
            program.chmod(0o755)
            for folder in ["usr", "bin", "lib", "lib64", "proc", "dev", "tmp", "root", "home/user", "run/systemd/system", "var/run", "var/log", "etc/systemd/system", "etc/init.d", "sandbox-bin"]:
                (jail / folder).mkdir(parents=True, exist_ok=True)
            (jail / "etc/os-release").write_text('ID=ubuntu\nVERSION_ID="22.04"\n')
            (jail / "etc/passwd").write_text("root:x:0:0::/root:/bin/sh\nuser:x:1000:1000::/home/user:/bin/sh\n")
            if args.init_system == "sysv":
                (jail / "run/systemd/system").rmdir()
            (jail / "sandbox-bin/systemctl").write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> /actions\ncase "$1" in --version) echo "systemd 249" ;; status) exit 3 ;; is-enabled) exit 1 ;; esac\nexit 0\n')
            (jail / "sandbox-bin/systemctl").chmod(0o755)
            (jail / "probe.sh").write_text('#!/bin/sh\nid -u > /effective-uid\n"$@"\nprobe_code=$?\nprintf "%s\\n" "$probe_code" > /program-exit\nexit 0\n')
            if args.repeat_register:
                (jail / "probe.sh").write_text('''#!/bin/sh
id -u > /effective-uid
original=$1; shift
"$original" "$@"
cp "$original" "$original.next"
"$original.next" "$@"
probe_code=$?
printf '%s\\n' "$probe_code" > /program-exit
exit 0
''')
                if args.replace_before_repeat:
                    probe = jail / "probe.sh"
                    text = probe.read_text().replace('cp "$original" "$original.next"', f'rm -f /etc/systemd/system/com.linkease.{"ddnstoshell" if app == "ddnsto" else "linkeasedaemon"}.service\ncp "$original" "$original.next"')
                    probe.write_text(text)
            if args.native_owner:
                probe = jail / "probe.sh"
                probe.write_text(probe.read_text().replace('"$@"\nprobe_code=', '/probe-zsetup run -- "$@"\nprobe_code='))
            probe = jail / "probe.sh"
            probe.write_text(probe.read_text().replace('exit 0\n', '''for probe_pid_file in /var/run/*.pid; do
    [ -f "$probe_pid_file" ] || continue
    IFS= read -r probe_pid < "$probe_pid_file" || continue
    case "$probe_pid" in ''|*[!0-9]*) continue ;; esac
    if kill -0 "$probe_pid" 2>/dev/null; then probe_alive=true; else probe_alive=false; fi
    printf '%s:%s:%s\\n' "$probe_pid_file" "$probe_pid" "$probe_alive" >> /service-processes
done
exit 0
'''))
            # Linux refuses CLONE_NEWUSER after chroot. Map UID1000 before
            # chroot, using the new namespace's capabilities before exec drops
            # them. Privileged paths are separately read-only in this probe.
            (jail / "user-exec.py").write_text('''import ctypes, os, sys
from pathlib import Path
libc = ctypes.CDLL(None, use_errno=True)
if libc.unshare(0x10000000) != 0:
    raise OSError(ctypes.get_errno(), "unshare user")
Path("/proc/self/setgroups").write_text("deny\\n")
Path("/proc/self/uid_map").write_text("1000 0 1\\n")
Path("/proc/self/gid_map").write_text("1000 0 1\\n")
os.chroot(sys.argv[1]); os.chdir("/")
os.execve("/bin/sh", ["sh", "/probe.sh", *sys.argv[2:]], {"HOME":"/home/user", "USER":"user", "PATH":"/sandbox-bin:/usr/bin:/bin"})
''')
            setup = work / "setup.sh"
            setup.write_text('''#!/bin/sh
set -eu
ulimit -c 0
ulimit -t 5
ulimit -f 1024
jail=$1; probe_scope=$2; probe_native=$3; shift 3
mount --make-rprivate /
ip link add eth0 type veth peer name eth1
ip link set dev eth0 address 02:00:00:00:00:10
ip addr add 192.0.2.1/30 dev eth0
ip link set eth0 up
ip link set eth1 up
ip link set lo up
for folder in usr bin lib lib64; do
    mount --bind "/$folder" "$jail/$folder"
    mount -o remount,bind,ro "$jail/$folder"
done
mount -t proc proc "$jail/proc"
touch "$jail/probe-zsetup"
mount --bind "$probe_native" "$jail/probe-zsetup"
mount -o remount,bind,ro "$jail/probe-zsetup"
for device in null zero urandom; do
    touch "$jail/dev/$device"
    mount --bind "/dev/$device" "$jail/dev/$device"
done
# Keep the namespace init in the owned process group. Even if a payload changes
# its process group, killing this init tears down every process in its PID ns.
if [ "$probe_scope" = user ]; then
    mount --bind "$jail/etc" "$jail/etc"
    mount -o remount,bind,ro "$jail/etc"
    mount --bind "$jail/opt" "$jail/opt"
    mount -o remount,bind,ro "$jail/opt"
    /usr/bin/python3 "$jail/user-exec.py" "$jail" "$@"
else
    chroot "$jail" /usr/bin/env -i HOME=/root USER=root PATH=/sandbox-bin:/usr/sbin:/usr/bin:/bin /bin/sh /probe.sh "$@"
fi
probe_code=$?
exit "$probe_code"
''')
            output = work / f"{app}.output"
            cmd = [native, "capture", "-o", str(output), "--max-bytes", "16384", "--timeout", "10s" if args.repeat_register or args.native_owner else "5s", "--", "unshare", "-Urnmpf", "sh", str(setup), str(jail), args.scope, native, "/" + str(program.relative_to(jail)), *invocation]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            units = {}
            for folder in [jail / "etc/systemd/system", jail / "etc/init.d"]:
                for unit in folder.iterdir():
                    if unit.is_file() and unit.stat().st_size <= 16384:
                        units[str(unit.relative_to(jail))] = unit.read_text(errors="replace")
            configuration = {}
            for folder in [jail / "etc", jail / "root"]:
                for entry in folder.rglob("*"):
                    if entry.is_file() and not entry.is_symlink() and entry.stat().st_size <= 16384:
                        configuration[str(entry.relative_to(jail))] = entry.read_text(errors="replace")
            rows.append({"application": app, "version": version, "scope": args.scope, "effective_uid": int((jail / "effective-uid").read_text()) if (jail / "effective-uid").exists() else None, "probe_exit": result.returncode, "program_exit": int((jail / "program-exit").read_text()) if (jail / "program-exit").exists() else None, "stdout": output.read_text(errors="replace") if output.exists() else "", "stderr": result.stderr[:16384], "generated_units": units, "service_actions": (jail / "actions").read_text() if (jail / "actions").exists() else "", "real_systemctl": False, "network": "isolated", "host_services_modified": False})
            rows[-1]["configuration_files"] = configuration
            rows[-1]["init_system"] = args.init_system
            rows[-1]["repeat_register"] = args.repeat_register
            rows[-1]["replace_before_repeat"] = args.replace_before_repeat
            rows[-1]["native_owner"] = args.native_owner
            rows[-1]["service_processes_before_namespace_exit"] = (jail / "service-processes").read_text() if (jail / "service-processes").exists() else ""
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps({"schema_version":1,"probes":rows}, ensure_ascii=False, indent=2) + "\n")
    print(args.report)

if __name__ == "__main__": main()
