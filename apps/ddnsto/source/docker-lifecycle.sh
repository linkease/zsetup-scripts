# Restricted engineering candidate, not a native-device acceptance claim.
# main must embed this source, parse inputs, and hold the shared machine lock
# around ddnsto_docker_lifecycle for every mutating action. No bootstrap needed.
# Inputs: REQUESTED_METHOD=docker, detected_platform=linux, ACTION (default
# install), TOKEN (supplied or prompted only for conflict-free fresh install), DEVICE_NAME, NETWORK (or
# DDNSTO_DOCKER_NETWORK). main resolves TOKEN_FILE into TOKEN; this executor
# never reads TOKEN_FILE. Existing-container operations reject both inputs.
# DDNSTO_DOCKER_STATE_DIR is an engineering override, not a multi-instance API.
# Fresh install only. Same-pin update is a no-op; recreation/upgrade is blocked
# until the published binary's identity persistence has been verified.
# Uninstall retains ALL private state for future validated reinstallation.
# No claim that /ddnsto-config contains every identity input used by this image.

ddnsto_docker_error() { printf 'DDNSTO Docker: %s\n' "$*" >&2; }

ddnsto_docker_cli() (
    unset DOCKER_CONTEXT DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH
    timeout 120 docker --host "$ddocker_endpoint" "$@"
)

ddnsto_docker_discover() {
    [ "${REQUESTED_METHOD:-}" = docker ] && [ "${detected_platform:-}" = linux ] || {
        ddnsto_docker_error 'explicit Docker on generic Linux is required'; return 2;
    }
    [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || return 2
    for ddocker_nas in /etc/synoinfo.conf /usr/syno /etc/config/uLinux.conf /etc/unraid-version /etc/openwrt_release; do
        [ ! -e "$ddocker_nas" ] || { ddnsto_docker_error 'NAS/OpenWrt networking is not accepted'; return 2; }
    done
    command -v docker >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 || return 2
    if [ -n "${DOCKER_CONTEXT:-}" ]; then
        ddocker_endpoint=$(timeout 5 docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || return 2
    elif [ -n "${DOCKER_HOST:-}" ]; then
        ddocker_endpoint=$DOCKER_HOST
    else
        ddocker_endpoint=$(timeout 5 docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || return 2
    fi
    case "$ddocker_endpoint" in unix:///*) ;; *) ddnsto_docker_error 'local Unix endpoint required'; return 2 ;; esac
    case "$ddocker_endpoint" in *[!a-zA-Z0-9_./:-]*) return 2 ;; esac
    [ -S "${ddocker_endpoint#unix://}" ] || return 2
    ddocker_engine=$(
        unset DOCKER_CONTEXT DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH
        timeout 5 docker --host "$ddocker_endpoint" info --format '{{.OSType}}|{{.Architecture}}|{{.OperatingSystem}}|{{json .SecurityOptions}}' 2>/dev/null
    ) || return 2
    case "$ddocker_engine" in *Desktop*|*rootless*) ddnsto_docker_error 'Desktop/rootless engine is not accepted'; return 2 ;; esac
    case "$ddocker_engine" in linux\|x86_64\|*\|*|linux\|amd64\|*\|*) ;; *) ddnsto_docker_error 'Linux amd64 engine required'; return 2 ;; esac
    case "${ddocker_engine##*|}" in \[*\]) ;; *) ddnsto_docker_error 'engine security information unavailable'; return 2 ;; esac
    ddocker_image=linkease/ddnsto@sha256:f70d2afbb0da6b21ff8865a4f3d9869775360bfbec1fff03474e5478a702ad30
    ddocker_dir=${DDNSTO_DOCKER_STATE_DIR:-/etc/ddnsto-docker}
    case "$ddocker_dir" in /*) ;; *) return 2 ;; esac
    case "$ddocker_dir" in /|*/|*//*|*/../*|*/./*|*/..|*/.|*[!a-zA-Z0-9_./-]*) return 2 ;; esac
    # Inspect every component without following symlinks, even for fresh state.
    ddocker_component=$ddocker_dir
    while [ "$ddocker_component" != / ]; do
        [ ! -L "$ddocker_component" ] || { ddnsto_docker_error 'symlink state path rejected'; return 2; }
        ddocker_component=${ddocker_component%/*}
        ddocker_component=${ddocker_component:-/}
    done
}

ddnsto_docker_plan() (
    ddnsto_docker_discover || exit $?
    printf '%s\n' 'method=docker candidate=engineering' 'docker_installable=false' \
        'candidate_executor=available production_acceptance=unverified' \
        'network_required=bridge-or-host device_name_required=true' \
        'identity_persistence=unverified installation_performed=false'
)

ddnsto_docker_safe_value() {
    case "$1" in ''|*[!a-zA-Z0-9_-]*|-*) return 2 ;; esac
    [ "${#1}" -le 128 ]
}

ddnsto_docker_prompt_field() (
    exec 3<>/dev/tty
    printf '%s' "$1" >&3
    IFS= read -r ddocker_answer <&3 || exit 2
    printf '%s' "$ddocker_answer"
)

ddnsto_docker_fresh_inputs() {
    if [ -n "${NETWORK:-}" ] && [ -n "${DDNSTO_DOCKER_NETWORK:-}" ] && [ "$NETWORK" != "$DDNSTO_DOCKER_NETWORK" ]; then return 2; fi
    ddocker_network=${NETWORK:-${DDNSTO_DOCKER_NETWORK:-}}
    ddocker_token=${TOKEN:-}; ddocker_name=${DEVICE_NAME:-}
    # Reject invalid supplied fields before collecting any missing input.
    case "$ddocker_network" in ''|bridge|host) ;; *) ddnsto_docker_error 'network must be bridge or host'; return 2 ;; esac
    for ddocker_value in "$ddocker_token" "$ddocker_name"; do
        [ -z "$ddocker_value" ] || ddnsto_docker_safe_value "$ddocker_value" || {
            ddnsto_docker_error 'unsafe Token or device name'; return 2;
        }
    done
    if [ -z "$ddocker_token" ] && [ -n "${TOKEN_FILE:-}" ]; then
        ddnsto_docker_error 'Token file must be resolved by the entrypoint'; return 2
    fi
    if [ -z "$ddocker_token" ] || [ -z "$ddocker_name" ] || [ -z "$ddocker_network" ]; then
        [ -t 0 ] || {
            ddnsto_docker_error 'noninteractive fresh install requires Token, device name and explicit bridge or host network'; return 2;
        }
    fi
    if [ -z "$ddocker_token" ]; then
        ddocker_token=$(ddnsto_prompt_token) || { ddnsto_docker_error 'could not read Token'; return 2; }
    fi
    ddnsto_docker_safe_value "$ddocker_token" || { ddnsto_docker_error 'empty or unsafe Token'; return 2; }
    if [ -z "$ddocker_name" ]; then
        ddocker_name=$(ddnsto_docker_prompt_field 'Docker device name: ') || return 2
    fi
    ddnsto_docker_safe_value "$ddocker_name" || { ddnsto_docker_error 'empty or unsafe device name'; return 2; }
    if [ -z "$ddocker_network" ]; then
        ddocker_network=$(ddnsto_docker_prompt_field 'Docker network [bridge/host]: ') || return 2
    fi
    case "$ddocker_network" in bridge|host) ;; *) ddnsto_docker_error 'network must be bridge or host'; return 2 ;; esac
}

ddnsto_docker_private_file() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u:%a:%h' "$1")" = "$(id -u):600:1" ]
}

ddnsto_docker_load() {
    [ -d "$ddocker_dir" ] && [ "$(stat -c '%u:%a' "$ddocker_dir")" = "$(id -u):700" ] || return 2
    for ddocker_file in container.env endpoint network image-id container-id; do
        ddnsto_docker_private_file "$ddocker_dir/$ddocker_file" || return 2
    done
    [ -d "$ddocker_dir/identity" ] && [ ! -L "$ddocker_dir/identity" ] || return 2
    [ "$(stat -c '%u:%a' "$ddocker_dir/identity")" = "$(id -u):700" ] || return 2
    [ "$(cat "$ddocker_dir/endpoint")" = "$ddocker_endpoint" ] || return 2
    ddocker_network=$(cat "$ddocker_dir/network")
    case "$ddocker_network" in bridge|host) ;; *) return 2 ;; esac
    ddocker_image_id=$(cat "$ddocker_dir/image-id")
    case "$ddocker_image_id" in sha256:*) ;; *) return 2 ;; esac
    [ "${#ddocker_image_id}" = 71 ] || return 2
    case "${ddocker_image_id#sha256:}" in *[!a-f0-9]*) return 2 ;; esac
    # Parse data, never source the env file. Reject extra keys and line changes.
    ddocker_token= ddocker_name=
    while IFS= read -r ddocker_line; do
        case "$ddocker_line" in
            TOKEN=*) [ -z "$ddocker_token" ] || return 2; ddocker_token=${ddocker_line#TOKEN=} ;;
            DEVICE_NAME=*) [ -z "$ddocker_name" ] || return 2; ddocker_name=${ddocker_line#DEVICE_NAME=} ;;
            *) return 2 ;;
        esac
    done < "$ddocker_dir/container.env"
    ddnsto_docker_safe_value "$ddocker_token" && ddnsto_docker_safe_value "$ddocker_name" || return 2
    printf 'TOKEN=%s\nDEVICE_NAME=%s\n' "$ddocker_token" "$ddocker_name" | cmp -s - "$ddocker_dir/container.env" || return 2
    ddocker_recorded_id=$(cat "$ddocker_dir/container-id")
    [ "$ddocker_recorded_id" = "$ddocker_id" ] || return 2
}

ddnsto_docker_expected() {
    printf '%s\n' "image=$ddocker_image" "imageid=$ddocker_image_id" \
        'name=/ddnsto-managed' "network=$ddocker_network" "attached_network=$ddocker_network" 'restart=unless-stopped' \
        'user=' 'privileged=false' 'cmd=["/usr/bin/ddnsto-monitor.sh"]' 'entrypoint=null' \
        'readonly=false' 'pid=' 'ipc=private' 'caps=0|0' 'security=0' 'devices=0' 'ports=0' \
        'groups=0' 'volumesfrom=0' 'device_requests=0' 'network_links=0' \
        "mount=bind|$ddocker_dir/identity|/ddnsto-config|true|rprivate" \
        'env=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
        'env=TZ=Asia/Shanghai' 'env=LOG_LEVEL=2' "env=TOKEN=$ddocker_token" \
        "env=DEVICE_NAME=$ddocker_name" 'label=io.ddnsto.installer=docker-candidate-v1' \
        "label=io.ddnsto.state=$ddocker_dir" 'label=maintainer=Janson <janson@linkease.com>'
}

ddnsto_docker_owned() {
    # Compare the complete allowlisted env/labels/mounts and execution settings.
    # Never echo inspect output: it contains credentials.
    ddocker_actual=$(ddnsto_docker_cli inspect --format 'image={{.Config.Image}}
imageid={{.Image}}
name={{.Name}}
network={{.HostConfig.NetworkMode}}
{{range $k,$v := .NetworkSettings.Networks}}attached_network={{$k}}
{{end}}restart={{.HostConfig.RestartPolicy.Name}}
user={{.Config.User}}
privileged={{.HostConfig.Privileged}}
cmd={{json .Config.Cmd}}
entrypoint={{json .Config.Entrypoint}}
readonly={{.HostConfig.ReadonlyRootfs}}
pid={{.HostConfig.PidMode}}
ipc={{.HostConfig.IpcMode}}
caps={{len .HostConfig.CapAdd}}|{{len .HostConfig.CapDrop}}
security={{len .HostConfig.SecurityOpt}}
devices={{len .HostConfig.Devices}}
ports={{len .HostConfig.PortBindings}}
groups={{len .HostConfig.GroupAdd}}
volumesfrom={{len .HostConfig.VolumesFrom}}
device_requests={{len .HostConfig.DeviceRequests}}
network_links={{len .HostConfig.Links}}
{{range .Mounts}}mount={{.Type}}|{{.Source}}|{{.Destination}}|{{.RW}}|{{.Propagation}}
{{end}}{{range .Config.Env}}env={{.}}
{{end}}{{range $k,$v := .Config.Labels}}label={{$k}}={{$v}}
{{end}}' "$ddocker_id" 2>/dev/null) || return 2
    ddocker_actual=$(printf '%s\n' "$ddocker_actual" | LC_ALL=C sort)
    ddocker_expected=$(ddnsto_docker_expected | LC_ALL=C sort)
    [ "$ddocker_actual" = "$ddocker_expected" ] || {
        ddnsto_docker_error 'container ownership/configuration mismatch; no changes made'; return 2;
    }
}

ddnsto_docker_report() {
    ddocker_running=$(ddnsto_docker_cli inspect --format '{{.State.Running}}' "$ddocker_id" 2>/dev/null) || return 2
    case "$ddocker_running" in true|false) ;; *) return 2 ;; esac
    printf 'operation=%s container_running=%s client_process=unverified cloud_status=unverified identity_persistence=unverified\n' "$1" "$ddocker_running"
}

ddnsto_docker_lifecycle() (
    # Disable tracing before reading private state or resolving Token arguments.
    set +x
    umask 077
    ACTION=${ACTION:-install}
    case "$ACTION" in install|update|status|start|stop|restart|uninstall|repair) ;; *) ddnsto_docker_error 'unsupported Docker action'; exit 2 ;; esac
    if [ "$ACTION" != status ] && [ "$(id -u)" != 0 ]; then
        ddnsto_docker_error 'Docker write actions require a root shell: run sudo -i, then rerun the installer in that shell. Elevating only the operation lock is insufficient.'
        exit 2
    fi
    ddnsto_docker_discover || exit $?
    [ -z "${DEVICE_IDX:-}${PUID:-}${PGID:-}${SUPPLIER_CODE:-}${FORCE_VERSION:-}" ] && [ "${VERIFY_STATUS:-0}" = 0 ] || {
        ddnsto_docker_error 'unsupported Docker fields'; exit 2;
    }
    for ddocker_native in "${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}" "${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}"; do
        [ ! -e "$ddocker_native" ] && [ ! -L "$ddocker_native" ] || { ddnsto_docker_error 'native installation conflict'; exit 2; }
    done
    # Query success is mandatory: an inaccessible engine is never an empty host.
    ddocker_id=$(ddnsto_docker_cli ps -a --no-trunc --filter 'name=^/ddnsto-managed$' --format '{{.ID}}' 2>/dev/null) || exit 2
    ddocker_labeled=$(ddnsto_docker_cli ps -a --no-trunc --filter 'label=io.ddnsto.installer=docker-candidate-v1' --format '{{.ID}}' 2>/dev/null) || exit 2
    [ "$ddocker_labeled" = "$ddocker_id" ] || { ddnsto_docker_error 'conflicting or renamed managed container'; exit 2; }
    if [ -n "$ddocker_id" ]; then
        case "$ddocker_id" in *[!a-f0-9]*) exit 2 ;; esac
        [ "${#ddocker_id}" = 64 ] || exit 2
        [ -z "${TOKEN:-}${TOKEN_FILE:-}${DEVICE_NAME:-}${NETWORK:-}${DDNSTO_DOCKER_NETWORK:-}" ] || {
            ddnsto_docker_error 'existing installation preserves credentials and networking'; exit 2;
        }
        ddnsto_docker_load && ddnsto_docker_owned || exit 2
        case "$ACTION" in
            install|update)
                printf '%s\n' 'operation=none installation=existing version=4.2.6 cloud_status=unverified' \
                    'identity_persistence=unverified replacement_update=blocked'
                exit 0 ;;
            status) ddnsto_docker_report status; exit $? ;;
            uninstall)
                ddnsto_docker_cli stop "$ddocker_id" >/dev/null 2>&1 || exit 13
                ddocker_running=$(ddnsto_docker_cli inspect --format '{{.State.Running}}' "$ddocker_id" 2>/dev/null) || exit 13
                [ "$ddocker_running" = false ] || exit 13
                ddnsto_docker_cli rm "$ddocker_id" >/dev/null 2>&1 || exit 13
                printf '%s\n' 'operation=uninstall state=retained cloud_status=unverified reinstall=blocked-identity-unverified'
                exit 0 ;;
            repair) ddocker_command=start ;;
            *) ddocker_command=$ACTION ;;
        esac
        ddnsto_docker_cli "$ddocker_command" "$ddocker_id" >/dev/null 2>&1 || { ddnsto_docker_error 'container operation failed; retained state'; exit 13; }
        ddnsto_docker_report "$ACTION" || exit $?
        if [ "$ACTION" = stop ]; then [ "$ddocker_running" = false ] || exit 13
        else [ "$ddocker_running" = true ] || exit 13; fi
        exit 0
    fi
    [ ! -e "$ddocker_dir" ] || { ddnsto_docker_error 'retained/incomplete state: recreation blocked until identity persistence is verified'; exit 2; }
    [ "$ACTION" = install ] || { ddnsto_docker_error 'no managed container'; exit 2; }
    # Only this proven-fresh branch may collect interactive inputs.
    ddnsto_docker_fresh_inputs || exit $?
    ddnsto_docker_cli pull --platform linux/amd64 "$ddocker_image" >/dev/null 2>&1 || { ddnsto_docker_error 'pinned image pull failed'; exit 11; }
    ddocker_image_id=$(ddnsto_docker_cli image inspect --format '{{.Id}}' "$ddocker_image" 2>/dev/null) || exit 11
    case "$ddocker_image_id" in sha256:*) ;; *) exit 11 ;; esac
    [ "${#ddocker_image_id}" = 71 ] || exit 11
    case "${ddocker_image_id#sha256:}" in *[!a-f0-9]*) exit 11 ;; esac
    # Atomic exclusive directory creation. A partial transaction is deliberately
    # retained and refused on rerun; never guess whether engine creation succeeded.
    mkdir -m 700 "$ddocker_dir" || exit 2
    mkdir -m 700 "$ddocker_dir/identity" || exit 2
    printf 'TOKEN=%s\nDEVICE_NAME=%s\n' "$ddocker_token" "$ddocker_name" > "$ddocker_dir/container.env" || exit 2
    printf '%s\n' "$ddocker_endpoint" > "$ddocker_dir/endpoint" || exit 2
    printf '%s\n' "$ddocker_network" > "$ddocker_dir/network" || exit 2
    printf '%s\n' "$ddocker_image_id" > "$ddocker_dir/image-id" || exit 2
    ddocker_id=$(ddnsto_docker_cli create --name ddnsto-managed --platform linux/amd64 \
        --network "$ddocker_network" --restart unless-stopped \
        --label io.ddnsto.installer=docker-candidate-v1 --label "io.ddnsto.state=$ddocker_dir" \
        --env-file "$ddocker_dir/container.env" \
        --mount "type=bind,src=$ddocker_dir/identity,dst=/ddnsto-config" "$ddocker_image" 2>/dev/null) || {
        ddnsto_docker_error 'container creation failed; private state retained'; exit 13;
    }
    case "$ddocker_id" in ''|*[!a-f0-9]*) exit 13 ;; esac
    [ "${#ddocker_id}" = 64 ] || exit 13
    printf '%s\n' "$ddocker_id" > "$ddocker_dir/container-id" || exit 13
    ddnsto_docker_owned || exit 2
    ddnsto_docker_cli start "$ddocker_id" >/dev/null 2>&1 || { ddnsto_docker_error 'start failed; container/state retained for explicit repair'; exit 13; }
    ddnsto_docker_report install || exit $?
    [ "$ddocker_running" = true ] || exit 13
)
