"""Controlled extraction contract. Fixtures never install or execute vendor code."""
import hashlib
import io
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / "asus-package.sh"
PLATFORM = MODULE.with_name("asus-platform.sh")
MARKERS = dict(rogsoft="hnd", armsoft="arm384", mtksoft="mtk",
               ipq32soft="ipq32", ipq64soft="ipq64", qcasoft="qca")


def elf(arch):
    return (b"\x7fELF" + bytes([1 if arch == "armv7l" else 2, 1, 1])
            + bytes(9) + bytes([2, 0, 40 if arch == "armv7l" else 183, 0])
            + bytes(44))


def members(channel="rogsoft"):
    files = {"webs/Module_ddnsto.asp": b"vendor UI", "res/icon-ddnsto.png": b"icon",
             ".valid": (MARKERS[channel] + "\n").encode(), "version": b"4.2.8\n",
             "install.sh": b"exit 91\n", "uninstall.sh": b"exit 92\n",
             "scripts/ddnsto_config.sh": b"exit 93\n",
             "scripts/ddnsto_status.sh": b"exit 94\n"}
    if channel == "armsoft":
        files.update({"bin/ddnsto": elf("armv7l"), "res/ddnsto_check.html": b"status"})
    else:
        files.update({"bin/ddnsto_arm": elf("armv7l"), "bin/ddnsto_aarch64": elf("aarch64")})
    result = []
    for name in ("", "webs/", "res/", "bin/", "scripts/"):
        info = tarfile.TarInfo("ddnsto/" + name)
        info.type = tarfile.DIRTYPE
        result.append((info, b""))
    for name, data in files.items():
        info = tarfile.TarInfo("ddnsto/" + name)
        info.size = len(data)
        result.append((info, data))
    return result


class AsusPackageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "package.tar.gz"
        self.dest = self.root / "stage"

    def fixture(self, entries=None):
        with tarfile.open(self.archive, "w:gz", format=tarfile.USTAR_FORMAT) as archive:
            for info, data in members() if entries is None else entries:
                archive.addfile(info, io.BytesIO(data))

    def extract(self, channel="rogsoft", arch="aarch64", setup=""):
        self.assertTrue(MODULE.is_file(), "controlled ASUS package adapter is missing")
        return subprocess.run(["sh", "-eu", "-c",
                               '. "$1"; . "$2"; ' + setup
                               + '\nddnsto_asus_extract "$3" "$4" "$5" "$6"',
                               "test", str(PLATFORM), str(MODULE), str(self.archive),
                               str(self.dest), channel, arch], capture_output=True,
                              text=True, timeout=20)

    def test_stages_only_selected_binary_and_vendor_ui_privately(self):
        self.fixture()
        result = self.extract()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual({p.name for p in self.dest.iterdir()},
                         {"ddnsto", "Module_ddnsto.asp", "icon-ddnsto.png"})
        self.assertEqual((self.dest / "ddnsto").read_bytes(), elf("aarch64"))
        self.assertEqual((self.dest / "Module_ddnsto.asp").read_bytes(), b"vendor UI")
        self.assertEqual(self.dest.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.dest / "ddnsto").stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.dest / "Module_ddnsto.asp").stat().st_mode & 0o777, 0o600)

    def rejected(self, **kwargs):
        result = self.extract(**kwargs)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.dest.exists(), result.stderr)

    def test_rejects_every_unexpected_path_and_member_type(self):
        for name in ("../outside", "/tmp/ddnsto-outside", "ddnsto/../outside",
                     "./ddnsto/version", "ddnsto//version", "ddnsto/extra",
                     "ddnsto/webs/extra\nname", "ddnsto/webs/extra\\name"):
            with self.subTest(name=name):
                entries = members()
                info = tarfile.TarInfo(name)
                entries.append((info, b""))
                self.fixture(entries)
                self.rejected()
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE,
                     tarfile.CHRTYPE, tarfile.BLKTYPE, tarfile.DIRTYPE):
            with self.subTest(kind=kind):
                entries = members()
                for info, _ in entries:
                    if info.name == "ddnsto/install.sh":
                        info.type = kind
                        info.linkname = str(self.root / "outside")
                        info.size = 0
                self.fixture(entries)
                self.rejected()
        self.assertFalse((self.root / "outside").exists())

    def test_rejects_duplicate_missing_and_wrong_directory_type(self):
        original = members()
        for entries in (original + [original[-1]], original[1:], original[:-1]):
            self.fixture(entries)
            self.rejected()
        original[0][0].type = tarfile.REGTYPE
        original[0][0].name = "ddnsto"
        self.fixture(original)
        self.rejected()

    def test_channel_architecture_and_exact_metadata(self):
        for channel in MARKERS:
            for arch in ("armv7l", "aarch64"):
                with self.subTest(channel=channel, arch=arch):
                    self.fixture(members(channel))
                    if channel == "armsoft" and arch == "aarch64":
                        self.rejected(channel=channel, arch=arch)
                        continue
                    result = self.extract(channel, arch)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((self.dest / "ddnsto").read_bytes(), elf(arch))
                    for path in self.dest.iterdir():
                        path.unlink()
                    self.dest.rmdir()
        self.fixture()
        for channel, arch in (("unknown", "aarch64"), ("rogsoft", "x86_64"),
                              ("mtksoft", "aarch64")):
            self.rejected(channel=channel, arch=arch)
        for name, data in ((".valid", b"hnd\n\n"), (".valid", b"hnd"),
                           (".valid", b"hnd\x00\n"), (".valid", b"hnd\x00"),
                           ("version", b"4.2.9\n"),
                           ("version", b"4.2.8\n\n")):
            entries = members()
            for i, (info, _) in enumerate(entries):
                if info.name == "ddnsto/" + name:
                    info.size = len(data)
                    entries[i] = (info, data)
            self.fixture(entries)
            self.rejected()

    def test_elf_architecture_is_checked_without_execution(self):
        for data in (elf("armv7l"), b"#!/bin/sh\nexit 0\n", b"\x7fELF"):
            entries = members()
            for i, (info, _) in enumerate(entries):
                if info.name == "ddnsto/bin/ddnsto_aarch64":
                    info.size = len(data)
                    entries[i] = (info, data)
            self.fixture(entries)
            self.rejected()

    def test_existing_destination_and_symlink_ancestors_are_untouched(self):
        self.fixture()
        self.dest.mkdir()
        sentinel = self.dest / "keep"
        sentinel.write_text("keep")
        self.assertNotEqual(self.extract().returncode, 0)
        self.assertEqual(sentinel.read_text(), "keep")
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        self.dest = link / "other"
        self.rejected()

    def test_partial_extraction_failure_is_cleaned(self):
        self.fixture()
        self.rejected(setup='''
_ddnsto_asus_package_tar() {
    case "$*" in *-xOzf*Module_ddnsto.asp*) printf partial; return 1;; esac
    tar "$@"
}
''')

    def test_oversized_regular_members_are_rejected_before_staging(self):
        entries = members()
        for i, (info, _) in enumerate(entries):
            if info.name == "ddnsto/install.sh":
                data = bytes(65537)
                info.size = len(data)
                entries[i] = (info, data)
        self.fixture(entries)
        self.rejected()

    def test_extraction_and_listing_output_have_kernel_and_final_size_bounds(self):
        self.fixture()
        for selector in ("*-xOzf*Module_ddnsto.asp*", "*-tzf*"):
            with self.subTest(selector=selector):
                # Simulate a tool producing excess output despite a sane header.
                # Record its inherited file limit, then suppress dd failure so
                # the adapter must also perform its final byte-count check.
                record = shlex.quote(str(self.root / "limit"))
                self.rejected(setup='''
_ddnsto_asus_package_tar() {
    case "$*" in ''' + selector + ''')
        ulimit -f > ''' + record + '''
        dd if=/dev/zero bs=1024 count=256 2>/dev/null || :
        return 0;;
    esac
    tar "$@"
}
''')
                self.assertNotEqual((self.root / "limit").read_text().strip(), "unlimited")

    def test_listing_command_failure_and_truncated_archive(self):
        self.fixture()
        self.rejected(setup='_ddnsto_asus_package_tar() { return 1; };')
        self.archive.write_bytes(self.archive.read_bytes()[:100])
        self.rejected()

    def test_real_gzip_bomb_member_and_large_listing_are_rejected(self):
        entries = members()
        for i, (info, _) in enumerate(entries):
            if info.name == "ddnsto/bin/ddnsto_aarch64":
                data = bytes(13 * 1024 * 1024)
                info.size = len(data)
                entries[i] = (info, data)
        self.fixture(entries)
        self.assertLess(self.archive.stat().st_size, 65536)
        self.rejected()
        entries = members()
        for i in range(2000):
            entries.append((tarfile.TarInfo("ddnsto/extra-" + str(i)), b""))
        self.fixture(entries)
        self.rejected()

    def test_missing_od_uses_pin_trust_but_present_failing_od_rejects(self):
        self.fixture()
        self.rejected(setup='_ddnsto_asus_package_od() { return 1; };')
        result = self.extract(setup='''
_ddnsto_asus_package_has_od() { return 1; }
stat() { return 127; }
id() { return 127; }
command() { return 127; }
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dest / "ddnsto").read_bytes(), elf("aarch64"))

    def test_output_limit_or_chmod_failure_is_fatal(self):
        self.fixture()
        for setup in ('ulimit() { return 1; };', 'chmod() { return 1; };'):
            self.rejected(setup=setup)

    def test_vendor_scripts_are_inert_and_tar_options_cannot_run_commands(self):
        sentinel = self.root / "executed"
        payload = ("touch " + shlex.quote(str(sentinel)) + "\n").encode()
        entries = members()
        for i, (info, _) in enumerate(entries):
            if info.name.endswith(".sh"):
                info.size = len(payload)
                entries[i] = (info, payload)
        self.fixture(entries)
        result = self.extract(setup="export TAR_OPTIONS=" + shlex.quote(
            "--checkpoint=1 --checkpoint-action=exec=touch " + str(sentinel)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(sentinel.exists())

    @unittest.skipUnless(os.environ.get("DDNSTO_ASUS_BUSYBOX"),
                         "optional local BusyBox executable")
    def test_busybox_tar_and_shell(self):
        self.fixture()
        busybox = os.environ["DDNSTO_ASUS_BUSYBOX"]
        result = subprocess.run(
            [busybox, "sh", "-eu", "-c", '''
. "$1"; . "$2"
bb=$3
_ddnsto_asus_package_tar() { "$bb" tar "$@"; }
_ddnsto_asus_package_od() { "$bb" od "$@"; }
ddnsto_asus_extract "$4" "$5" rogsoft aarch64
''', "test", str(PLATFORM), str(MODULE), busybox,
             str(self.archive), str(self.dest)], text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dest / "ddnsto").read_bytes(), elf("aarch64"))

    @unittest.skipUnless(os.environ.get("DDNSTO_ASUS_ARCHIVE_DIR"),
                         "optional six pinned vendor archives")
    def test_actual_six_archives_against_platform_pins(self):
        for channel in MARKERS:
            self.archive = Path(os.environ["DDNSTO_ASUS_ARCHIVE_DIR"]) / (channel + ".tar.gz")
            pins = subprocess.check_output(
                ["sh", "-eu", "-c", '. "$1"; ddnsto_asus_package "$2"',
                 "pins", str(PLATFORM), channel], text=True).splitlines()
            content = self.archive.read_bytes()
            self.assertEqual(len(content), int(pins[3]))
            self.assertEqual(hashlib.sha256(content).hexdigest(), pins[4])
            for arch in (("armv7l",) if channel == "armsoft" else ("armv7l", "aarch64")):
                with self.subTest(channel=channel, arch=arch):
                    self.dest = self.root / (channel + "-" + arch)
                    result = self.extract(channel, arch)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    with tarfile.open(self.archive) as archive:
                        binary = "ddnsto" if channel == "armsoft" else "ddnsto_" + ("arm" if arch == "armv7l" else "aarch64")
                        for source, target in (("bin/" + binary, "ddnsto"),
                                               ("webs/Module_ddnsto.asp", "Module_ddnsto.asp"),
                                               ("res/icon-ddnsto.png", "icon-ddnsto.png")):
                            self.assertEqual((self.dest / target).read_bytes(),
                                             archive.extractfile("ddnsto/" + source).read())


if __name__ == "__main__":
    unittest.main()
