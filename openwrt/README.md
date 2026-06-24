# Native GL.iNet / OpenWrt IPK package

This directory is a package feed-style source tree for a native LuCI application:

- Package name: `luci-app-glinet-crossmodel-backup`
- Runtime: native BusyBox, UCI, opkg, tar, and LuCI — no Docker, Node.js, or external SSH service
- Workflow: install the IPK on the source router to create a portable archive, then install it on the target router to upload, validate, and restore it locally.

## Build with an OpenWrt SDK

Use an SDK matching the target router's **OpenWrt release, target/subtarget, ABI, and package architecture**. A GL.iNet firmware package must be built against the same GL.iNet SDK/feed set when GL.iNet-specific ABI packages are involved.

```sh
git clone --branch OpenWRT https://github.com/zippyy/GL.iNet-CrossModel-BackupRestoreUtility.git
cd GL.iNet-CrossModel-BackupRestoreUtility

# Copy the package into an extracted, matching OpenWrt SDK.
cp -a openwrt/luci-app-glinet-crossmodel-backup \
  /path/to/openwrt-sdk/package/

cd /path/to/openwrt-sdk
./scripts/feeds update -a
./scripts/feeds install -a
make defconfig
make package/luci-app-glinet-crossmodel-backup/compile V=s
```

The IPK is written below the SDK's `bin/packages/<arch>/...` path.

## Install

Copy the correctly built IPK to the router, then run:

```sh
opkg install /tmp/luci-app-glinet-crossmodel-backup_*.ipk
/etc/init.d/uhttpd restart
```

Open the router's LuCI interface and select **Services → GL.iNet Cross-Model Backup**.

## Native profile format

The native app creates a `.tar.gz` portable profile. It contains UCI export files, a package manifest, optional archives for explicitly selected scripts/files and ELF binaries, and metadata describing source architecture and model.

- Package restore uses the target router's configured `opkg` feeds and skips core/kmod packages.
- Custom files stage under `/root/glinet-crossmodel-restore/<profile-id>/` by default.
- ELF binary restore is blocked when source and target architecture differ.
- Network port/DSA/VLAN layout, firmware, users, passwords, host keys, and other hardware-specific data are not copied automatically.
