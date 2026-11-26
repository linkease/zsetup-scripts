# Product selection precedes both user preparation and root service staging.
# No cross-implementation identity migration is implied by available space.
ddnsto_linux_current_variant() (
    [ -L "$INSTALLER_PREFIX/current" ] || { printf 'standard\n'; return; }
    target=$(readlink "$INSTALLER_PREFIX/current") || return 2
    case "$target" in versions/*) ;; *) return 2 ;; esac
    installer_service_version "${target#versions/}" || return 2
    executable="$INSTALLER_PREFIX/$target/bin/ddnsto"
    wrapper="${executable%/*}/.service-run"
    [ -f "$wrapper" ] && [ ! -L "$wrapper" ] || return 2
    installer_file_size "$wrapper" || return 2
    [ "$INSTALLER_FILE_SIZE" -le 4096 ] || return 2
    # Compare against the derived YAML path, not the management JSON.
    config=${SERVICE_CONFIG:-/etc/ddnsto/ddnsto-config.json}
    expected=$(ddnsto_zig_service_wrapper "$executable" "${config%/*}/.ddnsto-zig.yaml") || return 2
    if [ "$(cat "$wrapper")" = "$expected" ]; then printf 'zig\n'; else printf 'standard\n'; fi
)

ddnsto_linux_product_budget() {
    installer_policy ddnsto || return $?
    if [ "$DL_MODE" = bridge ]; then
        installer_space_budget "$INSTALLER_MAX_DOWNLOAD" "$INSTALLER_MAX_EXPANDED" "$INSTALLER_MAX_EXPANDED" "$INSTALLER_MAX_DOWNLOAD"
        [ "$LINUX_VARIANT" != zig ] || INSTALLER_REQUIRED_BYTES=$((INSTALLER_REQUIRED_BYTES - 8388608 + INSTALLER_RESERVE))
    fi
}

ddnsto_privilege_policy() { ddnsto_linux_product_select bridge; }

ddnsto_privilege_download() {
    dl_relative="linux-binary/$archive_name"
    [ "$LINUX_VARIANT" != zig ] || dl_relative=$PROCESS_PRODUCT_PATH
    installer_download "$dl_relative" "$transaction_dir/${dl_relative##*/}" "$digest"
}

# User preparation cannot read the private unit/config. Authenticate the
# readable protected receipt only; root revalidates the entire installation.
ddnsto_linux_prepared_current() {
    SERVICE_CONFIG=/etc/ddnsto/ddnsto-config.json
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX/.managed" get system_protected)" = true ] || return 12
    installer_file_size "$INSTALLER_PREFIX/.managed" || return 2
    [ "$INSTALLER_FILE_SIZE" = 7 ] && [ "$(cat "$INSTALLER_PREFIX/.managed")" = ddnsto ] || return 2
    [ -L "$INSTALLER_PREFIX/current" ] || return 2
    SERVICE_OLD=$(readlink "$INSTALLER_PREFIX/current") || return 2
    ddnsto_managed_receipt "$SERVICE_OLD" || return $?
}

ddnsto_linux_product_select() {
    DL_MODE=$1; LINUX_VARIANT=standard; DL_OLD=
    if [ -e "$INSTALLER_PREFIX/.managed" ] || [ -L "$INSTALLER_PREFIX/.managed" ]; then
        if [ "$DL_MODE" = bridge ]; then ddnsto_linux_prepared_current || return $?
        else ddnsto_managed_owned || return $?; fi
        DL_OLD=$SERVICE_OLD
        LINUX_VARIANT=$(ddnsto_linux_current_variant) || return $?
    fi
    if [ -n "${DDNSTO_VERSION:-}" ] && [ "$DDNSTO_VERSION" != "$(ddnsto_pinned_version standard linux)" ]; then
        [ "$LINUX_VARIANT" = standard ] && [ "${FORCE_VERSION:-}" != lite ] || {
            ddnsto_error 'E_VERSION: explicit historical versions cannot select Zig'; return 2;
        }
        ddnsto_linux_product_budget
        return $?
    fi
    if [ "$LINUX_VARIANT" = zig ] && [ "${FORCE_VERSION:-}" = standard ]; then
        ddnsto_error 'E_PRODUCT: Zig to standard identity migration has not been verified; current installation retained'; return 2
    fi
    ddnsto_linux_product_budget || return $?
    dl_work=${installer_work_dir:-${ZSETUP_WORK_DIR:-$INSTALLER_PREFIX/.staging}}
    [ "$DL_MODE" != bridge ] || dl_work=${installer_work_dir:-${ZSETUP_WORK_DIR:-$HOME/.local/state/linkease/ddnsto/.staging}}
    dl_available=
    for dl_path in "$INSTALLER_PREFIX" "$dl_work"; do
        dl_free=$("$ZSETUP_BIN" storage "$dl_path" get available_bytes) || return 12
        case "$dl_free" in ''|*[!0-9]*) ddnsto_error 'E_STORAGE: cannot determine available bytes'; return 12 ;; esac
        if [ -z "$dl_available" ] || [ "$dl_free" -lt "$dl_available" ]; then dl_available=$dl_free; fi
    done
    if [ "${FORCE_VERSION:-}" = lite ] || [ "$dl_available" -lt "$INSTALLER_REQUIRED_BYTES" ]; then
        if [ "$LINUX_VARIANT" != zig ]; then
            [ -z "$DL_OLD" ] && [ "${FORCE_VERSION:-}" != standard ] || {
                ddnsto_error 'E_SPACE: standard does not fit; existing clients are not automatically migrated or downgraded'; return 12;
            }
            LINUX_VARIANT=zig
            ddnsto_linux_product_budget || return $?
        fi
    fi
    if [ "$LINUX_VARIANT" = zig ]; then
        [ "${BUSINESS_ENV:-production}" = production ] && [ "${SWITCH_ENVIRONMENT:-0}" = 0 ] || {
            ddnsto_error 'E_SPACE: Zig test-environment switching is not verified; client unchanged'; return 12;
        }
        command -v jq >/dev/null 2>&1 || {
            ddnsto_error 'E_DEPENDENCY: low-space Zig system service requires existing jq; no packages were installed'; return 2;
        }
    fi
    [ "$dl_available" -ge "$INSTALLER_REQUIRED_BYTES" ] || {
        ddnsto_error "E_SPACE: $LINUX_VARIANT requires $INSTALLER_REQUIRED_BYTES bytes; available $dl_available"; return 12;
    }
    printf 'DDNSTO: selected %s; service budget %s bytes.\n' "$LINUX_VARIANT" "$INSTALLER_REQUIRED_BYTES" >&2
}
