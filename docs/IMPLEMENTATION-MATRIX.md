# Native implementation matrix

This matrix distinguishes checked-in behavior from validation that can only be
performed on an actual router. “Implemented” means the behavior exists in the
canonical package source and is covered by a static, unit, fixture, security,
or package-content check where practical. It does not imply certification of
every vendor firmware build.

| Area | Implemented behavior | Remaining hardware validation |
| --- | --- | --- |
| Package architecture | One `Architecture: all` IPK provides direct and controller modes; endpoints receive the shared core and CLI over SSH | Install/remove on representative GL.iNet 4.x and generic OpenWrt releases |
| SSH trust and credentials | Password files are transient mode 0600; key/agent auth is supported; `accept-new` records first use; saved fingerprints and known_hosts are both enforced; remote files are SHA-256 verified and cleaned | Dropbear/OpenSSH combinations, IPv6 and interrupted sessions |
| Archive v2 | Dedicated prefix, strict file/directory-only members, traversal/duplicate rejection, bounded pre-extraction per-file/per-archive size limits, validated manifest identity, exact SHA-256 payload coverage and legacy-v1 labeling | Large archives on low-memory devices |
| Portable Profile | Semantic Wi-Fi band/role mapping, logical LAN, DHCP/reservations, DNS, firewall/forwards, timezone, GL/generic DDNS, VPN structure, packages and explicit extras | Chipset-specific radio schemas and vendor VPN variations |
| GL.iNet adapter | Firmware 4.x detection, capability-probed local `ubus` JSON UCI calls with generic UCI fallback, dynamic `gl_ddns` IPv4/IPv6 section handling and service reinitialization | Exact advertised ubus signatures and DDNS registration behavior per firmware |
| Clone | Stable board-ID hard block, category-aware broad UCI capture, identity sanitization, target identity reinjection and persistent-file policy | Same-model migrations across firmware releases |
| Remote-Safe Clone | Clone rules plus management packages/state preserved, active SSH route reported, connectivity packages staged last and activation deferred | LAN/WAN/overlay/cloud management paths and reconnect behavior |
| Device Snapshot | Strong factory serial/MAC fingerprint required at creation and restore; exact-device hard block with explicit dangerous override | Factory-data availability on each board family |
| Restore safety | Read-only preflight, exact archive verification, bounded rollback retention, target snapshot before writes, rollback on apply failure, checksum and post-copy rollback verification | Deliberately injected failures and power-loss behavior |
| Packages and ELF | Enriched opkg metadata, five-way review, target feed/architecture checks, bounded feed calls, explicit installs, kmod prohibition, per-binary ELF class/machine checks | ABI/library availability beyond ELF architecture |
| LuCI and GL UI | Scope-first workflow, four strategy treatments, inventory, storage policy, library actions, Package Review and a mandatory validation gate; one IPK also installs the GL Admin hook | LuCI theme/browser variants and changing GL Admin DOMs |

The router-dependent checklist in the root README is the authoritative list of
tests that must be run before claiming certification for a named model and
firmware version.
