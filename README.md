# GL.iNet Cross-Model Backup, Migration and Recovery

`luci-app-glinet-crossmodel-backup` is a native, architecture-independent LuCI
application and CLI for GL.iNet firmware 4.x and generic OpenWrt. One IPK works
in both roles:

- **Local / direct:** back up, inspect, validate, and restore the router on
  which the IPK is installed.
- **Controller:** operate against other routers over SSH. The endpoint does not
  need this IPK; the controller streams the same shell runtime for each job and
  removes remote temporary files afterward.

The controller is the differentiator, not a separate edition. In the UI this is
one operation-scope choice: **This Router** or **Remote Router**.

This `main` branch is the authoritative router-native product and release
source. The separately maintained [`docker`](https://github.com/zippyy/GL.iNet-CrossModel-BackupRestoreUtility/tree/docker) branch contains
the experimental Docker/Node.js edition; Docker runtime files are intentionally
not duplicated here.

## Safety model

- New archives use format v2 and the dedicated `glinet-crossmodel/` prefix.
  They cannot be mistaken for stock root-filesystem backups.
- Every payload member is SHA-256 hashed. Member paths, top-level paths, links,
  the manifest version, and hashes are checked before extraction.
- Restore always runs read-only validation and creates a target-side
  pre-restore snapshot before changing files.
- Cross-model Portable Profiles never import source radio names, raw wireless,
  raw network topology, Ethernet assignments, switch/DSA layout, factory MACs,
  host keys, device TLS keys, cloud/node identity, or raw flash state.
- Clone and Remote-Safe Clone require the same model. Device Snapshot requires
  the same stable physical-device fingerprint.
- A Device Snapshot mismatch has one explicit, dangerous CLI/UI override. It is
  never inferred from a same-model match.
- Remote restores return a successful result before any network, firewall, or
  Wi-Fi activation. Remote-Safe Clone preserves target management state and
  stages source connectivity files when an active SSH management session is
  detected.
- Package feeds are advisory. Feed failure does not fail configuration restore,
  and kernel/kmod packages are never installed automatically.
- Submitted passwords are stored only in transient mode-0600 files. Router
  inventory never contains passwords.
- SSH uses `StrictHostKeyChecking=accept-new` with persistent known_hosts. A
  later host-key mismatch fails; it is not silently replaced. Saved inventory
  fingerprints are checked independently before controller operations.
- Profile count/size, automatic pruning, and rollback-snapshot retention are
  configurable in the LuCI storage policy or `/etc/config/glinet_crossmodel`.

The complete pre-change audit is in [docs/AUDIT-2026-08-11.md](docs/AUDIT-2026-08-11.md).

## Four strategies

| Strategy | Restore boundary | Identity behavior | Intended use |
| --- | --- | --- | --- |
| **Portable Profile** | Cross-model when target capabilities allow | Device identity is never captured | Migration across models and preferably versions |
| **Clone** | Hard same-model block | MAC overrides, GL DDNS/cloud identity, private VPN identity, host/TLS keys, and node state are sanitized or excluded | Deploy a known configuration to another physical router |
| **Remote-Safe Clone** | Hard same-model block | Clone rules plus target SSH, authorized_keys, ZeroTier, Tailscale, GoodCloud, rtty, WAN access, and the detected management path remain target-local | Same-model remote deployment without sacrificing access |
| **Device Snapshot** | Hard physical fingerprint block | Device-specific configuration may be retained; account databases remain excluded from automatic persistent-file discovery | Disaster recovery for the exact router |

Portable Wi-Fi records semantic fields such as band (`2.4`, `5`, or `6` GHz),
role (`main`, `guest`, or `other`), SSID, enabled state, encryption, key, hidden,
isolation, and portable roaming settings. Restore discovers target radios and
maps by band/capability instead of source `radioN` names.

The platform adapter is reported by `facts`:

- `glinet-4`: targeted semantic changes prefer the locally advertised `ubus`
  JSON-RPC UCI methods; GL DDNS dynamically maps real `glddns`/`glddnsv6` (and
  firmware-compatible fallback) sections while retaining target-bound identity
  before service reinitialization.
- `openwrt-uci`: targeted UCI fallback for generic OpenWrt.

No undocumented GL RPC method is called. Capability probes determine whether
the local RPC path is usable before falling back.

## Install and use directly

```sh
opkg install /tmp/luci-app-glinet-crossmodel-backup_2.0.0-6_all.ipk

glinet-crossmodel facts
glinet-crossmodel create \
  --output /root/portable-profile.tar.gz \
  --strategy portable \
  --name 'Travel router profile' \
  --notes 'Wi-Fi, LAN, reservations, firewall and VPN structure' \
  --categories wifi,lan,dhcp,dns,firewall,timezone,ddns,vpn,packages

glinet-crossmodel inspect /root/portable-profile.tar.gz --human
glinet-crossmodel validate /root/portable-profile.tar.gz
glinet-crossmodel packages /root/portable-profile.tar.gz
glinet-crossmodel restore /root/portable-profile.tar.gz \
  --categories wifi,lan,dhcp,dns,firewall,timezone,ddns,vpn
```

Open LuCI at **System → Backup & Recovery**. On GL.iNet firmware 4.x the same
IPK also installs a shortcut in the GL Admin Panel. No companion IPK is needed.

## Use as a controller

The UI supports manual SSH details or password-free saved router definitions.
Definitions may use request-only password authentication, a private-key path on
the controller, or SSH agent authentication. A saved definition contains:

- friendly name, host/IP, SSH port, and username;
- authentication type and optional key path;
- verified host fingerprint;
- last detected model and firmware.

It never contains a password. Profiles collected remotely are downloaded,
SHA-256 verified, and stored in the controller profile library.

The coordinator CLI is also available for automation:

```sh
# Password is read from a temporary mode-0600 file, never an argument.
glinet-crossmodel-remote facts 192.168.8.1 22 root password /tmp/ssh-password

# Key authentication.
glinet-crossmodel-remote facts 192.168.8.1 22 root key /root/.ssh/id_ed25519
```

The LuCI workflow builds the longer create/validate/restore coordinator calls
and cleans credentials and endpoint files on success, failure, or interruption.

## Diagnostic logging

The native OpenWrt package uses one structured logger across LuCI, the CLI,
backup/validation/restore core, rollback, package handling, GL.iNet integration,
and the agentless SSH/SCP coordinator. Every significant operation receives a
correlation ID that is propagated from LuCI through the controller, local CLI,
coordinator, and streamed remote runtime.

The default level is `INFO`. Logs use the `glinet-crossmodel` syslog tag and a
bounded RAM-backed file; the current file rotates once to `gcm.log.1` at 512 KB
by default:

```sh
logread -e glinet-crossmodel
tail -f /tmp/glinet-crossmodel/gcm.log
```

LuCI exposes the current level, recent entries, refresh, download, and clear
controls under **Diagnostics / Logging**. State-changing logging controls use
the same LuCI CSRF protection as backup and restore actions.

Temporarily enable DEBUG logging:

```sh
uci set glinet_crossmodel.logging.level='debug'
uci commit glinet_crossmodel
```

Enable TRACE only while reproducing a difficult issue:

```sh
uci set glinet_crossmodel.logging.level='trace'
uci commit glinet_crossmodel
```

Restore normal logging:

```sh
uci set glinet_crossmodel.logging.level='info'
uci commit glinet_crossmodel
```

For a single direct or coordinator invocation, `GCM_LOG_LEVEL=debug` overrides
UCI and `GCM_TRACE=1` forces TRACE. Diagnostics never write to machine-readable
stdout, so `facts`, `inspect`, `validate`, and `packages` remain valid JSON.
Human restore progress (`APPLIED`, `ADAPTED`, `SKIPPED`, `PRESERVED`, and
`DEFERRED`) remains a separate stdout channel.

Log fields whose names imply passwords, secrets, tokens, private/preshared
keys, certificates, TLS auth material, sessions, or CSRF data are centrally
redacted. UCI diagnostics record package, section, option, action, and result,
but never the option value.

The defaults in `/etc/config/glinet_crossmodel` are:

```text
config logging 'logging'
    option level 'info'
    option syslog '1'
    option file_log '1'
    option max_log_kb '512'
```

## Archive format v2

```text
glinet-crossmodel/
├── manifest.json
├── backup-info.txt
├── checksums.sha256
├── packages.json
├── portable/             # semantic model-independent profile, when applicable
├── uci/                  # sanitized/raw UCI, strategy dependent
├── extra/                # strategy-filtered keep.d persistent files
├── artifacts/            # explicitly selected files and ELF binaries
└── source/
    ├── facts.json
    └── packages.tsv      # reliable shell-side Package Review index
```

`manifest.json` records format/tool version, strategy, UUID, name, notes,
timestamp, source identity/facts, firmware/OpenWrt/architecture/kernel,
fingerprint where required, adapter/capabilities, included and excluded
sections, sanitizations, and persistent files discovered from
`/lib/upgrade/keep.d/*`.

Existing v1 `profile/` archives remain inspectable. Restore is a separately
labeled legacy path, requires explicit approval, has no v2 integrity claim, and
blocks the old whole-package network/wireless import.

## Package Review

`packages.json` is derived from `/usr/lib/opkg/status` and records name, version,
architecture, section, description, dependencies, installed size,
user-installed status, kmod status, and source kernel. Review classifies:

- already installed at the same version;
- already installed at a different version;
- missing and available from target feeds;
- missing and unavailable;
- kernel/kmod packages.

Only explicitly checked compatible missing packages are requested for install.
Target `opkg print-architecture` values are enforced, feed operations are
bounded when BusyBox `timeout` is available, and custom ELF files are checked
individually for ELF class and machine before placement. Matching CPU
architecture does not guarantee that every third-party binary has its required
runtime libraries; that remains part of Package Review and router validation.

Portable and Clone VPN handling recognizes GL WireGuard client/server,
OpenVPN client/server, policy packages, and AmneziaWG/AWG naming families.
Network-embedded WireGuard/AmneziaWG interfaces are extracted without physical
device bindings or private/preshared keys. Sanitized structural values are
merged so target cryptographic identity is not erased by a whole-package
portable import.

## Build and test

The standalone builder emits the legacy gzip/tar IPK wrapper accepted by the
target GL.iNet OpenWrt 21.02 opkg while preserving `Architecture: all`:

```sh
sh tests/run.sh
bash scripts/build-openwrt-ipk.sh
tar -tzf dist/luci-app-glinet-crossmodel-backup_2.0.0-6_all.ipk
```

The build copies checked-in runtime source byte-for-byte. It does not patch or
rewrite application behavior. CI runs archive traversal/link/hash tests, format
and decision tests, Lua syntax, severity-error shellcheck, builds the IPK,
inspects its members, publishes releases, and uploads artifacts.

An SDK feed build is also supported:

```sh
cp -a openwrt/luci-app-glinet-crossmodel-backup /path/to/openwrt-sdk/package/
cd /path/to/openwrt-sdk
make package/luci-app-glinet-crossmodel-backup/compile V=s
```

## Real-router validation still required

Automated tests intentionally require no router. Before declaring a specific
firmware/model combination validated, test these on real hardware:

The repository includes a non-destructive first pass that collects a temporary
Portable Profile, inspects it, validates it against the same router, and runs
Package Review without restoring or reloading services:

```sh
# Password/key material is referenced by path and never placed on argv.
scripts/real-router-smoke.sh 192.168.8.1 22 root key /root/.ssh/id_ed25519
```

- GL.iNet 4.x `ubus` UCI method signatures and rollback behavior by firmware;
- radio discovery/mapping on MediaTek, Qualcomm, Wi-Fi 6E, and Wi-Fi 7/MLO
  families;
- `gl_ddns` preference preservation, activation, and registration across 4.x;
- actual WireGuard server/client, OpenVPN server/client, AmneziaWG, and
  vendor-policy package schemas;
- keep.d expansion and persistent-file filters on each firmware family;
- Dropbear classic SCP, password/key/agent auth, known_hosts mismatch rejection,
  IPv6 targets, and cleanup after interrupted connections;
- Remote-Safe management-path detection over LAN, WAN forwarding, GoodCloud,
  rtty, Tailscale, and ZeroTier;
- pre-restore rollback from a deliberately injected mid-apply error;
- GL Admin Panel hook survival across boot, firmware update, package removal,
  and differing Admin Panel DOM builds;
- LuCI layout, keyboard focus, modal behavior, and narrow-screen rendering on
  the actual supported firmware browsers.

These are validation items, not claims of completed hardware certification.
The full requirement boundary is also recorded in
[docs/IMPLEMENTATION-MATRIX.md](docs/IMPLEMENTATION-MATRIX.md).
