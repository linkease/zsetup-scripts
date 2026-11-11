# Pure channel selection. Inputs are firmware facts, never executable settings.
# Caller must first establish ASUS firmware + an existing software center.
# Keep CPU selection separate: each modern archive contains two binaries.
ddnsto_asus_channel() (
    model=$1 kernel=$2 architecture=$3 source=$4
    model_channel= source_channel=
    case "$kernel" in ''|*[!a-zA-Z0-9._+-]*) return 2 ;; esac
    release=${kernel%%-*}; release=${release%%+*}
    case "$release" in ''|*[!0-9.]*|.*|*.|*..*) return 2 ;; esac
    # Validate every numeric component, without arithmetic on untrusted input.
    IFS=.; set -- $release; unset IFS
    [ "$#" -ge 3 ] || return 2
    for component do
        case "$component" in 0|[1-9]*) ;; *) return 2 ;; esac
    done
    case "$architecture" in armv7l|aarch64) ;; *) return 2 ;; esac
    case "$model" in
        TX-AX6000|TUF-AX4200Q|RT-AX57_Go|GS7|ZenWiFi_BT8P|GS7_Air|GS-BE7200X)
            model_channel=mtksoft ;;
        ZenWiFi_BD4) model_channel=ipq32soft ;;
        TUF_6500) model_channel=ipq64soft ;;
        RT-AX89X) model_channel=qcasoft ;;
    esac
    # Only use a source as a classification hint. It is never a download URL.
    # Do not guess HND from ARM64 or an unfamiliar model alone.
    case "${source%/}" in
        '') ;;
        https://rogsoft.ddnsto.com) source_channel=rogsoft ;;
        https://armsoft.ddnsto.com) source_channel=armsoft ;;
        https://mtksoft.ddnsto.com) source_channel=mtksoft ;;
        https://ipq32soft.ddnsto.com) source_channel=ipq32soft ;;
        https://ipq64soft.ddnsto.com) source_channel=ipq64soft ;;
        https://qcasoft.ddnsto.com) source_channel=qcasoft ;;
        *) return 2 ;;
    esac
    if [ -n "$model_channel" ] && [ -n "$source_channel" ]; then
        [ "$model_channel" = "$source_channel" ] || return 2
    fi
    channel=${model_channel:-$source_channel}
    case "$kernel" in
        2.6.*)
            [ "$architecture" = armv7l ] || return 2
            [ -z "$channel" ] || [ "$channel" = armsoft ] || return 2
            channel=armsoft ;;
        4.[1-9]*|5.*|6.*)
            [ -n "$channel" ] && [ "$channel" != armsoft ] || return 2 ;;
        *) return 2 ;;
    esac
    printf '%s\n' "$channel"
)

# Reviewed CDN bytes on 2026-11-10. These URLs are mutable, so a changed
# package must fail verification until a new installer reviews its pin.
# Output: URL, plugin version, .valid marker, byte size, SHA-256.
ddnsto_asus_package() (
    case "$1" in
        rogsoft) marker=hnd size=8104981 sha=671c1c77d7b867f5019af35e8702be665695e30c107138ae150d045e11df1960 ;;
        armsoft) marker=arm384 size=3430887 sha=8e0ff71269b8ba8674427896310d99309d97eae92b007d97cb968eb1d880664d ;;
        mtksoft) marker=mtk size=8105004 sha=8d08921e49bed7bcafed48dc6c6b6795467f77767a97cc8af23f0b463285248a ;;
        ipq32soft) marker=ipq32 size=8105008 sha=56c0298ec811e51cf93390bbfa2f9489752188320aaf96c43d2b19289ba7580d ;;
        ipq64soft) marker=ipq64 size=8105008 sha=4cb863a85d5c5dcd00ff8a3f5a09fa90465b59b48e48cdce12163be62b1f10ce ;;
        qcasoft) marker=qca size=8105006 sha=fa021afaf9424f032ff9e084e76c80fadd7fe74e844060e0d84ac6053db19216 ;;
        *) return 2 ;;
    esac
    printf '%s\n' "https://asusgo.koolcenter.com/$1/ddnsto/ddnsto.tar.gz" 4.2.8 "$marker" "$size" "$sha"
)
