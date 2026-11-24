#!/usr/bin/env python3
"""Validate and build the directly publishable apps tree."""

import argparse
from dataclasses import dataclass
import hashlib
import itertools
import json
from pathlib import Path
import re
import sys
import tempfile

import build_ddnsto_installer
import build_ddnsto_site


APP_ID = re.compile(r"[a-z][a-z0-9-]{0,63}\Z")
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\Z")
ENTRYPOINTS = {"sh", "ps1"}
MANIFEST_KEYS = {
    "schema_version", "id", "name", "version", "min_zsetup",
    "entrypoints", "targets", "compatibility_aliases",
}
TARGET_KEYS = {"os", "package_manager", "arch"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def string_list(value, field, *, pattern=None):
    require(isinstance(value, list) and value, f"{field} must be a non-empty list")
    require(all(isinstance(item, str) and item for item in value), f"{field} contains an invalid value")
    require(len(value) == len(set(value)), f"{field} contains a duplicate value")
    if pattern is not None:
        require(all(pattern.fullmatch(item) for item in value), f"{field} contains an unsafe value")
    return value


@dataclass(frozen=True)
class Application:
    directory: Path
    manifest: dict
    expanded_targets: tuple

    @property
    def id(self):
        return self.manifest["id"]


def read_application(directory: Path):
    path = directory / "app.json"
    external = directory.parent.parent / 'sources' / directory.name / 'app.json'
    if directory.name == 'ddnsto' and external.is_file():
        path = external
    require(path.is_file() and not path.is_symlink(), f"missing {directory.name}/app.json")
    raw = path.read_bytes()
    require(len(raw) <= 65536, f"{directory.name}/app.json is too large")
    data = json.loads(raw)
    require(isinstance(data, dict), f"{directory.name}/app.json must be an object")
    require(set(data) == MANIFEST_KEYS, f"{directory.name}/app.json fields differ from schema")
    require(data["schema_version"] == 1, "schema_version must be 1")
    require(isinstance(data["id"], str) and APP_ID.fullmatch(data["id"]), "invalid application id")
    require(data["id"] == directory.name, "application id must equal directory name")
    require(isinstance(data["name"], str) and 0 < len(data["name"]) <= 128, "invalid application name")
    require(isinstance(data["version"], str) and VERSION.fullmatch(data["version"]), "invalid version")
    require(isinstance(data["min_zsetup"], str) and VERSION.fullmatch(data["min_zsetup"]), "invalid min_zsetup")
    entrypoints = string_list(data["entrypoints"], "entrypoints")
    require(set(entrypoints) <= ENTRYPOINTS, "entrypoints contains an unsupported type")
    aliases = data["compatibility_aliases"]
    require(isinstance(aliases, list), "compatibility_aliases must be a list")
    require(len(aliases) == len(set(aliases)), "compatibility_aliases contains a duplicate value")
    for alias in aliases:
        require(isinstance(alias, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", alias),
                "invalid compatibility alias")
        require(Path(alias).suffix.removeprefix(".") in entrypoints, "compatibility alias type is not enabled")

    targets = data["targets"]
    require(isinstance(targets, list) and targets, "targets must be a non-empty list")
    expanded = []
    value_pattern = re.compile(r"\*|[a-z0-9][a-z0-9._-]{0,63}")
    for target in targets:
        require(isinstance(target, dict) and set(target) == TARGET_KEYS, "invalid target fields")
        values = [string_list(target[key], f"target {key}", pattern=value_pattern)
                  for key in ("os", "package_manager", "arch")]
        expanded.extend(itertools.product(*values))
    require(len(expanded) == len(set(expanded)), "duplicate target selector")
    if any(os_name == "windows" for os_name, _, _ in expanded):
        require("ps1" in entrypoints, "windows target requires installer.ps1 entrypoint")
    if any(os_name != "windows" for os_name, _, _ in expanded):
        require("sh" in entrypoints, "non-Windows target requires installer.sh entrypoint")
    version_dir = directory / data["version"]
    require(version_dir.is_dir() and not version_dir.is_symlink(), "current version directory is missing")
    for entrypoint in entrypoints:
        payload = version_dir / f"installer.{entrypoint}"
        require(payload.is_file() and not payload.is_symlink(), f"missing {directory.name}/{data['version']}/installer.{entrypoint}")
    return Application(directory, data, tuple(expanded))


def discover(apps: Path):
    require(apps.is_dir() and not apps.is_symlink(), "apps root must be a real directory")
    applications = []
    ids = set()
    for directory in sorted(apps.iterdir(), key=lambda item: item.name):
        if not directory.is_dir() or directory.name in {"zsetup", "_shared"}:
            continue
        require(APP_ID.fullmatch(directory.name), f"unsafe application directory: {directory.name}")
        application = read_application(directory)
        require(application.id not in ids, f"duplicate application id: {application.id}")
        ids.add(application.id)
        applications.append(application)
    return applications


def posix_entry(root: Path, application: Application):
    template = (root / "templates/install.sh.in").read_text()
    bootstrap_lines = (root / "lib/bootstrap.sh").read_text().splitlines()
    if bootstrap_lines and bootstrap_lines[0] == "#!/bin/sh":
        bootstrap_lines.pop(0)
    if bootstrap_lines and bootstrap_lines[0] == "set -eu":
        bootstrap_lines.pop(0)
    bootstrap = "\n".join(bootstrap_lines).strip() + "\n"
    primary_urls, fallback_url = config_urls(application.directory.parent, windows=False)
    replacements = {
        "@APP_ID@": application.id,
        "@BOOTSTRAP@": bootstrap,
        "@CONFIG_PRIMARY_URLS@": " ".join(primary_urls),
        "@CONFIG_FALLBACK_URL@": fallback_url,
    }
    require(all(template.count(marker) == 1 for marker in replacements),
            "invalid standard POSIX entry template")
    require(all("'" not in value for value in [application.id, *primary_urls, fallback_url]),
            "unsafe POSIX entry value")
    for marker, value in replacements.items():
        template = template.replace(marker, value)
    return template


def powershell_entry(root: Path, application: Application):
    template = (root / "templates/install.ps1.in").read_text()
    bootstrap = (root / "lib/bootstrap.ps1").read_text().strip() + "\n"
    primary_urls, fallback_url = config_urls(application.directory.parent, windows=True)
    replacements = {
        "@APP_ID@": application.id,
        "@BOOTSTRAP@": bootstrap,
        "@CONFIG_PRIMARY_URLS@": ", ".join(f"'{url}'" for url in primary_urls),
        "@CONFIG_FALLBACK_URL@": fallback_url,
    }
    require(all(template.count(marker) == 1 for marker in replacements),
            "invalid standard PowerShell entry template")
    require(all("'" not in value for value in [application.id, *primary_urls, fallback_url]),
            "unsafe PowerShell entry value")
    text = template
    for marker, value in replacements.items():
        text = text.replace(marker, value)
    return b"\xef\xbb\xbf" + text.encode("utf-8")


def install_file(path: Path, content: bytes, *, executable: bool, check: bool, label: str):
    mode = 0o755 if executable else 0o644
    if check:
        require(path.is_file() and not path.is_symlink() and path.read_bytes() == content,
                f"stale {label}: {path}")
        require(stat_mode(path) == mode, f"wrong mode for {label}: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as stream:
        stream.write(content)
        temporary = Path(stream.name)
    try:
        temporary.chmod(mode)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def stat_mode(path: Path):
    return path.stat().st_mode & 0o777


def generate_entries(root: Path, applications, *, check: bool):
    for application in applications:
        entrypoints = application.manifest["entrypoints"]
        if "sh" in entrypoints:
            content = posix_entry(root, application).encode()
            # DDNSTO's standard entry is generated by build_ddnsto_site below.
            # Keep its native bootstrap only under the compatibility alias.
            if not (application.directory.name == "ddnsto" and
                    (application.directory.parent.parent / "sources/ddnsto").is_dir()):
                install_file(application.directory / "install.sh", content,
                             executable=True, check=check, label="standard entry")
            for alias in application.manifest["compatibility_aliases"]:
                if alias.endswith(".sh"):
                    install_file(application.directory / alias, content,
                                 executable=True, check=check, label="compatibility alias")
        if "ps1" in entrypoints:
            content = powershell_entry(root, application)
            install_file(application.directory / "install.ps1", content,
                         executable=False, check=check, label="standard PowerShell entry")
            for alias in application.manifest["compatibility_aliases"]:
                if alias.endswith(".ps1"):
                    install_file(application.directory / alias, content,
                                 executable=False, check=check, label="PowerShell compatibility alias")


def version_tuple(value: str):
    core = re.split(r"[-+]", value, maxsplit=1)[0]
    return tuple(int(part) for part in core.split("."))


def read_base(apps: Path, filename="base.json"):
    path = apps / "zsetup" / filename
    require(path.is_file() and not path.is_symlink(), f"missing zsetup/{filename}")
    data = json.loads(path.read_bytes())
    require(isinstance(data, dict) and set(data) == {
        "schema_version", "public_path_prefix", "source_groups", "stable_zsetup",
    },
            "invalid zsetup/base.json fields")
    require(data["schema_version"] == 1, "invalid zsetup base schema_version")
    prefix = data["public_path_prefix"]
    require(isinstance(prefix, str) and re.fullmatch(
        r"[a-z0-9][a-z0-9._-]*(?:/[a-z0-9][a-z0-9._-]*)*", prefix),
        "invalid public_path_prefix")
    groups = data["source_groups"]
    require(isinstance(groups, list) and groups, "zsetup base needs source groups")
    ids = [group.get("id") for group in groups if isinstance(group, dict)]
    require(len(ids) == len(groups) and len(ids) == len(set(ids)),
            "zsetup base needs unique source groups")
    stable = data["stable_zsetup"]
    require(isinstance(stable, dict) and isinstance(stable.get("version"), str)
            and VERSION.fullmatch(stable["version"]), "invalid stable zsetup version")
    require(stable.get("source_group") in ids, "stable zsetup references an unknown source group")
    require(isinstance(stable.get("artifacts"), list) and stable["artifacts"],
            "stable zsetup artifacts are required")
    return data


def config_urls(apps: Path, *, windows: bool):
    filename = "base-windows.json" if windows else "base.json"
    config_name = "config-windows.json" if windows else "config.json"
    base = read_base(apps, filename)
    group_id = base["stable_zsetup"]["source_group"]
    group = next(group for group in base["source_groups"] if group["id"] == group_id)
    require(set(group) == {"id", "primary_bases", "fallback_base"},
            "invalid source group fields")
    primaries = group["primary_bases"]
    fallback = group["fallback_base"]
    require(isinstance(primaries, list) and primaries and
            all(isinstance(url, str) and url.startswith("https://") and
                not any(character.isspace() for character in url) for url in primaries),
            "invalid source group primary_bases")
    require(isinstance(fallback, str) and fallback.startswith("https://") and
            not any(character.isspace() for character in fallback),
            "invalid source group fallback_base")
    relative = f"{base['public_path_prefix']}/zsetup/{config_name}"
    return ([f"{url.rstrip('/')}/{relative}" for url in primaries],
            f"{fallback.rstrip('/')}/{relative}")


def generate_config(apps: Path, applications, *, check: bool, windows=False):
    filename = "base-windows.json" if windows else "base.json"
    output = "config-windows.json" if windows else "config.json"
    base = read_base(apps, filename)
    stable_version = base["stable_zsetup"]["version"]
    release_group = base["stable_zsetup"]["source_group"]
    records = []
    for application in applications:
        minimum = application.manifest["min_zsetup"]
        for os_name, package_manager, arch in sorted(application.expanded_targets):
            if (os_name == "windows") != windows:
                continue
            require(version_tuple(stable_version) >= version_tuple(minimum),
                    f"{application.id} requires zsetup >= {minimum}; base is {stable_version}")
            extension = "ps1" if os_name == "windows" else "sh"
            payload = application.directory / application.manifest["version"] / f"installer.{extension}"
            relative = f"{base['public_path_prefix']}/{payload.relative_to(apps).as_posix()}"
            raw = payload.read_bytes()
            records.append({
                "application": application.id,
                "os": os_name,
                "package_manager": package_manager,
                "arch": arch,
                "path": relative,
                "background": False,
                "source_group": release_group,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "size": len(raw),
                "min_version": minimum,
            })
    records.sort(key=lambda item: (item["application"], item["os"], item["package_manager"], item["arch"], item["path"]))
    identity = hashlib.sha256(json.dumps({
        "stable": stable_version, "installers": records,
    }, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:12]
    config = {
        "schema_version": 1,
        "config_version": f"apps-{identity}",
        "source_groups": base["source_groups"],
        "stable_zsetup": base["stable_zsetup"],
        "installers": records,
    }
    content = (json.dumps(config, ensure_ascii=True, indent=2) + "\n").encode()
    require(len(content) <= 131072,
            f"zsetup {output} exceeds the standard entry download bound")
    install_file(apps / "zsetup" / output, content, executable=False,
                 check=check, label=f"zsetup {output}")


def generate_checksums(apps: Path, *, check: bool):
    records = []
    for path in sorted(apps.rglob("*"), key=lambda item: item.relative_to(apps).as_posix()):
        if path == apps / "SHA256SUMS":
            continue
        require(not path.is_symlink(), f"symbolic link in public tree: {path}")
        if path.is_dir():
            continue
        require(path.is_file(), f"special file in public tree: {path}")
        relative = path.relative_to(apps).as_posix()
        records.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {relative}\n")
    install_file(apps / "SHA256SUMS", "".join(records).encode(), executable=False,
                 check=check, label="public checksums")


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apps", type=Path, default=root / "apps")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        build_ddnsto_installer.generate(root=root, apps=args.apps, check=args.check)
        applications = discover(args.apps)
        if not args.validate_only:
            generate_entries(root, applications, check=args.check)
            generate_config(args.apps, applications, check=args.check, windows=False)
            has_windows = any(os_name == "windows" for app in applications for os_name, _, _ in app.expanded_targets)
            if has_windows or (args.apps / "zsetup/base-windows.json").exists():
                generate_config(args.apps, applications, check=args.check, windows=True)
            build_ddnsto_site.generate(root, args.apps, check=args.check, install_file=install_file)
            generate_checksums(args.apps, check=args.check)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"apps build: {error}", file=sys.stderr)
        return 1
    print(f"Validated {len(applications)} applications")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
