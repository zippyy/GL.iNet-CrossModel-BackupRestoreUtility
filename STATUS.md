# Docker branch status

This branch is the standalone Docker/Node.js controller edition. It is
intentionally separate from the native router implementation on `main` and
does not build or publish an OpenWrt IPK/APK. It shares the canonical engine:
the pinned native runtime under `runtime/native/` is streamed to managed
routers over SSH, so no package is installed on the router.

## Production readiness (implementation / test)

The Docker edition implements the native engine's safety guarantees and
proves them end to end:

- **Canonical engine, not a reimplementation.** Archive v2 format, archive
  security boundary (member scan, checksums, expansion limits), the four
  strategies, identity protection, mandatory pre-restore snapshot, verified
  rollback, and deferred activation are all supplied by the vendored
  canonical runtime (pinned to `main`, drift-guarded by SHA-256 checksums and
  a CI test). Node/Express handles orchestration, transport, and state only.
- **Verified rollback through the full container path.** The HTTP API → job
  runner → SSH/SFTP → streamed canonical runtime pipeline is tested with
  real failure injection: a restore that mutates the target and then fails is
  rolled back by the canonical engine to a byte-identical pre-state
  (`rolled-back`), and a restore whose rollback also fails surfaces loudly as
  `rollback-failed`. Target trees are hash-compared before/after.
- **Host-key trust.** accept-new → persist → hard-fail on changed keys,
  enforced through the controller's router wrapper and exercised over real
  SSH; stored fingerprints are never silently replaced.
- **Hardened delivery.** Aggregate test suite green (`npm test`: native shell
  suites + Node suites), lint green, strict-CSP UI proven (no inline
  script/style), multi-stage non-root container with read-only application
  tree and persistent `/data`, fail-closed authentication (no credential →
  no start), CSRF enforced, graceful SIGTERM shutdown.
- **CI + registry.** The `docker-edition-ci` workflow tests every push/PR and
  publishes `linux/amd64` + `linux/arm64` to
  `ghcr.io/zippyy/glinet-crossmodel-backuprestoreutility` on pushes to this
  branch (`docker`, `docker-latest`, `sha-<shortsha>` tags). The published
  image itself is smoke-tested (non-root, health, auth, CSRF, UI, `/data`
  persistence across restart).

## Remaining boundary: real-hardware validation

Production readiness above is an implementation/test statement. No claim of
universal router certification is made: the full matrix has not been run
against physical GL.iNet hardware in this environment. Before relying on this
edition for a production migration, validate against the exact source and
target router models (facts, create, inspect, validate, package review, and a
staged restore on a non-production device). Fixture/in-process SSH proof is
not a substitute for hardware certification.

## Intentionally unsupported / not claimed

- **Legacy Docker JSON profiles** (old prototype format): import, inspect,
  and export are supported and clearly labeled `legacy-unverified`; restore
  from legacy JSON is **blocked by design** (create a fresh v2 backup).
- **apk-tools package restoration**: apk-based target detection is supported;
  automatic package restoration through apk-tools is **not claimed** because
  canonical `main` has no equivalent install behavior.
- **SSH agent authentication**: implemented via `GCM_SSH_AUTH_SOCK`; local
  execution status: IMPLEMENTED / NOT EXECUTED in this environment's suite
  (password, key, and host-trust paths are proven; agent mode is optional).
- **Real-router smoke**: NOT EXECUTED (no safe test router configured in this
  environment).
