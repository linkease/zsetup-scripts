#!/usr/bin/env python3
"""Create a scoped core + kai-skills proposal from the current live config."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
BASES = [
    "https://dl.istoreos.com/binary",
    "https://fw.d4ctech.com/binary",
    "https://fw20.koolcenter.com/binary",
]
FALLBACK = "https://fw.koolcenter.com/binary"
KAI_SOURCE_GROUP = {
    "id": "kai-skills",
    "primary_bases": [base + "/kai/kai-skills" for base in BASES],
    "fallback_base": FALLBACK + "/kai/kai-skills",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    data = Path(path).read_bytes()
    require(len(data) <= 1024 * 1024, "input is too large")
    return data, json.loads(data)


def write_candidate(output, config, live_raw, version, skill_version, existing_apps):
    encoded = (json.dumps(config, ensure_ascii=True, indent=2) + "\n").encode()
    require(len(encoded) <= 131072, "proposed config exceeds native bound")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(encoded)
    print(json.dumps({
        "status": "candidate", "version": version, "kaiSkills": skill_version,
        "preservedApplications": existing_apps,
        "liveConfigSha256": hashlib.sha256(live_raw).hexdigest(),
        "proposedConfigSha256": hashlib.sha256(encoded).hexdigest(),
    }, sort_keys=True))


def windows_candidate(args, live_raw, config, measurements):
    version = measurements.get("version")
    require(version == "0.6.5", "canonical Windows zsetup 0.6.5 measurements are required")
    records = [record for record in measurements.get("records", [])
               if record.get("os") == "windows"]
    require(len(records) == 1 and records[0].get("arch") == "i686",
            "one canonical Windows i686 artifact is required")
    record = records[0]
    require(re.fullmatch(r"[0-9a-f]{64}", record.get("sha256", "")) and
            isinstance(record.get("size"), int) and record["size"] > 0,
            "invalid Windows artifact identity")
    require(config.get("schema_version") == 1, "live schema 1 config is required")
    source_id = config.get("stable_zsetup", {}).get("source_group")
    groups = [group for group in config.get("source_groups", [])
              if group.get("id") == source_id]
    require(len(groups) == 1 and groups[0].get("primary_bases") == BASES and
            groups[0].get("fallback_base") == FALLBACK,
            "live Windows sources differ from the contract")
    existing = [item for item in config.get("installers", [])
                if item.get("application") != "kai-skills"]
    live_kai = [item for item in config.get("installers", [])
                if item.get("application") == "kai-skills"]
    require(not live_kai or (len(live_kai) == 1 and live_kai[0].get("os") == "windows"),
            "live Windows kai-skills record is inconsistent")
    existing_apps = sorted({item["application"] for item in existing})
    spec = importlib.util.spec_from_file_location(
        "canonical_product_config", args.zsetup_root / "scripts/generate-product-config.py"
    )
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    _, canonical = generator.catalog_installers(ROOT / "catalog-windows.json", version)
    kai = [item for item in canonical if item["application"] == "kai-skills"]
    require(len(kai) == 1 and kai[0]["os"] == "windows",
            "canonical Windows kai-skills selector is missing")
    kai[0]["source_group"] = source_id
    for item in existing:
        item["min_version"] = version
    config["installers"] = existing + kai
    config["stable_zsetup"] = {
        "version": version,
        "source_group": source_id,
        "artifacts": [{
            "arch": "i686",
            "path": f"zsetup/{version}/zsetup-windows-i686.exe",
            "sha256": record["sha256"],
            "size": record["size"],
        }],
    }
    release = re.search(rb"\$script:KaiSkillsRelease = '([^']+)'",
                        (Path(__file__).resolve().parent /
                         "kai-skills-install.ps1").read_bytes())
    require(release is not None, "Windows release-bound installer identity is missing")
    skill_version = release.group(1).decode("ascii")
    config["config_version"] = (
        f"kai-skills-windows-{skill_version}-core-{version}-"
        f"{hashlib.sha256(live_raw).hexdigest()[:12]}"
    )
    require(sorted({item["application"] for item in config["installers"]
                    if item["application"] != "kai-skills"}) == existing_apps,
            "existing Windows applications were not preserved")
    write_candidate(args.output, config, live_raw, version, skill_version, existing_apps)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("linux", "windows"), default="linux")
    parser.add_argument("--live-config", required=True, type=Path)
    parser.add_argument("--measurements", required=True, type=Path)
    parser.add_argument("--zsetup-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    require(not args.output.exists() and not args.output.is_symlink(), "output must be new")
    live_raw, config = read(args.live_config)
    _, measurements = read(args.measurements)
    if args.platform == "windows":
        windows_candidate(args, live_raw, config, measurements)
        return
    version = measurements.get("version")
    require(version == "0.6.4", "canonical zsetup 0.6.4 measurements are required")
    records = [record for record in measurements.get("records", []) if record.get("os") == "linux"]
    require(len(records) == 4 and {record["arch"] for record in records} ==
            {"x86_64", "aarch64", "armv7", "mipsel"}, "incomplete Linux matrix")
    require(config.get("schema_version") == 1, "live schema 1 config is required")
    groups = [group for group in config["source_groups"] if group.get("id") == "koolcenter"]
    require(len(groups) == 1 and groups[0].get("primary_bases") == BASES and
            groups[0].get("fallback_base") == FALLBACK, "live sources differ from the contract")
    kai_groups = [group for group in config["source_groups"]
                  if group.get("id") == KAI_SOURCE_GROUP["id"]]
    require(len(kai_groups) <= 1 and (not kai_groups or kai_groups[0] == KAI_SOURCE_GROUP),
            "live kai-skills source group differs from the contract")
    existing = [item for item in config["installers"]
                if item.get("application") != "kai-skills"]
    live_kai = [item for item in config["installers"]
                if item.get("application") == "kai-skills"]
    require(not live_kai or (len(live_kai) == 2 and
            {item.get("os") for item in live_kai} == {"ubuntu", "openwrt"} and
            all(item.get("source_group") == KAI_SOURCE_GROUP["id"] for item in live_kai)),
            "live kai-skills installer records are inconsistent")
    existing_apps = sorted({item["application"] for item in existing})

    spec = importlib.util.spec_from_file_location(
        "canonical_product_config", args.zsetup_root / "scripts/generate-product-config.py"
    )
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    _, canonical = generator.catalog_installers(ROOT / "catalog.json", version)
    kai = [item for item in canonical if item["application"] == "kai-skills"]
    require(len(kai) == 2 and {item["os"] for item in kai} == {"ubuntu", "openwrt"},
            "canonical kai-skills selectors are incomplete")
    for item in kai:
        item["source_group"] = KAI_SOURCE_GROUP["id"]
        prefix = "kai/kai-skills/"
        require(item["path"].startswith(prefix), "kai-skills installer path is outside its source group")
        item["path"] = item["path"][len(prefix):]
    if not kai_groups:
        config["source_groups"].append(KAI_SOURCE_GROUP)
    for item in existing:
        item["min_version"] = version
    config["installers"] = existing + kai
    config["stable_zsetup"] = {
        "version": version,
        "source_group": "koolcenter",
        "artifacts": [
            {
                "arch": record["arch"],
                "path": f"zsetup/{version}/zsetup-linux-{record['arch']}",
                "sha256": record["sha256"],
                "size": record["size"],
            }
            for record in sorted(records, key=lambda value: value["arch"])
        ],
    }
    release = re.search(rb"KAI_SKILLS_RELEASE='([^']+)'",
                        (Path(__file__).resolve().parent / "kai-skills-install.sh").read_bytes())
    require(release is not None, "release-bound installer identity is missing")
    skill_version = release.group(1).decode("ascii")
    config["config_version"] = (
        f"kai-skills-{skill_version}-core-{version}-"
        f"{hashlib.sha256(live_raw).hexdigest()[:12]}"
    )
    require(sorted({item["application"] for item in config["installers"]
                    if item["application"] != "kai-skills"}) == existing_apps,
            "existing applications were not preserved")
    write_candidate(args.output, config, live_raw, version, skill_version, existing_apps)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise SystemExit("failed: " + str(error))
