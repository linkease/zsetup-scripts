# KaiPlus owns complete schema-2 snapshots. Do not project these into a Codex
# directory or bootstrap another runtime. This mode only prepares a snapshot;
# the live KaiPlus parent verifies the plan and performs the atomic activation.
if [ "${1:-}" = --source ]; then
    if [ "$#" != 6 ] || [ "$2" != kaiplus ] || [ "$3" != --system ] || [ "$5" != --context ] || [ -z "${KAI_PLUS_BIN:-}" ]; then
        echo 'kai-skills: KaiPlus requires --source kaiplus --system SYSTEM --context CONTEXT and its binary' >&2
        exit 2
    fi
    # Host identity is metadata, not a filter on the complete KaiPlus snapshot.
    case "$4" in istoreos|debian|ubuntu|windows|macos|asusgo|generic-linux) ;; *) echo 'kai-skills: unsupported KaiPlus system' >&2; exit 2 ;; esac
    case "$KAI_PLUS_BIN:$6" in /*:/*) ;; *) echo 'kai-skills: KaiPlus paths must be absolute' >&2; exit 2 ;; esac
    if [ ! -x "$KAI_PLUS_BIN" ] || [ ! -f "$6" ] || [ -L "$6" ]; then
        echo 'kai-skills: KaiPlus private context or binary is unavailable' >&2
        exit 2
    fi
    exec "$KAI_PLUS_BIN" _skills_prepare "$6" --source "$2" --system "$4"
fi
