# Standard-entry preflight: runs before native bootstrap, not inside its payload.
# Reuse the business filesystem checks; never remount DSM /tmp or chmod strangers.
ddnsto_entry_private_storage() {
    ddnsto_bootstrap_safe_ancestors "${1%/*}" &&
        ddnsto_bootstrap_private_dir "$1" || {
        printf '%s\n' 'DDNSTO: unsafe installer cache; check ownership/permissions or run as a DSM administrator; code=12' >&2
        return 12
    }
    WORK_ROOT=$1
    ZSETUP_ROOT=$WORK_ROOT
    ZSETUP_MANAGED_ROOT=$WORK_ROOT/managed
    ZSETUP_CACHE_DIR=$WORK_ROOT/installers
    export ZSETUP_ROOT ZSETUP_MANAGED_ROOT ZSETUP_CACHE_DIR
}

ddnsto_entry_storage() {
    DDNSTO_ENTRY_APPLIANCE=
    DDNSTO_ENTRY_LEGACY=0
    if [ -f /etc.defaults/VERSION ] && [ -x /usr/syno/bin/synopkg ]; then
        DDNSTO_ENTRY_APPLIANCE=synology
        if [ -n "${ZSETUP_ROOT:-}" ]; then
            ddnsto_entry_private_storage "$ZSETUP_ROOT"
        elif [ "$(id -u)" = 0 ]; then
            ddnsto_entry_private_storage /var/lib/ddnsto-installer
        else
            # DSM's home entry can be a symlink into the actual data volume.
            # Resolve it first, then validate every real ancestor.
            entry_home=$(CDPATH= cd -P -- "${HOME:?}" && pwd -P) || return 12
            ddnsto_entry_private_storage "$entry_home/.ddnsto-installer"
        fi
    elif [ -x /bin/nvram ] && [ -x /usr/bin/dbus ] && [ -d /koolshare ]; then
        DDNSTO_ENTRY_APPLIANCE=asus
        ddnsto_asus_storage || {
            printf '%s\n' 'DDNSTO: unsafe ASUS installer storage; check /jffs; code=12' >&2
            return 12
        }
        WORK_ROOT=$ASUS_STATE/entry-bootstrap
        ddnsto_asus_private_dir "$WORK_ROOT" || return 12
        ZSETUP_ROOT=$WORK_ROOT
        export ZSETUP_ROOT
        case "$(uname -r)" in 2.6.*) DDNSTO_ENTRY_LEGACY=1 ;; esac
    fi
}

ddnsto_entry_storage
