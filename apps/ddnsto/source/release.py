"""DDNSTO historical installer URLs; product releases belong to the server publisher."""
import shutil


def copy_compat_installers(installer, destination):
    """Historical DDNSTO URLs publish the same standalone entry bytes."""
    for relative in ("openwrt/install_ddnsto.sh", "openwrt/install_ddnsto_business.sh", "openwrt/setup_ddnsto.sh", "linux-binary/install_ddnsto_linux.sh"):
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(installer, target)
