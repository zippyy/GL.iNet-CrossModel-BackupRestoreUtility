# GL.iNet Cross-Model Backup / Restore Utility

A self-hosted utility for moving portable GL.iNet configuration between router models over SSH and UCI.

It creates a portable JSON profile rather than a raw firmware backup. Profiles can include network, wireless, VPN, firewall, AdGuard Home, DDNS, and limited system UCI data plus optional package manifests, custom scripts/files, and custom ELF binaries.

## Deploy

```bash
git clone --branch dev https://github.com/zippyy/GL.iNet-CrossModel-BackupRestoreUtility.git
cd GL.iNet-CrossModel-BackupRestoreUtility
docker compose up -d --build
```

Open `http://127.0.0.1:8787` locally, or put the service behind an authenticated reverse proxy.

## Optional portable artifacts

### Installed packages

Selecting **Installed package manifest** records package names and source versions from `opkg list-installed`; it does not copy `.ipk` archives. During restore, the tool only installs missing non-core packages when you explicitly enable package installation. It runs `opkg update`, then resolves compatible versions from the target router's configured feeds. Kernel, `kmod-*`, and core platform packages are skipped.

### Custom scripts and files

List one absolute regular-file path per line, such as `/root/fix-vpn.sh`, `/etc/rc.local`, or `/usr/local/bin/router-health`. Each file is capped at 8 MB and all selected scripts/binaries together are capped at 32 MB. On restore they are staged under `/root/glinet-portable-restore/<profile-id>/` by default. Enable direct restore only after reviewing the target paths.

### ELF binaries

List explicit ELF binary paths separately. Direct binary restore is allowed only where the source and target `uname -m` architecture match. This prevents accidental MIPS, ARM, or x86 binary deployment onto incompatible router hardware.

## Safety

- Backups can contain Wi-Fi passwords, VPN keys, DDNS tokens, AdGuard credentials, package names, and the contents of every custom file selected.
- Router credentials are used for the request and are not written to saved profiles.
- Network device names, switch-port/VLAN layout, users, firmware settings, and other hardware-specific values are not automatically restored across models.
- Validate first and review every warning before restoring configuration to a production router.
