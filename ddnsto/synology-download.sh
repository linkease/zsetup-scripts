#!/bin/sh
# Shared SPK selection; manual downloads and automatic DSM adapter use one pin.
ddnsto_synology_select() {
    synology_error() { printf 'DDNSTO: %s\n' "$1" >&2; }
    version_file=${DDNSTO_DSM_VERSION_FILE:-/etc.defaults/VERSION}
    [ -f "$version_file" ] && [ -r "$version_file" ] || {
        synology_error 'cannot read DSM VERSION'; return 2;
    }
    # Read data only. Do not source vendor VERSION or evaluate its contents.
    # Extract every occurrence so duplicate/ambiguous keys fail validation.
    # Count first: command substitution strips trailing empty lines.
    [ "$(grep -c '^[[:space:]]*majorversion[[:space:]]*=' "$version_file")" = 1 ] &&
        [ "$(grep -c '^[[:space:]]*buildnumber[[:space:]]*=' "$version_file")" = 1 ] || {
        synology_error 'DSM VERSION requires exactly one majorversion and buildnumber'; return 2;
    }
    major=$(sed -n '/^[[:space:]]*majorversion[[:space:]]*=/ {
        s/^[[:space:]]*majorversion[[:space:]]*=[[:space:]]*//
        s/[[:space:]]*$//
        s/^"\(.*\)"$/\1/
        p
    }' "$version_file") || return 2
    build=$(sed -n '/^[[:space:]]*buildnumber[[:space:]]*=/ {
        s/^[[:space:]]*buildnumber[[:space:]]*=[[:space:]]*//
        s/[[:space:]]*$//
        s/^"\(.*\)"$/\1/
        p
    }' "$version_file") || return 2
    case "$major" in 6|7) ;; *) synology_error 'unsupported or ambiguous DSM major version'; return 2 ;; esac
    case "$build" in ''|*[!0-9]*) synology_error 'invalid or ambiguous DSM build number'; return 2 ;; esac
    [ "${#build}" -le 9 ] || { synology_error 'invalid DSM build number'; return 2; }
    case "$major" in 6) minimum=5940 ;; 7) minimum=41890 ;; esac
    [ "$build" -ge "$minimum" ] || { synology_error 'DSM build is below the supported minimum'; return 2; }
    arch=$(uname -m) || return 2
    case "$arch" in
        x86_64) family=x86 ;;
        armv7|armv7l) family=arm ;;
        aarch64)
            # This model has a real ARM32 package canary; do not infer support
            # for every ARM64 DSM kernel from the SPK architecture list.
            model=$(cat "${DDNSTO_DSM_MODEL_FILE:-/proc/sys/kernel/syno_hw_version}" 2>/dev/null) || return 2
            [ "$major:$model" = 7:DS220j ] || { synology_error 'ARM64 model compatibility is unverified'; return 2; }
            family=arm ;;
        *) synology_error 'Synology SPK supports only x86_64 and armv7'; return 2 ;;
    esac
    case "$family:$major" in
        arm:6) digest=b83750595c95db591be99eb06749a7a657597426d13e4b699bce4c0ad16c3e60 ;;
        arm:7) digest=7286134081b518e5e339b60be7f51bc270979cbd4708998121f61e1d08470ad9 ;;
        x86:6) digest=9f3409198a7794212931e044c095a3133489c1241320f2fb45acea0c08011f03 ;;
        x86:7) digest=2842ea8b3b191528ccd8bf0f0600c99de540a56812531fe8b3fa4aacdde3fb87 ;;
    esac
    filename="ddnsto_${family}-dsm${major}.spk"
    relative="synology/4.2.8-7/$filename"
}

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

    ddnsto_synology_select || exit $?
    handoff() {
        printf '%s\n' 'platform=synology' 'package_version=4.2.8-7' \
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
