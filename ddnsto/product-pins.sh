# Maintained product metadata; embedded in install.sh, never fetched at runtime.
# HTTPS bytes verified 2026-11-03; see docs/ddnsto-artifacts-2026-11-03.json.
# lite retains the package naming used by the Micro client release.
ddnsto_pinned_version() {
    case "$1" in
        standard|lite) printf '%s\n' 4.2.8 ;;
        *) printf '%s\n' 'DDNSTO: unknown pinned variant' >&2; return 11 ;;
    esac
}

ddnsto_pinned_sha() {
    case "$1" in
        linux-binary/ddnsto-standard-4.2.8.tar.gz) printf '%s\n' 3bf7ada14448b5aa04afa171e497f85d0b8bb4adcf2209991e52ef5826d4e975 ;;
        openwrt/lite-apk/4.2.8/ddnsto_aarch64.apk) printf '%s\n' aaf16937cad6373849ad1d1f15d64b9a085a55d4f44778c2458997fb2af0b65d ;;
        openwrt/lite-apk/4.2.8/ddnsto_arm.apk) printf '%s\n' 2834dfe9fe683d6dfffed8b73a71a7d84867789fbd8537fe3e21f8ea7e4e8c6b ;;
        openwrt/lite-apk/4.2.8/ddnsto_mipsel.apk) printf '%s\n' 91cfe44983494d3efea407fe5bd4ee5c76e227e821cd5729684ef92f46d3043e ;;
        openwrt/lite-apk/4.2.8/ddnsto_x86_64.apk) printf '%s\n' b725dab7fd7387527c03015f37cfa1e5424e13d550cc0d2fba3a7067627cef96 ;;
        openwrt/lite/4.2.8/ddnsto_aarch64.ipk) printf '%s\n' f400d53e82b4ad83da42e05b8561e3a92afbaca21f228fb994d2a5ed659474a7 ;;
        openwrt/lite/4.2.8/ddnsto_arm.ipk) printf '%s\n' c9ab02d44f753eb1129570687ec1fd31246f654444fc77dc219a7dd91fb7417e ;;
        openwrt/lite/4.2.8/ddnsto_mipsel.ipk) printf '%s\n' 3e331d2f59f891f33b2f3c00a8cecd429a266c5a52810966f78051aef267c1fb ;;
        openwrt/lite/4.2.8/ddnsto_x86_64.ipk) printf '%s\n' ed4bd946f54840a61312e4121cc6887e874baea00506711c2ce3e69f4f8411ac ;;
        openwrt/luci-app-ddnsto.apk) printf '%s\n' edd733e46d476b688da2dc046f6d87eee5365c72b1be34c82c6b9f5ef4b87a18 ;;
        openwrt/luci-app-ddnsto.ipk) printf '%s\n' 702828cdfc1cf2e33dc1b2894ec69a49f1739dfd3ece8948da0d093c6348d123 ;;
        openwrt/luci-i18n-ddnsto-zh-cn.apk) printf '%s\n' dbb3b6d2176f1c223e82ca46e6be4fda50ff30f449c9302be3382eb6162d8e2d ;;
        openwrt/luci-i18n-ddnsto-zh-cn.ipk) printf '%s\n' fff0850c893a75eb597d9e60cada9350caf5bc22219628a8c212f79f82e90679 ;;
        openwrt/standard-apk/4.2.8/ddnsto_aarch64.apk) printf '%s\n' 67e3e784a38a05aa8d3c8693caa8fd20d8316ca950268b956f688df6a1f11d8f ;;
        openwrt/standard-apk/4.2.8/ddnsto_arm.apk) printf '%s\n' 4d5c656af9560ba2a039f7305968ad086788204dcc678e8bc6bbbe345a481bf9 ;;
        openwrt/standard-apk/4.2.8/ddnsto_mipsel.apk) printf '%s\n' 8ef767b45b7546e2b4e979ac0fc426d663e34988c816e465a6c0b8b54a62d9b8 ;;
        openwrt/standard-apk/4.2.8/ddnsto_x86_64.apk) printf '%s\n' 6740fea1fbc6f58de41d5024af0d4c6d523599947c50b70889c15646f0a482c0 ;;
        openwrt/standard/4.2.8/ddnsto_aarch64.ipk) printf '%s\n' 5f291b4c28daefe4298f33d8dae9860945091bdb4af357d58b1c4553e41828cf ;;
        openwrt/standard/4.2.8/ddnsto_arm.ipk) printf '%s\n' acc8df1f81049cde0695357347aeeeecec1f99046e5e91fed1cfdde5cbedc3c6 ;;
        openwrt/standard/4.2.8/ddnsto_mipsel.ipk) printf '%s\n' 0afd87b8a17db1616b73e64625badd7eae714cf1bcdb963cc46038b8288a0553 ;;
        openwrt/standard/4.2.8/ddnsto_x86_64.ipk) printf '%s\n' d2965019064df274cea7a04433aabeb767a4b49502f724d61aa26adf641eda63 ;;
        *) printf '%s\n' "DDNSTO: no pinned artifact for $1; use a reviewed newer installer" >&2; return 11 ;;
    esac
}
