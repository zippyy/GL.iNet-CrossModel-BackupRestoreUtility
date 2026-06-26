# GL.iNet Cross-Model Backup / Restore Utility

A self-hosted tool for moving portable GL.iNet configuration between router models over SSH and UCI.

It creates a portable JSON profile rather than a raw firmware backup. The tool validates a target before changing it and limits migration to settings that can sensibly transfer between different hardware: network settings, Wi-Fi SSIDs, VPN profiles, named firewall rules, AdGuard Home settings, DDNS, and limited system preferences.

## Deploy

```bash
git clone https://github.com/zippyy/GL.iNet-CrossModel-BackupRestoreUtility.git
cd GL.iNet-CrossModel-BackupRestoreUtility
docker compose up -d --build
```

Open `http://127.0.0.1:8787` locally, or put the service behind an authenticated reverse proxy.

## GL.iNet Admin Panel v4 companion IPK

`openwrt/glui-integration` contains the companion package for routers that already have `luci-app-glinet-crossmodel-backup` installed. It does not replace the backup/restore application.

It changes the LuCI application route from `Services` to `System`, injects a same-origin GL.iNet Admin Panel v4 hook through `/www/gl_home.html`, and adds a **Cross-Model Backup** shortcut to the expanded System menu plus the header.

Build the package from the repository root:

```bash
sh openwrt/glui-integration/build-ipk.sh
```

The output is `dist/luci-app-glinet-crossmodel-backup-glui_1.1.0-21_all.ipk`. It uses the legacy gzip/tar IPK layout accepted by GL.iNet's OpenWrt 21.02 `opkg`; do not repack it as a Debian `ar` archive.

The companion runs an idempotent install hook and boot-time repair hook. This restores the GL UI injection after a firmware update that replaces `/www/gl_home.html`. Removing the companion removes only its GL UI hook; it intentionally leaves the main LuCI app under **System**.

## Safety

- Backups can contain Wi-Fi passwords, VPN keys, DDNS tokens, and AdGuard credentials.
- Router credentials are used for the request and are not written to saved profiles.
- Network device names, switch-port/VLAN layout, users, firmware settings, and other hardware-specific values are not auto-restored across models.
- Validate first and review every warning before restoring configuration to a production router.
