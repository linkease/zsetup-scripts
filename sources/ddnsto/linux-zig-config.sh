# Systemd Zig protocol renderers. These only emit data; callers validate
# ownership and commit via bounded capture. Automatic product selection remains
# disabled until fresh installation and privilege preparation are integrated.
ddnsto_zig_config_render() (
    config=$1; state=$2
    case "$state" in
        /*) ;;
        *) return 2 ;;
    esac
    case "$state" in /|*/../*|*/..|*/./*|*/.|*'
'*|*"$(printf '\r')"*) return 2 ;; esac
    [ -f "$config" ] && [ ! -L "$config" ] || return 2
    size=$(wc -c < "$config") || return 2
    [ "$size" -le 16384 ] || return 2
    command -v jq >/dev/null 2>&1 || return 2
    # JSON quoted scalars are YAML scalars too. Do not interpolate input into
    # jq source or shell code. Reject unknown settings instead of losing them.
    jq -ers --arg state "$state" '
      def reject: error("unsupported service configuration");
      if length != 1 then reject else .[0] end |
      if type != "object" then reject else . end |
      if (keys - ["token", "routeridx", "supplierCode"] | length) != 0 then reject else . end |
      if (.token | type != "string" or length == 0) then reject else . end |
      (if has("routeridx") then .routeridx else 0 end) as $raw |
      (if ($raw | type) == "string" then
         if ($raw | test("^[0-9]+$")) then ($raw | tonumber) else reject end
       else $raw end) as $idx |
      if ($idx | type) != "number" then reject
      elif $idx < 0 or $idx > 2147483647 or ($idx | floor) != $idx then reject else . end |
      (if has("supplierCode") then .supplierCode else "" end) as $supplier |
      if ($supplier | type) != "string" then reject else . end |
      "userToken: " + (.token | tojson),
      "routerIdx: " + ($idx | tostring),
      "supplierCode: " + ($supplier | tojson),
      "bootConfigPath: " + ($state + "/.ddnsto_boot.cfg" | tojson),
      "logPath: " + ($state + "/logs" | tojson),
      "httpAddr: \"127.0.0.1:0\"",
      "webdav:", "  enabled: false"
    ' "$config" 2>/dev/null
)

ddnsto_zig_service_wrapper() (
    # Use the common POSIX quote encoder; no token is embedded in the wrapper
    # or process argv. Configuration must be a separately protected file.
    for path in "$1" "$2"; do
        case "$path" in /*) ;; *) return 2 ;; esac
        case "$path" in *'
'*|*"$(printf '\r')"*) return 2 ;; esac
    done
    printf '#!/bin/sh\nexec '
    for path in "$1" --config "$2" run; do
        installer_service_replace "$path" "'" "'\\''"
        printf "'%s' " "$service_replaced"
    done
    printf '\n'
)
