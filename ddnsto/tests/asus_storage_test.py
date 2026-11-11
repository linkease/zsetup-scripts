"""Bounded ASUS helper contract; OS fixtures never touch host /jffs."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / "asus-storage.sh"


class AsusStorageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.jffs = self.root / "jffs"
        self.jffs.mkdir(mode=0o755)
        self.state = self.jffs / ".ddnsto-installer"

    def fixture(self, mounts="/dev/sda5 /jffs ext4 rw,relatime 0 0", uid="0"):
        # Only raw OS boundaries are substituted. All parsing, anchor and
        # ancestor decisions remain production code. Real ls/mkdir exercise
        # symlink and permission behavior, translating the fixture owner to 0.
        return """
_ddnsto_asus_status() { printf 'Uid:\\t%s\\t%s\\t%s\\t%s\\n' UID UID UID UID; }
_ddnsto_asus_mounts() { printf '%s\\n' MOUNTS; }
_ddnsto_asus_ls() {
    case "$1" in /jffs|/jffs/*) ;; *) return 1;; esac
    listing=$(LC_ALL=C ls -nd ROOT"$1") || return 1
    printf '%s\\n' "$listing" | awk -v owner=OWNER '{ if ($3 == owner) $3=0; print }'
}
_ddnsto_asus_mkdir() { mkdir -m 700 ROOT"$1"; }
""".replace("UID", shlex.quote(uid)).replace("MOUNTS", shlex.quote(mounts)).replace(
            "ROOT", shlex.quote(str(self.root))).replace("OWNER", str(os.getuid()))

    def scoped(self, code, **kwargs):
        return self.shell(code, self.fixture(**kwargs))

    def shell(self, code, setup=""):
        self.assertTrue(MODULE.is_file(), "ASUS storage helper is not implemented")
        result = subprocess.run(["sh", "-eu", "-c",
                                 '. "$1"; ' + setup + "\n" + code,
                                 "test", str(MODULE)], text=True,
                                capture_output=True, timeout=5)
        self.assertNotIn("not found", result.stderr,
                         "A missing function/tool is not a policy rejection")
        return result

    def test_uid_from_proc_and_builtin_detection(self):
        result = self.shell("ddnsto_asus_uid; ddnsto_asus_has printf; "
                            "! ddnsto_asus_has ddnsto_nonexistent_tool")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(os.geteuid()) + "\n")

    def test_numeric_metadata_and_ambiguous_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "file"
            path.write_text("abc")
            path.chmod(0o600)
            result = self.shell("ddnsto_asus_fields " + shlex.quote(str(path)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, f"{os.getuid()} 600 1\n")
            for mode in (0o755, 0o1777, 0o2750, 0o4700, 0o000):
                path.chmod(mode)
                result = self.shell("ddnsto_asus_fields " + shlex.quote(str(path)))
                self.assertEqual(result.stdout, f"{os.getuid()} {mode:o} 1\n")
            for name in ("a b", "a\nb", "a*", "a\\b"):
                odd = Path(tmp) / name
                odd.touch()
                result = self.shell("ddnsto_asus_fields " + shlex.quote(str(odd)))
                self.assertNotEqual(result.returncode, 0, name)
                self.assertEqual(result.stdout, "")

    def test_metadata_rejects_ambiguous_output_and_command_failure(self):
        for listing in ("", "-rw-------+ 1 0 0 3 Jan 1 2026 /jffs/f",
                        "-rw------- 1 root 0 3 Jan 1 2026 /jffs/f",
                        "-rw------- 1 0 0 3 Jan 1 2026 /jffs/f\nextra"):
            setup = "_ddnsto_asus_ls() { printf '%s\\n' " + shlex.quote(listing) + "; };"
            result = self.shell("ddnsto_asus_fields /jffs/f", setup)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
        result = self.shell("ddnsto_asus_fields /jffs/f",
                            "_ddnsto_asus_ls() { return 1; };")
        self.assertNotEqual(result.returncode, 0)

    def test_verified_mount_creates_private_state_without_chmod_ancestors(self):
        result = self.scoped('ddnsto_asus_anchor; ddnsto_asus_storage; printf "%s\\n" "$ASUS_STATE"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/jffs/.ddnsto-installer\n")
        self.assertEqual(self.state.stat().st_mode & 0o7777, 0o700)
        self.assertEqual(self.jffs.stat().st_mode & 0o7777, 0o755)
        self.assertEqual(self.scoped("ddnsto_asus_storage").returncode, 0)

    def test_anchor_rejects_missing_wrong_readonly_duplicate_or_nested_mounts(self):
        good = "/dev/sda5 /jffs ext4 rw,relatime 0 0"
        for mounts in ("", good.replace("/jffs", "/jffs-other"),
                       good.replace("/dev/sda5", "tmpfs"),
                       good.replace("ext4", "tmpfs"), good.replace("rw,", "ro,"),
                       good.replace("rw,", "rw,ro,"), good + "\n" + good,
                       good + "\ntmpfs /jffs/child tmpfs rw 0 0",
                       good.replace("/jffs", r"/jf\146s"),
                       good.replace("/dev/sda5", "$(evil)")):
            with self.subTest(mounts=mounts):
                result = self.scoped('ASUS_STATE=bad; ddnsto_asus_storage && exit 99; '
                                     '[ -z "$ASUS_STATE" ]', mounts=mounts)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(self.state.exists())

    def test_anchor_accepts_approved_block_and_flash_mount_sources(self):
        for source, filesystem in (
                ("/dev/sda5", "ext4"), ("/dev/sdb1", "ext2"),
                ("/dev/mmcblk0p3", "ext3"), ("/dev/mapper/jffs", "ext4"),
                ("/dev/mtdblock3", "jffs2"), ("/dev/mtdblock/4", "jffs2"),
                ("/dev/ubi0_1", "ubifs"), ("ubi0:jffs", "ubifs"),
                ("ubi12:jffs-data_1.0", "ubifs")):
            with self.subTest(source=source, filesystem=filesystem):
                result = self.scoped("ddnsto_asus_storage", mounts=
                                     f"{source} /jffs {filesystem} rw,relatime 0 0")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.state.stat().st_mode & 0o7777, 0o700)

    def test_anchor_rejects_unapproved_filesystems_and_source_grammar(self):
        cases = [("/dev/sda5", fs) for fs in ("tmpfs", "overlay", "nfs", "nfs4", "cifs", "squashfs")]
        cases += [(source, "ext4") for source in (
            "server:/jffs", "//server/share", "ubi0:jffs", "/tmp/disk",
            "/dev/../tmp/disk", "/dev//sda5", "/dev/sda5/", r"/dev/sda\065",
            "/dev/$(evil)")]
        cases += [(source, "jffs2") for source in ("/dev/sda5", "/dev/mtdblock", "ubi0:jffs")]
        cases += [(source, "ubifs") for source in (
            "/dev/sda5", "/dev/ubi0", "/dev/ubi0_", "ubi:jffs", "ubi0:",
            "ubi0:../jffs", "ubi0:jffs/path", "ubi0:$(evil)")]
        for source, filesystem in cases:
            with self.subTest(source=source, filesystem=filesystem):
                result = self.scoped("ddnsto_asus_storage", mounts=
                                     f"{source} /jffs {filesystem} rw 0 0")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.state.exists())

    def test_anchor_rejects_noexec_and_bad_mount_options(self):
        for options in ("rw,noexec", "noexec,rw", "rw,noexec,exec", "ro", "rw,ro",
                        "rw,rw", "rw,bind", "rw,rbind", "relatime"):
            with self.subTest(options=options):
                result = self.scoped("ddnsto_asus_anchor", mounts=
                                     f"/dev/sda5 /jffs ext4 {options} 0 0")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.state.exists())

    def test_anchor_allows_only_approved_modes_without_changing_them(self):
        for mode in (0o700, 0o750, 0o755, 0o710, 0o751, 0o754, 0o705):
            with self.subTest(mode=oct(mode)):
                self.jffs.chmod(mode)
                result = self.scoped("ddnsto_asus_anchor")
                self.assertEqual(result.returncode == 0, mode in (0o700, 0o750, 0o755))
                self.assertEqual(self.jffs.stat().st_mode & 0o7777, mode)

    def test_ancestors_excludes_leaf_append_probe_to_check_directory(self):
        directory = self.jffs / "scripts"
        directory.mkdir()
        directory.chmod(0o777)
        self.assertEqual(self.scoped("ddnsto_asus_safe_ancestors /jffs/scripts").returncode, 0)
        self.assertNotEqual(self.scoped("ddnsto_asus_safe_ancestors /jffs/scripts/probe").returncode, 0)
        directory.chmod(0o750)
        self.assertEqual(self.scoped("ddnsto_asus_safe_ancestors /jffs/scripts/probe").returncode, 0)
        self.assertFalse((directory / "probe").exists())

    def test_anchor_rejects_nonroot_and_unsafe_anchor_permissions(self):
        self.assertNotEqual(self.scoped("ddnsto_asus_anchor", uid="911").returncode, 0)
        for mode in (0o777, 0o775, 0o1755):
            self.jffs.chmod(mode)
            self.assertNotEqual(self.scoped("ddnsto_asus_storage").returncode, 0)
            self.assertEqual(self.jffs.stat().st_mode & 0o7777, mode)
        self.jffs.chmod(0o755)
        setup = self.fixture() + '\n_ddnsto_asus_ls() { printf "drwxr-xr-x 2 911 0 0 Jan 1 2026 /jffs\\n"; };'
        self.assertNotEqual(self.shell("ddnsto_asus_anchor", setup).returncode, 0)

    def test_symlink_anchor_and_preexisting_unsafe_state_rejected(self):
        self.jffs.rmdir()
        target = self.root / "target"
        target.mkdir(mode=0o755)
        self.jffs.symlink_to(target)
        self.assertNotEqual(self.scoped("ddnsto_asus_storage").returncode, 0)
        self.assertFalse((target / ".ddnsto-installer").exists())
        self.jffs.unlink()
        self.jffs.mkdir(mode=0o755)
        self.state.symlink_to(target)
        self.assertNotEqual(self.scoped("ddnsto_asus_storage").returncode, 0)
        self.state.unlink()
        for mode in (0o755, 0o770, 0o707):
            self.state.mkdir(mode=mode)
            self.state.chmod(mode)
            self.assertNotEqual(self.scoped("ddnsto_asus_storage").returncode, 0)
            self.assertEqual(self.state.stat().st_mode & 0o7777, mode)
            self.state.rmdir()

    def test_bounded_ancestors_and_private_directory_creation(self):
        result = self.scoped('ddnsto_asus_storage; '
                             'ddnsto_asus_private_dir "$ASUS_STATE/stage"; '
                             'ddnsto_asus_safe_ancestors "$ASUS_STATE/stage/new-file"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.state / "stage").stat().st_mode & 0o7777, 0o700)
        for path in ("/tmp/file", "/koolshare/file", "/jffs-other/file",
                     "/jffs/.ddnsto-installer/../file", "/jffs//file", "/jffs/./file"):
            self.assertNotEqual(self.scoped("ddnsto_asus_safe_ancestors " +
                                           shlex.quote(path)).returncode, 0, path)
        for mode in (0o775, 0o777, 0o1755):
            (self.state / "stage").chmod(mode)
            self.assertNotEqual(self.scoped(
                "ddnsto_asus_safe_ancestors /jffs/.ddnsto-installer/stage/file").returncode, 0)
        (self.state / "stage").rmdir()
        (self.state / "stage").symlink_to(self.root)
        self.assertNotEqual(self.scoped(
            "ddnsto_asus_private_dir /jffs/.ddnsto-installer/stage/escape").returncode, 0)
        self.assertFalse((self.root / "escape").exists())
        self.assertNotEqual(self.scoped("ddnsto_asus_private_dir /jffs/other").returncode, 0)

    def test_safe_file_rejects_symlink_hardlink_writable_nonregular_and_nonroot(self):
        self.state.mkdir(mode=0o700)
        file = self.state / "payload"
        file.write_text("abc")
        file.chmod(0o600)
        check = "ddnsto_asus_safe_file /jffs/.ddnsto-installer/payload"
        self.assertEqual(self.scoped(check).returncode, 0)
        for mode in (0o666, 0o620, 0o602, 0o4600):
            file.chmod(mode)
            self.assertNotEqual(self.scoped(check).returncode, 0)
        file.chmod(0o600)
        os.link(file, self.state / "alias")
        self.assertNotEqual(self.scoped(check).returncode, 0)
        file.unlink()
        file.symlink_to(self.state / "alias")
        self.assertNotEqual(self.scoped(check).returncode, 0)
        file.unlink()
        file.mkdir(mode=0o700)
        self.assertNotEqual(self.scoped(check).returncode, 0)
        file.rmdir()
        os.mkfifo(file)
        self.assertNotEqual(self.scoped(check).returncode, 0)
        file.unlink()
        setup = self.fixture() + '''
_ddnsto_asus_ls() {
 case "$1" in
 /jffs) printf 'drwxr-xr-x 2 0 0 0 Jan 1 2026 /jffs\\n';;
 /jffs/.ddnsto-installer) printf 'drwx------ 2 0 0 0 Jan 1 2026 /jffs/.ddnsto-installer\\n';;
 *) printf '%s\\n' '-rw------- 1 911 0 3 Jan 1 2026 /jffs/.ddnsto-installer/payload';;
 esac
}
'''
        self.assertNotEqual(self.shell(check, setup).returncode, 0)

    def test_random_private_directory_is_fresh_and_preserves_umask(self):
        result = self.scoped('ddnsto_asus_storage; umask 022; '
                             'ddnsto_asus_mktemp "$ASUS_STATE"; '
                             'ddnsto_asus_mktemp "$ASUS_STATE"; umask')
        self.assertEqual(result.returncode, 0, result.stderr)
        first, second, mask = result.stdout.splitlines()
        self.assertNotEqual(first, second)
        self.assertEqual(int(mask, 8), 0o22)
        for path in (first, second):
            self.assertRegex(path, r"^/jffs/\.ddnsto-installer/tmp\.[0-9a-f]{24}$")
            self.assertEqual((self.root / path.lstrip("/")).stat().st_mode & 0o7777, 0o700)

    def test_random_directory_collisions_and_bad_randomness_fail_closed(self):
        self.state.mkdir(mode=0o700)
        collision = self.state / ("tmp." + "a" * 24)
        collision.mkdir(mode=0o700)
        (collision / "keep").write_text("keep")
        setup = self.fixture() + "\n_ddnsto_asus_random() { printf '%s\\n' " + "a" * 24 + "; };"
        result = self.shell("ddnsto_asus_mktemp /jffs/.ddnsto-installer", setup)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual((collision / "keep").read_text(), "keep")
        for value in ("", "abc", "../escape", "G" * 24, "a" * 25, "a" * 24 + "\nextra"):
            setup = self.fixture() + "\n_ddnsto_asus_random() { printf '%s\\n' " + shlex.quote(value) + "; };"
            self.assertNotEqual(self.shell("ddnsto_asus_mktemp /jffs/.ddnsto-installer", setup).returncode, 0)
        for parent in ("/tmp", "/jffs", "/jffs/.ddnsto-installer/missing"):
            self.assertNotEqual(self.scoped("ddnsto_asus_mktemp " + parent).returncode, 0)

    def test_hash_abc_with_openssl_and_sha256sum_fallback(self):
        self.state.mkdir(mode=0o700)
        file = self.state / "payload"
        file.write_bytes(b"abc")
        file.chmod(0o600)
        for backend in ("openssl", "sha256sum"):
            setup = self.fixture() + """
ddnsto_asus_has() { [ "$1" = BACKEND ]; }
_ddnsto_asus_openssl_hash() { openssl dgst -sha256 < ROOT"$1"; }
_ddnsto_asus_sha256_hash() { sha256sum < ROOT"$1"; }
""".replace("BACKEND", backend).replace("ROOT", shlex.quote(str(self.root)))
            result = self.shell("ddnsto_asus_hash /jffs/.ddnsto-installer/payload", setup)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n")

    def test_hash_rejects_tool_failure_bad_output_and_unsafe_file(self):
        self.state.mkdir(mode=0o700)
        file = self.state / "payload"
        file.write_bytes(b"abc")
        file.chmod(0o600)
        digest = "a" * 64
        for body in ("return 1", "printf '%s\\n' 'SHA256(stdin)= " + digest + "'; return 1",
                     "printf '%s\\n' 'SHA256(stdin)= short'",
                     "printf '%s\\n' 'SHA256(stdin)= " + digest + "' extra",
                     "printf '%s\\n' 'unexpected " + digest + "'"):
            setup = self.fixture() + "\n_ddnsto_asus_openssl_hash() { " + body + "; };"
            result = self.shell("ddnsto_asus_hash /jffs/.ddnsto-installer/payload", setup)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
        file.chmod(0o666)
        self.assertNotEqual(self.scoped("ddnsto_asus_hash /jffs/.ddnsto-installer/payload").returncode, 0)

    def test_uid_parsing_effective_uid_and_malformed_records(self):
        for status, expected in (("Uid: 911 0 911 911", "0\n"),
                                 ("Uid: 0 911 0 0", "911\n"),
                                 ("Uid: 0 0 0", None),
                                 ("Uid: 0 root 0 0", None),
                                 ("Uid: 0 0 0 0\nUid: 0 0 0 0", None),
                                 ("Name: shell", None)):
            setup = "_ddnsto_asus_status() { printf '%s\\n' " + shlex.quote(status) + "; };"
            result = self.shell("ddnsto_asus_uid", setup)
            self.assertEqual(result.stdout, expected or "")
            self.assertEqual(result.returncode == 0, expected is not None)

    def test_compatibility_without_missing_router_utilities(self):
        bindir = self.root / "bin"
        bindir.mkdir()
        for tool in ("ls", "awk", "mkdir", "openssl", "cat"):
            executable = shutil.which(tool)
            self.assertIsNotNone(executable, tool + " required for test")
            (bindir / tool).symlink_to(executable)
        setup = self.fixture() + "\nPATH=" + shlex.quote(str(bindir)) + """
command() { printf 'forbidden command builtin\\n' >&2; return 99; }
ASUS_STATE=/tmp/evil
ASUS_ROOT=/tmp/evil
DDNSTO_ASUS_ROOT=/tmp/evil
"""
        result = self.shell('ddnsto_asus_has openssl; ! ddnsto_asus_has stat; '
                            '! ddnsto_asus_has sha256sum; ddnsto_asus_storage; '
                            'ddnsto_asus_mktemp "$ASUS_STATE"', setup)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertTrue(result.stdout.startswith("/jffs/.ddnsto-installer/tmp."))

    def test_randomness_failure_and_directory_creation_failure(self):
        self.state.mkdir(mode=0o700)
        for boundary in ("_ddnsto_asus_random() { return 1; }",
                         "_ddnsto_asus_mkdir() { return 1; }"):
            result = self.shell("ddnsto_asus_mktemp /jffs/.ddnsto-installer",
                                self.fixture() + "\n" + boundary)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertEqual(list(self.state.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
