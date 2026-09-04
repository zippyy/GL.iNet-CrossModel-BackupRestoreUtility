# Docker Edition — Feature Parity Matrix

Reference points (recorded at audit time):

```text
main:   2eb8d5232a3e328862f1e299285535c5d0e4d30e  (native release v2.0.0-17)
docker: 0058925b4dc94fa5412499d0ae4c9290c0276a00  (starting SHA of this pass)
```

Status legend:

```text
CANONICAL   supplied by the vendored canonical native runtime (runtime/native/)
NODE        orchestration/API/UI implemented in Node on this branch
MIXED       canonical engine for policy, Node for transport/state
GAP         intentionally not provided (documented limitation)
```

| Feature | main | Docker before | Docker target | Status | Where proven |
| --- | --- | --- | --- | --- | --- |
| Portable Profile strategy | yes | partial (raw uci export) | canonical | CANONICAL (engine) + NODE (orchestration) | runtime/native/core.sh `gcm_restore`/`gcm_apply_portable_*`; tests/strategy, tests/rollback |
| Clone strategy | yes | no | canonical | CANONICAL + NODE | core.sh strategy enforcement; tests/strategy |
| Remote-Safe Clone strategy | yes | no | canonical | CANONICAL + NODE | core.sh `gcm_apply_raw_uci` remote-safe exclusions; tests/strategy |
| Device Snapshot strategy | yes | no | canonical | CANONICAL + NODE | core.sh fingerprint gates; tests/strategy |
| Dangerous device override | explicit flag | n/a | explicit, never inferred | NODE (plan binding) + CANONICAL | lib/plans.js; server.js restore route |
| Archive format v2 | yes | no (JSON) | canonical v2 only | CANONICAL | runtime/native/core.sh `GCM_FORMAT_NAME`; tests/archive |
| Archive security boundary | yes | no | canonical | CANONICAL | core.sh member scan + checksums; tests/archive |
| Legacy JSON import | n/a (v1 tar) | native JSON | label legacy-unverified, inspect/export only | NODE | server.js /api/profiles/import |
| Legacy restore | v1 tar w/ --allow-legacy | naive | BLOCKED for JSON (GAP, documented) | GAP | server.js validate/restore routes |
| Inspect | CLI | json view | canonical inspect (local verify) | CANONICAL | lib/engine.js inspectArchiveLocally |
| Validate (target compatibility) | CLI | warnings | canonical remote validate | CANONICAL + NODE | engine.remoteValidate; server validate job |
| Package Review | opkg + apk detection | opkg manifest | canonical review + apk-aware detection | CANONICAL + NODE | engine.remotePackages; core.sh `gcm_package_review_files` |
| Package install policy | explicit, no kmod | explicit, CORE filter | canonical (explicit selection, kmod blocked) | CANONICAL | core.sh `gcm_install_selected_packages` |
| Pre-restore snapshot | mandatory | none | canonical, target-side | CANONICAL | core.sh `gcm_pre_restore_snapshot`; tests/rollback |
| Verified rollback | yes | none | canonical + rollback-failed state | CANONICAL + NODE | core.sh `gcm_rollback_snapshot`; tests/rollback |
| Remote-safe activation | `glinet-crossmodel activate` | n/a | canonical activate + DEFERRED markers | CANONICAL + NODE | engine.remoteActivate; jobs |
| Identity sanitization | yes | none | canonical | CANONICAL | core.sh clone/snapshot rules; tests/identity |
| Target identity preservation | yes | none | canonical | CANONICAL | core.sh `PRESERVED=target-factory-identity` |
| Wi-Fi semantic mapping | yes | no | canonical | CANONICAL | core.sh portable wifi; tests/strategy |
| LAN/DHCP/DNS/firewall portable | yes | partial | canonical | CANONICAL | core.sh `gcm_apply_portable_lan_dhcp_dns` |
| GL.iNet adapter (ubus capability probe) | yes | no | canonical (target-side) | CANONICAL | core.sh adapter probes |
| VPN sanitization | yes | no | canonical | CANONICAL | core.sh portable vpn |
| Custom files/scripts policy | yes | partial | canonical | CANONICAL | core.sh `gcm_apply_custom_tree` |
| ELF class/machine validation | yes | naive arch string | canonical | CANONICAL | core.sh `gcm_binary_compatible` |
| SSH password auth | yes | yes | yes | NODE | lib/ssh.js; tests/ssh |
| SSH key auth | yes | no | yes | NODE | lib/ssh.js |
| SSH agent auth | yes (native) | no | optional (socket mount) | NODE (GCM_SSH_AUTH_SOCK) | lib/ssh.js |
| Host-key accept-new → persist → hard-fail | yes | none | yes | NODE | lib/ssh.js hostVerifier; tests/ssh |
| Credentials never persisted/logged | yes | partial | yes | NODE | lib/jobs.js in-memory secrets; lib/log.js redaction |
| Router inventory (no passwords) | yes | no | yes | NODE | lib/store.js routers |
| Profile library (immutable bytes + metadata) | profiles dir | json files | yes | NODE | lib/store.js profiles |
| Storage policy / pruning | yes | no | yes (active rollback protected) | NODE | lib/store.js prune |
| Job model + correlation logs | yes | no | yes | NODE | lib/jobs.js, lib/log.js |
| Validation gate + restore plan token | yes | no | yes | NODE | lib/plans.js |
| Authentication (fail-closed) | LuCI | none | yes | NODE | lib/auth.js |
| CSRF / rate limit / Helmet | LuCI | partial | yes | NODE | server.js |
| Diagnostics UI + log levels | yes | no | yes | NODE | server.js /api/logs |
| Multi-arch Docker image + GHCR | n/a | single | amd64+arm64 | NODE/CI | .github/workflows/docker.yml |
| Real-router smoke | tests/fixtures only | none | NOT EXECUTED on hardware | GAP | docs (validation status) |

## Gaps (deliberate)

1. Legacy Docker JSON profiles (glinet-portable-profile/v1, /v2 JSON) can be
   imported, inspected, and exported as `legacy-unverified`, but cannot be
   restored. A safe conversion to the canonical v2 archive has not been
   implemented; restoring unverified JSON content would violate the v2
   integrity boundary. This is the same policy main applies to legacy v1 tar
   profiles (which require `--allow-legacy` and are network/wireless-blocked);
   JSON profiles have no equivalent safe subset and stay blocked.
2. Real-hardware router validation is NOT EXECUTED in this pass. Automated
   proof runs the vendored canonical engine against fixture router state and
   an in-process SSH server; it is not a substitute for on-device smoke tests.
3. apk-tools package installation parity is limited to whatever `main`
   supports (review classification). See docs in README.
