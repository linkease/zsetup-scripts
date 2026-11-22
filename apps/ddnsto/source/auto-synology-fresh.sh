# DSM's Package Center API carries wizard values; synopkg drops shell env.
ddnsto_synowebapi() { /usr/syno/bin/synowebapi --exec "$@"; }

ddnsto_synology_absent_paths() {
    for path do
        if [ -e "$path" ] || [ -L "$path" ]; then
            ddnsto_flow_error E_OWNERSHIP '发现群晖套件或历史配置残留，未执行新装' '请检查套件中心和原配置，不会自动删除或换绑'; return 2
        fi
    done
}

ddnsto_synology_fresh_check() {
    ddnsto_synology_absent_paths "$syno_pkg" /volume*/@appdata/ddnsto \
        /volume*/@appstore/ddnsto /tmp/.ddnsto/ddnsto-config.json
}

ddnsto_synology_fresh_preflight() {
    [ -x /usr/syno/bin/synowebapi ] || {
        ddnsto_flow_error E_DEPENDENCY 'DSM 缺少套件中心本机安装接口' '请通过套件中心手动安装 SPK'; return 2;
    }
    syno_check=$(ddnsto_synowebapi api=SYNO.Core.Package.Installation method=check version=1 'id="ddnsto"' 2>/dev/null) &&
    syno_volume=$(printf '%s' "$syno_check" | jq -er '
        select(.success == true and .data.is_occupied == false) |
        .data | .volume_path as $v | select(.volume_list | any(.mount_point == $v)) |
        $v | select(type == "string")
    ' 2>/dev/null) || {
        ddnsto_flow_error E_STORAGE 'DSM 无法确认可用的默认套件安装卷，或安装器正忙' '请在套件中心设置默认安装卷，等待其他安装完成后重试'; return 2;
    }
    # DSM jq 1.5 may be compiled without regex support.
    case "$syno_volume" in
        /volume*) volume_number=${syno_volume#/volume} ;;
        *) volume_number=invalid ;;
    esac
    case "$volume_number" in ''|*[!0-9]*)
        ddnsto_flow_error E_STORAGE 'DSM 返回的默认安装卷路径不受支持' '请通过套件中心手动安装'; return 2 ;;
    esac
    ddnsto_bootstrap_safe_ancestors "$syno_volume" || {
        ddnsto_flow_error E_STORAGE '群晖安装卷权限不安全' '请检查默认安装卷权限'; return 2;
    }
    ddnsto_synology_fresh_check
}

ddnsto_synology_fresh_install() (
    ddnsto_synology_fresh_check || exit $?
    # JSON string containing a JSON object: same encoding as DSM Package Center.
    # No shared temporary token file. Native CLI requires argv; suppress its
    # argument-echoing stderr and never copy its raw reply into diagnostics.
    extra=$(printf '%s' "$TOKEN" | jq -Rsc '{wizard_ddnsto_token:.,wizard_ddnsto_idx:"0"}|tojson') || exit 2
    package_path=$(printf '%s' "$1" | jq -Rsc .) || exit 2
    result=$(ddnsto_synowebapi api=SYNO.Core.Package.Installation method=install version=1 \
        "path=$package_path" "volume_path=\"$syno_volume\"" "extra_values=$extra" \
        check_codesign=false force=false installrunpackage=false 2>/dev/null) || {
        ddnsto_flow_error E_PACKAGE 'DSM 本机安装接口执行失败' '请检查套件中心安装记录；不会自动卸载或强制重装'; exit 11;
    }
    unset extra
    # Accept only this SHA-verified third-party SPK, as in Package Center's
    # third-party confirmation. Never change global trust settings or force.
    printf '%s' "$result" | jq -e '.success == true and (.data.has_fail != true)' >/dev/null 2>&1 || {
        code=$(printf '%s' "$result" | jq -r '.error.code | select(type == "number" and floor == .)' 2>/dev/null) || code=
        case "$code" in ''|*[!0-9]*) code=unknown ;; esac
        ddnsto_flow_error E_PACKAGE "DSM 套件安装被拒绝（接口错误码 $code）" '请检查套件中心安装记录；不会自动卸载或强制重装'; exit 11;
    }
)
