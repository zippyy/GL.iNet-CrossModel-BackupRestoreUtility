# GL.iNet Cross-Model Backup / Restore Utility — Docker Edition

A self-hosted Docker controller for moving GL.iNet configuration between
router models over SSH — with the native engine's safety guarantees: canonical
v2 archives, mandatory pre-restore snapshots, verified rollback, and deferred
activation.

This is the `docker` branch. The native OpenWrt IPK / APK / LuCI edition lives
on `main` and is a separate artifact; this edition shares its engine rather
than reimplementing it.

Managed routers do **not** need an IPK or APK installed. The controller
streams the pinned canonical native runtime to the router over SSH and runs it
agentless, exactly like the native controller's `cat core.sh cli | ssh sh -s`.

---

## Architecture

```
Browser ── HTTP/JSON ──> Node/Express controller ── SSH (ssh2) ──> Router
                              │  (orchestration only)
                              ├── jobs/       persisted job state machine
                              ├── plans/      one-use validated restore tokens
                              ├── profiles/   immutable v2 archive library
                              ├── known-hosts/  host-key fingerprint trust
                              └── runtime/native/  CANONICAL RUNTIME (vendored,
                                    pinned to main @ runtime/UPSTREAM_MAIN_COMMIT)
```

Three layers, deliberately separated:

| Layer | Responsibility |
| --- | --- |
| Node/Express | HTTP API, authentication, CSRF, job orchestration, SSH/SFTP transport, profile library, host-key trust, diagnostics |
| Canonical native runtime (`runtime/native/`) | Every backup/restore/validate/activate semantic — archive v2 format, four strategies, identity protection, pre-restore snapshot, verified rollback |
| SSH | Agentless remote execution. The concatenated `core.sh` + CLI is streamed to the router (`sh -s -- <action>`) and archives move over SFTP with SHA-256 verification |

The vendored runtime is byte-identical to a pinned `main` revision
(`runtime/UPSTREAM_MAIN_COMMIT`, guarded by `runtime/native/SHA256SUMS` and
the runtime-drift test). `scripts/sync-native-runtime.sh <new-sha>` updates
the pin deliberately.

---

## Deployment

### Pull the image

```bash
docker pull ghcr.io/zippyy/glinet-crossmodel-backuprestoreutility:docker-latest
```

### Run with Docker

```bash
mkdir -p secrets
printf '%s\n' 'choose-a-long-random-password' > secrets/admin_password
chmod 600 secrets/admin_password

docker run -d --name glinet-crossmodel-backup \
  -p 127.0.0.1:8787:8787 \
  -v glinet-crossmodel-data:/data \
  -v "$PWD/secrets/admin_password:/run/secrets/admin_password:ro" \
  -e GCM_ADMIN_PASSWORD_FILE=/run/secrets/admin_password \
  ghcr.io/zippyy/glinet-crossmodel-backuprestoreutility:docker-latest
```

### Run with Compose

```bash
mkdir -p secrets
printf '%s\n' 'choose-a-long-random-password' > secrets/admin_password
chmod 600 secrets/admin_password
docker compose up -d
```

Open `http://127.0.0.1:8787`. Put the service behind an authenticated reverse
proxy when exposing it beyond localhost.

Images are multi-architecture (`linux/amd64`, `linux/arm64`). Tags on the
`docker` branch are `docker`, `docker-latest`, and `sha-<shortsha>`; native
`v2.0.0-x` IPK/APK release semantics on `main` are unaffected.

---

## Authentication

The server **refuses to start** without an administrator credential. There is
no default password.

Provide the admin password through one of:

| Source | Environment |
| --- | --- |
| Docker secret / password file (preferred) | `GCM_ADMIN_PASSWORD_FILE` (or `ADMIN_PASSWORD_FILE`) pointing at a file whose content is the password |
| scrypt hash | `GCM_ADMIN_PASSWORD_HASH` / `ADMIN_PASSWORD_HASH` in `salt:hash` form (`node lib/auth.js --hash <password>`) |
| Environment (compat) | `GCM_ADMIN_PASSWORD` / `ADMIN_PASSWORD` (minimum 8 characters) |

The secret is read once at startup, never logged, and never written to `/data`.
Login is rate-limited; sessions are server-side, HttpOnly, SameSite=Strict
with a session-bound CSRF token required for every state-changing request.

---

## Persistent storage (`/data`)

All durable state lives under `/data` (bind mount or named volume — the
Compose file uses a named volume so upgrades never lose data):

```
/data
├── profiles/      immutable archive bytes (v2 .tar.gz)
├── meta/          profile sidecar metadata (label/notes live here, not in the archive)
├── routers/       router inventory (never passwords)
├── known-hosts.json  host-key fingerprint trust store
├── jobs/          job state + sanitized transcripts
├── sessions/      server-side auth sessions
├── plans/         one-use restore plan tokens
├── logs/          rotating diagnostic log
└── settings.json  storage policy (pruning, rollback retention)
```

The container runs as a non-root user; `/data` is owned by that user and the
application tree is read-only. Upgrade with:

```bash
docker compose pull
docker compose up -d
```

The named volume survives the container replacement; profiles, routers, host
fingerprints, jobs, and settings are all retained.

---

## Routers

Save routers in the inventory (host, port, username, auth type). Passwords are
**never stored** — they are supplied per job/test-connection. Private keys are
referenced by a server-side path.

Host keys are enforced like OpenSSH's `accept-new`, but stricter:

1. **First connection**: the operator explicitly enables *accept new host key*
   (test connection / add router). The SHA-256 fingerprint is stored.
2. **Later connections**: the router's host key MUST match the stored
   fingerprint. A changed key is a hard failure — it is never replaced
   silently.
3. **Re-trusting** a changed key is a separate explicit operation (forget key,
   then accept-new again).

The fingerprint is stored per `host:port`; jobs against a saved router always
verify before any command runs.

---

## Profiles

Backups are canonical **v2 archives** (`glinet-crossmodel/v2`): a gzipped tar
with a manifest, per-file SHA-256 checksums, and strict member safety rules
(no traversal, no symlinks/hardlinks, no duplicate members, bounded expansion,
no unlisted payloads). Every archive is verified by the canonical engine on
import and on every operation.

Legacy Docker JSON profiles from the old prototype can still be
**imported, inspected, and exported**, clearly labeled `legacy-unverified`.
Restore from legacy JSON is **blocked by design** — create a fresh v2 backup
from the source router instead.

---

## Four strategies

| Strategy | Purpose | Gate |
| --- | --- | --- |
| **Portable Profile** | Cross-model migration: Wi-Fi, LAN/DHCP/DNS, firewall, DDNS, VPN structure, timezone adapt semantically | model-agnostic; identity never imported |
| **Clone** | Same-model full UCI replacement | same model/board |
| **Remote-Safe Clone** | Same-model clone that preserves the active SSH management path (stages connectivity files) | same model/board + management-route protection |
| **Device Snapshot** | Exact physical-device restore (credentials and identity included) | device fingerprint match |

Every restore requires a **mandatory validation gate**: the canonical engine
validates the archive against the **live target**, produces a plan, and the
server issues a one-use token bound to the session, router, profile SHA-256,
target facts hash, strategy, categories, and every override flag. Any drift
between validation and restore invalidates the token.

---

## Package Review

- **opkg**: package review and explicit restore of selected non-core,
  non-kmod, user-installed packages is supported (the canonical engine
  resolves compatible versions from the target feeds; kmod/kernel packages
  are review-only and never auto-installed).
- **apk-tools**: target detection is supported (the facts/review recognize
  apk-based targets). **Automatic package restoration through apk-tools is
  NOT claimed** — canonical `main` has no equivalent install behavior, so this
  edition does not invent one.

---

## Restore safety

Every restore runs on the router, in order:

1. **Mandatory pre-restore snapshot** — the target's UCI config tree (and any
   extra-tree/custom-file targets about to change) is captured, checksummed,
   and verified *before* anything is mutated.
2. **Apply** — the canonical engine applies the validated plan with
   connectivity-affecting reloads **deferred** (`GCM_DEFER_RELOAD`); the
   controller must confirm success first.
3. **Failure → automatic verified rollback** — if apply fails after a partial
   mutation, the canonical `gcm_rollback_snapshot` restores every captured
   file and verifies byte-for-byte equality with the snapshot.
4. **Deferred activation** — on success, staged network/firewall/wireless
   changes apply via an explicit `activate` job.

Job states:

```
queued → running → succeeded
                → failed          (pre-mutation or non-restore failure)
                → rolled-back     (restore failed; rollback VERIFIED — target
                                   is byte-identical to pre-state)
                → rollback-failed (restore failed AND rollback could not be
                                   verified — inspect the snapshot immediately)
```

The API and UI surface the canonical marker chain (`RESTORE=…`,
`ROLLBACK=…`, `PRE_RESTORE_SNAPSHOT=…`, `APPLIED=…`, `DEFERRED=…`) so an
operator can always see exactly what happened.

---

## Jobs

Long-running router operations are jobs, not HTTP requests. A job is created
(`202`), persisted under `/data/jobs`, and transitions through the states
above with progress notes, correlation IDs, and a sanitized transcript.
Credentials live only in the job runner's memory for the duration of the run
and are stripped before anything is persisted.

---

## Diagnostics

Every operation carries a **correlation ID** (`GCM_OP_ID`) threaded through the
controller logs and the canonical runtime's own diagnostics. Log entries are
single-line key=value records; values whose field names imply secrets are
redacted at the source. The UI exposes a log viewer with INFO/DEBUG/TRACE
level control, log download, and clear.

---

## Security

- **Authentication**: fail-closed (no credential → no start), rate-limited,
  server-side HttpOnly sessions.
- **CSRF**: session-bound double-submit token required on all state-changing
  routes.
- **Host fingerprints**: accept-new → persist → hard-fail; changed keys are
  never silently replaced.
- **Credential handling**: passwords are request/job-scoped, in-memory only,
  never logged, never written to disk, never placed on a command line (ssh2
  uses the SSH protocol).
- **Archive integrity**: canonical member scan + per-file SHA-256 verification
  before anything is extracted; import verifies before storing.
- **HTTP hardening**: Helmet CSP (`script-src`/`style-src 'self'`, no
  `unsafe-inline`), no `x-powered-by`, `nosniff`, rate limits, no stack traces
  in errors.
- **Image**: non-root runtime user, read-only application tree, writable
  `/data` only, no git metadata/tests/secrets in the image, healthcheck,
  graceful SIGTERM shutdown, no default credentials.

---

## Development

```bash
npm ci
npm test          # native shell suites (archive/strategy/packages/rollback)
                  # + Node suites (unit/transport/pipeline/UI-CSP/drift)
npm run lint      # syntax, JSON, vendored-runtime checksums, secret scan
docker build -t glinet-crossmodel-docker:test .
test/container-smoke.sh   # full container behavior smoke
```

`test/run-native.sh` drives the vendored canonical runtime's own shell
suites against sandboxed roots; `test/*.test.js` covers controller logic,
SSH transport against a real in-process ssh2 router, the HTTP→job→SSH→runtime
restore pipeline (with injected failures proving verified rollback and
rollback-failed mapping), and the strict-CSP UI.

See `docs/PARITY-MATRIX.md` for the feature-by-feature parity audit against
`main`, and `STATUS.md` for the current validation status.
