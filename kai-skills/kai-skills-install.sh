#!/bin/sh
set -eu

KAI_SKILLS_RELEASE='1.2.5'
KAI_SKILLS_MANIFEST_PATH='releases/1.2.5/release-manifest.json'
KAI_SKILLS_MANIFEST_SHA256='cc62e2e00e75bf76ab6c26c4c49a56e0ee791fa8ebe9186445266148bdd999b7'
KAI_SKILLS_MANIFEST_SIZE='29797'

kai_skills_fail() {
    echo "kai-skills: $*" >&2
    return 2
}

kai_skills_safe_id() {
    case "$1" in ''|*[!a-z0-9-]*) return 1 ;; esac
}

kai_skills_download() {
    relative=$1 destination=$2 expected_sha=$3 expected_size=$4
    set -- "$ZSETUP_BIN" download -o "$destination" --sha256 "$expected_sha" \
        --size "$expected_size" --max-bytes "$expected_size"
    for base in $ZSETUP_SOURCE_BASES; do
        set -- "$@" "${base%/}/$relative"
    done
    if [ -n "${ZSETUP_SOURCE_FALLBACK:-}" ]; then
        set -- "$@" --fallback-url "${ZSETUP_SOURCE_FALLBACK%/}/$relative"
    fi
    "$@"
}

kai_skills_target() {
    if [ -n "$kai_target" ]; then
        printf '%s\n' "$kai_target"
        return
    fi
    case "$kai_scope:$kai_consumer" in
        user:codex) printf '%s\n' "$HOME/.agents/skills" ;;
        user:claude) printf '%s\n' "$HOME/.claude/skills" ;;
        user:opencode) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills" ;;
        project:codex) printf '%s\n' "${KAI_SKILLS_PROJECT_ROOT:-$PWD}/.agents/skills" ;;
        project:claude) printf '%s\n' "${KAI_SKILLS_PROJECT_ROOT:-$PWD}/.claude/skills" ;;
        project:opencode) printf '%s\n' "${KAI_SKILLS_PROJECT_ROOT:-$PWD}/.opencode/skills" ;;
        *) return 2 ;;
    esac
}

kai_skills_install() {
    : "${ZSETUP_BIN:?zsetup is required}" "${ZSETUP_SOURCE_BASES:?source group is required}"
    if [ -n "${KAI_SKILLS_REQUESTED_RELEASE:-}" ] && [ "$KAI_SKILLS_REQUESTED_RELEASE" != "$KAI_SKILLS_RELEASE" ]; then
        kai_skills_fail "entrypoint release $KAI_SKILLS_REQUESTED_RELEASE does not match configured release $KAI_SKILLS_RELEASE"
        return $?
    fi
    kai_skill= kai_system= kai_mode=on-device kai_consumer=codex kai_scope=user kai_target=
    kai_action=install kai_dry=0 kai_json=0 kai_install_mode=copy kai_architecture= kai_update_shared=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --skill) [ "$#" -ge 2 ] || kai_skills_fail 'missing --skill value'; kai_skill=$2; shift ;;
            --system) [ "$#" -ge 2 ] || kai_skills_fail 'missing --system value'; kai_system=$2; shift ;;
            --mode) [ "$#" -ge 2 ] || kai_skills_fail 'missing --mode value'; kai_mode=$2; shift ;;
            --consumer) [ "$#" -ge 2 ] || kai_skills_fail 'missing --consumer value'; kai_consumer=$2; shift ;;
            --scope) [ "$#" -ge 2 ] || kai_skills_fail 'missing --scope value'; kai_scope=$2; shift ;;
            --target-skills|--target) [ "$#" -ge 2 ] || kai_skills_fail 'missing target value'; kai_target=$2; shift ;;
            --architecture) [ "$#" -ge 2 ] || kai_skills_fail 'missing architecture value'; kai_architecture=$2; shift ;;
            --dry-run) kai_dry=1 ;;
            --json) kai_json=1 ;;
            --upgrade) kai_action=upgrade ;;
            --uninstall) kai_action=uninstall ;;
            --copy) kai_install_mode=copy ;;
            --symlink) kai_install_mode=symlink ;;
            --update-shared) kai_update_shared=1 ;;
            *) kai_skills_fail "unknown option $1" || return $? ;;
        esac
        shift
    done
    [ -n "$kai_skill" ] || [ -n "$kai_system" ] || kai_skills_fail 'choose --skill or --system' || return $?
    [ -z "$kai_skill" ] || [ -z "$kai_system" ] || kai_skills_fail 'choose only one selection' || return $?
    [ -z "$kai_skill" ] || kai_skills_safe_id "$kai_skill" || kai_skills_fail 'invalid skill id' || return $?
    case "$kai_system" in ''|istoreos|ubuntu) ;; *) kai_skills_fail 'unsupported system' || return $? ;; esac
    [ "$kai_mode" = on-device ] || kai_skills_fail 'only the locked on-device system collection is published' || return $?
    case "$kai_consumer" in codex|claude|opencode) ;; *) kai_skills_fail 'unsupported consumer' || return $? ;; esac
    case "$kai_scope" in user|project) ;; *) kai_skills_fail 'scope must be user or project' || return $? ;; esac
    [ "$kai_update_shared" = 0 ] || [ "$kai_action" = upgrade ] || kai_skills_fail '--update-shared requires --upgrade' || return $?
    command -v jq >/dev/null 2>&1 || kai_skills_fail 'jq is required' || return $?

    kai_target=$(kai_skills_target) || kai_skills_fail 'cannot resolve target skills directory' || return $?
    case "$kai_target" in ''|/|.|..) kai_skills_fail 'unsafe target skills directory' || return $? ;; esac
    kai_work_base=${KAI_SKILLS_WORK_BASE:-${TMPDIR:-/tmp}}
    case "$kai_work_base" in ''|/|.|..) kai_skills_fail 'unsafe work base' || return $? ;; esac
    kai_work=$kai_work_base/kai-skills-$$
    umask 077
    mkdir "$kai_work" || return 12
    kai_skills_cleanup() { rm -rf "$kai_work"; }
    trap kai_skills_cleanup EXIT HUP INT TERM

    kai_manifest=$kai_work/release-manifest.json
    kai_skills_download "$KAI_SKILLS_MANIFEST_PATH" "$kai_manifest" \
        "$KAI_SKILLS_MANIFEST_SHA256" "$KAI_SKILLS_MANIFEST_SIZE" || return $?
    if [ -n "$kai_skill" ]; then kai_kind=skill; kai_id=$kai_skill; else kai_kind=system; kai_id=$kai_system; fi
    kai_record=$(jq -er --arg kind "$kai_kind" --arg id "$kai_id" --arg version "$KAI_SKILLS_RELEASE" '
      if .schemaVersion != 3 or .distribution != "kai-skills-zsetup" or .version != $version or
         .minimumZsetupVersion != "0.6.0" or .archiveFormat != "tar.gz" then error("manifest contract") else . end |
      [.artifacts[] | select(.kind==$kind and .id==$id)] |
      if length != 1 then error("selection is not published") else .[0] end |
      [.path, (.size|tostring), .sha256, .root, (.expandedSize|tostring), (.fileCount|tostring)] | @tsv
    ' "$kai_manifest") || { echo 'kai-skills: invalid or unavailable selection' >&2; return 11; }
    IFS="$(printf '\t')" read -r kai_path kai_size kai_sha kai_root kai_expanded kai_files <<EOF
$kai_record
EOF
    case "$kai_path" in "$kai_kind"s/*.tar.gz) ;; *) echo 'kai-skills: unsafe artifact path' >&2; return 11 ;; esac
    case "$kai_sha" in sha256:????????????????????????????????????????????????????????????????) ;; *) return 11 ;; esac
    case "$kai_size:$kai_expanded:$kai_files" in *[!0-9:]*|0:*|*:0:*|*:0) return 11 ;; esac
    case "$kai_root" in ''|.|..|*/*|*\\*) return 11 ;; esac
    kai_archive=$kai_work/package.tar.gz
    kai_skills_download "releases/$KAI_SKILLS_RELEASE/$kai_path" "$kai_archive" \
        "${kai_sha#sha256:}" "$kai_size" || return $?
    kai_stage=$kai_work/extracted
    "$ZSETUP_BIN" archive extract --input "$kai_archive" --output "$kai_stage" --root "$kai_root" \
        --max-bytes "$kai_expanded" --max-files "$kai_files" \
        --min-free-bytes "${KAI_SKILLS_MIN_FREE_BYTES:-16777216}" || return $?
    kai_package=$kai_stage/$kai_root
    [ -f "$kai_package/install.sh" ] && [ ! -L "$kai_package/install.sh" ] || return 11

    if [ -n "$kai_skill" ]; then
        set -- --skill "$kai_skill"
    else
        set -- --platform "$kai_system" --all --mode "$kai_mode"
    fi
    set -- "$@" --consumer "$kai_consumer" --scope "$kai_scope" --target-skills "$kai_target"
    [ -z "$kai_architecture" ] || set -- "$@" --architecture "$kai_architecture"
    [ "$kai_dry" = 0 ] || set -- "$@" --dry-run
    [ "$kai_json" = 0 ] || set -- "$@" --json
    [ "$kai_install_mode" = copy ] || set -- "$@" --symlink
    [ "$kai_update_shared" = 0 ] || set -- "$@" --update-shared
    case "$kai_action" in upgrade) set -- "$@" --upgrade ;; uninstall) set -- "$@" --uninstall ;; esac
    export ZSETUP_BIN KAI_SKILLS_RELEASE
    sh "$kai_package/install.sh" "$@"
}

main() {
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        kai_skills_install "$@"
    else
        exec "${ZSETUP_BIN:-zsetup}" install kai-skills --foreground -- "$@"
    fi
}

main "$@"
