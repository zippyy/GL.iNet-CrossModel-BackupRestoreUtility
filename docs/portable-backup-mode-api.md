# Portable backup mode API

This branch keeps the existing JSON profile store, but adds mode metadata and validation behavior inspired by GL Portable Backup.

## Create backup

`POST /api/backups`

New optional body field:

```json
{
  "mode": "profile"
}
```

Allowed values:

- `profile` — existing cross-model behavior. Keeps data mostly intact and relies on validation/restore category filtering.
- `remote-safe` — same-model migration that avoids known remote-access config files and defers disruptive service reloads.
- `clone` — same-model sanitized clone. Strips hardware identity and common key/credential fields from exported UCI config.

The created profile uses `format: glinet-portable-profile/v2` and remains able to import older `v1` profiles.

## Validate

`POST /api/backups/:backupId/validate`

The response now includes:

- `profile.mode`
- richer target facts: board ID, OpenWrt version, architecture, kernel
- `packageComparison`
- `plan.warnings`, `plan.apply`, and `plan.skipped`

## Package review

`POST /api/backups/:backupId/packages`

Compares source user-installed packages captured in the backup against target installed packages.

Response groups:

- `missingKernelModules`
- `missing`
- `installed`

Kernel modules are separated because they are firmware/kernel-tied and should not be blindly installed across routers.

## Restore

`POST /api/backups/:backupId/restore`

For `clone` and `remote-safe`, restore is blocked unless source and target board IDs match. Network, DHCP, wireless, and firewall changes are committed but service reload is deferred so a remote SSH/Tailscale/ZeroTier session can return a proper API response.
