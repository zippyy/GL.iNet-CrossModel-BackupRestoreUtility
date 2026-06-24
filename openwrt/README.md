# Native GL.iNet / OpenWrt IPK package

This directory is a package feed-style source tree for a native LuCI application:

- Package name: `luci-app-glinet-crossmodel-backup`
- Runtime: native BusyBox, UCI, opkg, tar, LuCI, OpenSSH client, and sshpass — no Docker, Node.js, or separately hosted service
- Control-router workflow: install the IPK once on a main router, then manage that router itself or other reachable GL.iNet/OpenWrt LAN routers over SSH
- Remote routers do not need the IPK. The control router streams the small native backend script for an active job, retrieves profiles, and removes its temporary remote files when finished.

## Build with an OpenWrt SDK

Use an SDK matching the **control router's** OpenWrt release, target/subtarget, ABI, and package architecture. A GL.iNet firmware package should be built against the same GL.iNet SDK/feed set when GL.iNet-specific ABI packages are involved.

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

## Install on the control router

```sh
opkg install /tmp/luci-app-glinet-crossmodel-backup_*.ipk
/etc/init.d/uhttpd restart
```

Open the router's LuCI interface and select **Services → GL.iNet Cross-Model Backup**.

## LAN SSH workflow

Enable the SSH source or target toggle in LuCI, enter a LAN address, SSH port, username, and password, and run the connection test. The control router uses `sshpass` with a temporary mode-0600 password file; it does not save submitted credentials. New SSH host keys are stored in `/root/.ssh/known_hosts`; changed keys fail validation instead of being silently trusted.

## Native profile format

The native app creates a `.tar.gz` portable profile. It contains UCI export files, a package manifest, optional archives for explicitly selected scripts/files and ELF binaries, and metadata describing source architecture and model.

- Package restore uses the target router's configured `opkg` feeds and skips core/kmod packages.
- Custom files stage under `/root/glinet-crossmodel-restore/<profile-id>/` by default.
- ELF binary restore is blocked when source and target architecture differ.
- Network port/DSA/VLAN layout, firmware, users, passwords, host keys, and other hardware-specific data are not copied automatically.
