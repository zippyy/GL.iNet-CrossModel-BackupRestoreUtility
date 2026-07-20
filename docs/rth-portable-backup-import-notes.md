# RemoteToHome gl-portable-backup review notes

Reference project: `RemoteToHome-io/gl-portable-backup`.

This branch ports concepts that are worth carrying forward without copying the upstream shell backend verbatim.

## Pulled into this branch

- Backup mode vocabulary:
  - `profile` for cross-model migration.
  - `remote-safe` for same-model restores where the management tunnel must survive.
  - `clone` for same-model sanitized cloning.
- Mode-aware validation:
  - `clone` and `remote-safe` require the same source/target board ID.
  - firmware mismatches warn before restore.
  - `network`, `wireless`, and `firewall` reloads are deferred after restore so remote SSH/Tailscale/ZeroTier sessions are not cut off before the API returns.
- Remote-safe exclusions:
  - preserve `zerotier`, `tailscale`, `gl-cloud`, `rtty`, `dropbear`, and `wan-access` configs.
- Sanitization for same-model clone-style backups:
  - strip MAC addresses and obvious key/credential fields from exported UCI config.
- Package review metadata:
  - capture user-installed packages in the backup profile.
  - expose `/api/backups/:backupId/packages` to compare source packages with target packages.
  - separate missing kernel modules from ordinary missing user packages.

## Not pulled yet

- Full raw same-device backup mode.
- OpenWrt `keep.d` file discovery and extra persistent file capture.
- GL.iNet JSON-RPC profile capture/restore for Wi-Fi/LAN/DNS/firewall.
- Native LuCI JavaScript view rewrite with `menu.d` and `rpcd/acl.d`.

## Licensing note

The upstream project is GPL-3.0-or-later. This branch reimplements the ideas independently in the existing Node backend. Do not paste upstream source code into this repository unless the repository licensing is made GPL-compatible and attribution is added.
