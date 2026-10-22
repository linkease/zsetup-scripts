# Read-only, bounded Docker discovery; never changes context or starts an engine.
# A reachable engine is NOT proof of a supported DDNSTO container installation.
ddnsto_probe_docker() (
    command -v docker >/dev/null 2>&1 || { echo cli-unavailable; return; }
    command -v timeout >/dev/null 2>&1 || { echo probe-timeout-unavailable; return; }
    if [ -n "${DOCKER_CONTEXT:-}" ]; then
        endpoint=$(timeout 5 docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || { echo context-unavailable; return; }
    elif [ -n "${DOCKER_HOST:-}" ]; then
        endpoint=$DOCKER_HOST
    else
        endpoint=$(timeout 5 docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || { echo context-unavailable; return; }
    fi
    case "$endpoint" in
        unix:///*) socket_path=${endpoint#unix://} ;;
        '') echo context-unavailable; return ;;
        *) echo remote-endpoint; return ;;
    esac
    [ -S "$socket_path" ] || { echo socket-unavailable; return; }
    # Explicit endpoint prevents a context change from redirecting this probe.
    # Clear DOCKER_CONTEXT, which otherwise conflicts with an explicit host.
    unset DOCKER_CONTEXT
    engine=$(timeout 5 docker --host "$endpoint" info --format '{{.OSType}}|{{.Architecture}}|{{.OperatingSystem}}' 2>/dev/null) || { echo engine-unreachable; return; }
    case "$engine" in
        *'Docker Desktop'*) echo desktop-engine-unverified ;;
        linux\|*\|*) echo local-linux-engine ;;
        *) echo unsupported-engine ;;
    esac
)
