# GL.iNet Cross-Model Backup / Restore Utility — Native OpenWrt branch

This `OpenWRT` branch packages the utility as a native LuCI application that can be compiled into an IPK for GL.iNet/OpenWrt routers. It does **not** require Docker, Node.js, or a separately hosted web service.

Install the generated IPK on the source router to create a portable profile archive, then install the same IPK on the target router to upload and restore compatible settings locally.

## Build the IPK

Use an OpenWrt SDK that matches the target router's firmware release, target/subtarget, ABI, and package architecture.

```sh
git clone --branch OpenWRT https://github.com/zippyy/GL.iNet-CrossModel-BackupRestoreUtility.git
cd GL.iNet-CrossModel-BackupRestoreUtility

cp -a openwrt/luci-app-glinet-crossmodel-backup /path/to/openwrt-sdk/package/
cd /path/to/openwrt-sdk
./scripts/feeds update -a
./scripts/feeds install -a
make defconfig
make package/luci-app-glinet-crossmodel-backup/compile V=s
```

The generated IPK appears under `bin/packages/<architecture>/...` inside the SDK.

## Install on a GL.iNet router

```sh
opkg install /tmp/luci-app-glinet-crossmodel-backup_*.ipk
/etc/init.d/uhttpd restart
```

Open LuCI and go to **Services → GL.iNet Cross-Model Backup**.

## Native portable profile contents

The app creates a `.tar.gz` archive with selected UCI exports and source metadata. It can also include:

- An installed-package manifest. The target runs `opkg update` and installs only missing, compatible non-core/non-kmod packages when explicitly enabled.
- Explicit custom scripts and regular files. Each file is capped at 8 MB; all custom files together are capped at 32 MB. They stage under `/root/glinet-crossmodel-restore/` by default.
- Explicit custom ELF binaries. Restore is blocked if the source and target `uname -m` architectures do not match.

## Intentionally not cloned

Firmware, kernel modules, physical ports, DSA/switch/VLAN topology, hardware-specific interface names, device identity, users, passwords, SSH host keys, and raw flash configuration are not copied automatically.
