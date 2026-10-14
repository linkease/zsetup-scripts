# Maintained product metadata; embedded in install.sh, never fetched at runtime.
# All 21 existing HTTPS artifacts re-downloaded and verified 2026-10-14.
# See docs/github-testing.md. Bump installer version when updating any pin.
ddnsto_pinned_version() {
    case "$1" in
        standard) printf '%s\n' 4.2.6 ;;
        lite) printf '%s\n' 4.2.2 ;;
        *) printf '%s\n' 'DDNSTO: unknown pinned variant' >&2; return 11 ;;
    esac
}

ddnsto_pinned_sha() {
    case "$1" in
        linux-binary/ddnsto-standard-4.2.3.tar.gz) printf '%s\n' b982ebd38e8c145d955049eb5b73960c01941bc05f084c3a2115dfca2b6eea6e ;;
        openwrt/lite-apk/4.2.2/ddnsto_aarch64.apk) printf '%s\n' fa8715e298357b1f194fd303b7bc53fe97fc2d62847099c8942fb1d833c44bba ;;
        openwrt/lite-apk/4.2.2/ddnsto_arm.apk) printf '%s\n' a0d748be8936b8515a4a83e624529ee9873728c434b44e330e03159e2f7fd4b4 ;;
        openwrt/lite-apk/4.2.2/ddnsto_mipsel.apk) printf '%s\n' 34cf69a86b7c22993e974d54b973ad65eda9a81b59b79a77eff68140bf3f421d ;;
        openwrt/lite-apk/4.2.2/ddnsto_x86_64.apk) printf '%s\n' 291a24cb1e8e821f127ad08249bcfbc1517501189b895fbad261c950e2aa0abf ;;
        openwrt/lite/4.2.2/ddnsto_aarch64.ipk) printf '%s\n' 4f1542dc9e8f14a2da69800190e2d2b5f20288c96c2067eb1ada62e9d9999d0c ;;
        openwrt/lite/4.2.2/ddnsto_arm.ipk) printf '%s\n' 3ccdc5100c4e43e7a75a6fd1cbfd5718e8ba7fce40ac4626da83487db2f3ea96 ;;
        openwrt/lite/4.2.2/ddnsto_mipsel.ipk) printf '%s\n' 22df2e1f8c9238e861954778d9b48f149660ee7b0fd8639b1e73731454209fbe ;;
        openwrt/lite/4.2.2/ddnsto_x86_64.ipk) printf '%s\n' 1434d56a8122d4fdb470a744a512373741307631fabde0a31e37733984461ca4 ;;
        openwrt/standard-apk/4.2.6/ddnsto_aarch64.apk) printf '%s\n' 55e0d89060bbd8d6df3ca473ca114f257dd1312587ea703963ce812877e7a509 ;;
        openwrt/standard-apk/4.2.6/ddnsto_arm.apk) printf '%s\n' a90951eb323a19f79964b597af9cdefbb728e675b8077c0fd115fa061011f62a ;;
        openwrt/standard-apk/4.2.6/ddnsto_mipsel.apk) printf '%s\n' ebd0f3eeed46ec8f45a585b0e49403725fbd18a48de42d9ed0380609ed0d76ed ;;
        openwrt/standard-apk/4.2.6/ddnsto_x86_64.apk) printf '%s\n' 470e4ea428f897cc8e38f7528b9387b0dd7373d5c727ef334e1d79c8dead7da2 ;;
        openwrt/standard/4.2.6/ddnsto_aarch64.ipk) printf '%s\n' 413aef536307542e08fde749af9c9b5db239280fb2cdee5f48ced5cb61ef545a ;;
        openwrt/standard/4.2.6/ddnsto_arm.ipk) printf '%s\n' 167ff8ba20965f72471bf8be9a1010eb776ca54b336033d807bb83c19e1f3917 ;;
        openwrt/standard/4.2.6/ddnsto_mipsel.ipk) printf '%s\n' 9a0c740708cb1ede7e680112bcec5c9dad9f00739ef8587b334f305898d2763c ;;
        openwrt/standard/4.2.6/ddnsto_x86_64.ipk) printf '%s\n' a7d868da03dea6e6e9b4cb02bc6f2ccfa31d2eeba62f0ac088338bc83e31e9eb ;;
        openwrt/luci-app-ddnsto.apk) printf '%s\n' 74c1905d95ec90077cd3f4b4d907782c093ad977f0c7c4c93137190106e1e566 ;;
        openwrt/luci-i18n-ddnsto-zh-cn.apk) printf '%s\n' 96fcf176a2d2be9d3ad85d0687d5f0adaa37282be4cb0c95cee609c6dde60fb4 ;;
        openwrt/luci-app-ddnsto.ipk) printf '%s\n' f3c87b000e7ec6ed640783232354b7462a274323d5edd5d2cc857c03192bda13 ;;
        openwrt/luci-i18n-ddnsto-zh-cn.ipk) printf '%s\n' 6c5f3e287b70704181769f23b1775c064bf1d4bf2c6ee1fb0a226377478c1a04 ;;
        *) printf '%s\n' "DDNSTO: no pinned artifact for $1; use a reviewed newer installer" >&2; return 11 ;;
    esac
}
