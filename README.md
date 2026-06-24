# GL.iNet Cross-Model Backup / Restore Utility — Native OpenWrt branch

This `OpenWRT` branch packages the utility as a native LuCI application that can be compiled into an IPK for GL.iNet/OpenWrt routers. It does **not** require Docker, Node.js, or a separately hosted web service.

Install the generated IPK on one control router, such as a Flint 3 or Flint 4. From its LuCI page, you can create profiles from that router itself or from reachable GL.iNet/OpenWrt routers on the LAN over SSH. The same control router can also push a profile to a selected LAN router and execute the native restore there. Remote routers do **not** need this IPK installed.

## Build the IPK

Use an OpenWrt SDK that matches the control router's firmware release, target/subtarget, ABI, and package architecture.

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

## Install on the control router

```sh
opkg install /tmp/luci-app-glinet-crossmodel-backup_*.ipk
/etc/init.d/uhttpd restart
```

Open LuCI and go to **Services → GL.iNet Cross-Model Backup**.

The IPK depends on `openssh-client` and `sshpass` so it can manage LAN routers by password-authenticated SSH. Credentials are submitted only for the active request, placed in a temporary mode-0600 file, and deleted after the SSH task. New host keys are accepted once and saved in the control router's `/root/.ssh/known_hosts`; a later key mismatch is rejected rather than silently trusted.

## Remote LAN workflow

1. Install the IPK on the control router only.
2. On **Backup source**, enable **Connect to another LAN router over SSH**, enter its LAN address, SSH port, username, and password, then test the connection.
3. Create the portable profile. It is copied back and saved on the control router.
4. On **Restore target**, enable **Restore to another LAN router over SSH**, enter that router's SSH details, upload a profile, choose categories, and restore.

During each remote operation, the control router streams the native backend script to the remote router over SSH. It creates or applies the profile locally on that remote router, then removes the temporary remote archive and helper inputs when the job finishes.

## Native portable profile contents

The app creates a `.tar.gz` archive with selected UCI exports and source metadata. It can also include:

- An installed-package manifest. The target runs `opkg update` and installs only missing, compatible non-core/non-kmod packages when explicitly enabled.
- Explicit custom scripts and regular files. Each file is capped at 8 MB; all custom files together are capped at 32 MB. They stage under `/root/glinet-crossmodel-restore/` by default.
- Explicit custom ELF binaries. Restore is blocked if the source and target `uname -m` architectures do not match.

## Intentionally not cloned

Firmware, kernel modules, physical ports, DSA/switch/VLAN topology, hardware-specific interface names, device identity, users, passwords, SSH host keys, and raw flash configuration are not copied automatically.
