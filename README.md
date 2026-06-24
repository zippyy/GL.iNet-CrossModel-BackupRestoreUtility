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

## Safety

- Backups can contain Wi-Fi passwords, VPN keys, DDNS tokens, and AdGuard credentials.
- Router credentials are used for the request and are not written to saved profiles.
- Network device names, switch-port/VLAN layout, users, firmware settings, and other hardware-specific values are not auto-restored across models.
- Validate first and review every warning before restoring configuration to a production router.
