#!/bin/sh
# Source-only Synology SPK download/manual-handoff helper.
# Downloads and digest verification belong to the caller's ddnsto_download.
ddnsto_synology_download() (
    umask 077
    synology_error() { printf 'DDNSTO: %s\n' "$1" >&2; }
    case "${ACTION:-install}" in
        install|download) ;;
        *) synology_error 'Synology supports only download or manual install handoff'; exit 2 ;;
    esac
    if [ -n "${TOKEN:-}${TOKEN_FILE:-}${FORCE_VERSION:-}" ] ||
        [ "${VERIFY_STATUS:-0}" != 0 ]; then
        synology_error 'Synology download does not accept credentials or installation flags; configure the package in DSM'
        exit 2
    fi
    case "${REQUESTED_METHOD:-auto}" in
        auto|native) ;;
        *) synology_error 'Synology download supports only auto or native method'; exit 2 ;;
    esac
    case "${PLAN_ONLY:-0}" in 0|1) ;; *) synology_error 'invalid plan flag'; exit 2 ;; esac

    version_file=${DDNSTO_DSM_VERSION_FILE:-/etc.defaults/VERSION}
    [ -f "$version_file" ] && [ -r "$version_file" ] || {
        synology_error 'cannot read DSM VERSION'; exit 2;
    }
    # Read data only. Do not source vendor VERSION or evaluate its contents.
    # Extract every occurrence so duplicate/ambiguous keys fail validation.
    # Count first: command substitution strips trailing empty lines.
    [ "$(grep -c '^[[:space:]]*majorversion[[:space:]]*=' "$version_file")" = 1 ] &&
        [ "$(grep -c '^[[:space:]]*buildnumber[[:space:]]*=' "$version_file")" = 1 ] || {
        synology_error 'DSM VERSION requires exactly one majorversion and buildnumber'; exit 2;
    }
    major=$(sed -n '/^[[:space:]]*majorversion[[:space:]]*=/ {
        s/^[[:space:]]*majorversion[[:space:]]*=[[:space:]]*//
        s/[[:space:]]*$//
        s/^"\(.*\)"$/\1/
        p
    }' "$version_file") || exit 2
    build=$(sed -n '/^[[:space:]]*buildnumber[[:space:]]*=/ {
        s/^[[:space:]]*buildnumber[[:space:]]*=[[:space:]]*//
        s/[[:space:]]*$//
        s/^"\(.*\)"$/\1/
        p
    }' "$version_file") || exit 2
    case "$major" in 6|7) ;; *) synology_error 'unsupported or ambiguous DSM major version'; exit 2 ;; esac
    case "$build" in ''|*[!0-9]*) synology_error 'invalid or ambiguous DSM build number'; exit 2 ;; esac
    [ "${#build}" -le 9 ] || { synology_error 'invalid DSM build number'; exit 2; }
    case "$major" in 6) minimum=5940 ;; 7) minimum=41890 ;; esac
    [ "$build" -ge "$minimum" ] || { synology_error 'DSM build is below the supported minimum'; exit 2; }
    arch=$(uname -m) || exit 2
    case "$arch" in
        x86_64) family=x86 ;;
        armv7|armv7l) family=arm ;;
        *) synology_error 'Synology SPK supports only x86_64 and armv7'; exit 2 ;;
    esac
    case "$family:$major" in
        arm:6) digest=0595dd1ae1681213acb35dfc61e15d877bfee19e59d5f4242a366540922b7f89 ;;
        arm:7) digest=bde9af2d3ff17f4bc5c609b79af39da7efd7209c59d03935492d1748bb84eba5 ;;
        x86:6) digest=89d5871b7162edba9e4467a619d5d2eae19744d9cf637692e0695a1a4a701a83 ;;
        x86:7) digest=cccf82a0240c235d5eea6465ca9a339a9d92977345418ab72deb79ce2a3c8b59 ;;
    esac
    filename="ddnsto_${family}-dsm${major}.spk"
    relative="synology/$filename"
    handoff() {
        printf '%s\n' 'platform=synology' 'package_version=4.2.7-4' \
            "dsm_major=$major" "dsm_build=$build" "arch=$arch" \
            'installation_performed=false' 'installation_status=manual-required' \
            'Open DSM Package Center > Manual Install and import the downloaded SPK.' \
            'Identity migration: back up existing Token/configuration and device identity before upgrading or migrating; follow the package migration instructions and verify the device identity afterward. No identity migration is performed by this helper.'
    }
    if [ "${PLAN_ONLY:-0}" = 1 ]; then
        printf '%s\n' 'operation=plan' 'download_performed=false' "package_relative=$relative" "package_sha256=$digest"
        handoff
        exit 0
    fi
    OUTPUT_DIR=${OUTPUT_DIR:-$PWD/ddnsto-downloads}
    # Prefix relative paths to avoid interpreting a leading '-' as an option.
    case "$OUTPUT_DIR" in /*) output=$OUTPUT_DIR ;; *) output="./$OUTPUT_DIR" ;; esac
    [ ! -L "$output" ] || { synology_error 'output directory must not be a symlink'; exit 2; }
    mkdir -p "$output" || exit 2
    output=$(cd "$output" && pwd -P) || exit 2
    work=$(mktemp -d "$output/ddnsto-synology.XXXXXX") || exit 2
    keep=0
    cleanup_synology() {
        code=$?
        trap - EXIT HUP INT TERM
        if [ "$keep" = 0 ]; then
            # Only our private staging file; never remove an existing package
            # or recursively delete the caller's output directory.
            rm -f "$work/$filename.part"
            rmdir "$work" 2>/dev/null || true
        fi
        exit "$code"
    }
    trap cleanup_synology EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ddnsto_download "$relative" "$work/$filename.part" "$digest" || exit "$?"
    [ -f "$work/$filename.part" ] && [ -s "$work/$filename.part" ] && [ ! -L "$work/$filename.part" ] || {
        synology_error 'verified download did not produce a regular nonempty SPK'; exit 11;
    }
    mv "$work/$filename.part" "$work/$filename" || exit 2
    keep=1
    printf '%s\n' 'operation=download' 'download_performed=true' "package_path=$work/$filename" "package_sha256=$digest"
    handoff
    [ "${ACTION:-install}" = download ] || exit 20
)
