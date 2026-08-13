# GL.iNet Cross-Model Backup & Restore — Agent Instructions

This file contains repository-specific instructions for AI coding agents working on **GL.iNet Cross-Model Backup, Migration and Recovery**.

Repository:

`zippyy/GL.iNet-CrossModel-BackupRestoreUtility`

Primary development branch:

`main`

Unless the task explicitly says otherwise, treat the **router-native implementation on `main` as authoritative**. The `docker` branch is a separate experimental product line and must not be mixed into the router runtime or IPK.

---

## 1. Project Mission

This project provides a native OpenWrt/LuCI backup, migration, cloning, and disaster-recovery utility for GL.iNet firmware 4.x and generic OpenWrt.

A single IPK can operate in two roles:

1. **Local / direct mode**
   - Back up the router on which the package is installed.
   - Inspect archives.
   - Validate archives.
   - Restore archives.
   - Review/install compatible packages.

2. **Controller mode**
   - Manage other routers over SSH.
   - Remote routers do **not** require the IPK.
   - The controller streams the same shell runtime to the remote router.
   - Temporary remote files must be cleaned afterward.

Do not create separate implementations for local and remote behavior unless technically unavoidable.

Shared behavior should remain in the shared runtime wherever possible.

---

# 2. Core Design Principles

When modifying this repository, optimize for these priorities in this order:

1. **Do not brick routers.**
2. **Do not destroy remote management access.**
3. **Do not leak credentials or device identity.**
4. **Do not weaken archive validation.**
5. **Do not weaken rollback behavior.**
6. **Preserve cross-model portability rules.**
7. **Preserve compatibility with constrained OpenWrt systems.**
8. **Keep local and agentless-remote behavior consistent.**
9. **Maintain backward compatibility where reasonably possible.**
10. Improve usability, diagnostics, and maintainability.

A backup utility is safety-critical infrastructure.

Prefer refusing an unsafe restore over attempting to be clever.

---

# 3. Repository Map

The OpenWrt package lives primarily under:

```text
openwrt/luci-app-glinet-crossmodel-backup/
```

Important files include:

```text
openwrt/luci-app-glinet-crossmodel-backup/
├── Makefile
└── root/
    ├── etc/
    │   ├── config/
    │   │   └── glinet_crossmodel
    │   └── init.d/
    │       └── gcm-glui-integration
    ├── lib/
    │   └── upgrade/
    │       └── keep.d/
    │           └── glinet-crossmodel
    ├── usr/
    │   ├── bin/
    │   │   └── glinet-crossmodel
    │   ├── lib/
    │   │   ├── glinet-crossmodel/
    │   │   │   └── core.sh
    │   │   └── lua/luci/
    │   │       ├── controller/
    │   │       │   └── glinet_crossmodel.lua
    │   │       └── view/glinet_crossmodel/
    │   │           └── index.htm
    │   └── libexec/
    │       ├── glinet-crossmodel-remote
    │       ├── glinet-crossmodel-backup
    │       ├── glinet-crossmodel-validate
    │       └── gcm-glui-integrate
    └── www/
        └── js/
            └── gcm-glui-hook.js
```

Other important areas:

```text
tests/
scripts/
docs/
.github/workflows/
README.md
STATUS.md
```

Before making significant changes, inspect the relevant implementation rather than assuming behavior from filenames or documentation alone.

---

# 4. Runtime Architecture

## `core.sh`

`core.sh` contains the majority of backup, validation, compatibility, restore, sanitization, adaptation, package, and rollback logic.

It is especially important because it serves **two environments**:

- sourced locally by the installed CLI;
- concatenated with the CLI and streamed over SSH for agentless remote operation.

Therefore:

**`core.sh` must remain BusyBox ash / POSIX-shell compatible.**

Do not introduce dependencies on:

- Bash
- Python
- Node.js
- Perl
- GNU-only utilities
- package-local files unavailable on remote targets

unless the feature explicitly detects their availability and has a safe fallback.

Assume a remote endpoint may contain only normal OpenWrt/BusyBox tooling.

---

## `glinet-crossmodel`

This is the user-facing CLI.

Major commands include:

```sh
glinet-crossmodel facts
glinet-crossmodel create
glinet-crossmodel inspect
glinet-crossmodel validate
glinet-crossmodel restore
glinet-crossmodel packages
glinet-crossmodel version
```

Keep command-line interfaces stable unless the requested feature requires a change.

Prefer adding optional flags over breaking existing invocation forms.

---

## `glinet-crossmodel-remote`

This is the agentless SSH coordinator.

It handles:

- SSH connection setup
- password/key/agent authentication
- known_hosts
- runtime streaming
- SCP transfers
- SHA-256 transfer verification
- remote temporary files
- remote cleanup
- remote create
- remote validate
- remote restore
- remote package review

Remote endpoints should not need the IPK installed.

Do not accidentally introduce a dependency on files existing under `/usr/lib/glinet-crossmodel/` on the remote router.

---

## LuCI Controller

The main LuCI backend is:

```text
root/usr/lib/lua/luci/controller/glinet_crossmodel.lua
```

It handles:

- API routing
- CSRF validation
- saved router inventory
- local operations
- remote operations
- archive upload/download
- profile storage
- storage limits
- retention
- SSH credentials
- backend command invocation

Do not move security-sensitive validation solely into JavaScript.

The server side must remain authoritative.

---

# 5. stdout Is an API

This is a critical rule.

Several CLI commands produce machine-readable output consumed by the LuCI controller.

Examples include:

```text
facts
inspect
validate
packages
```

Do not casually add:

```sh
echo "Doing something..."
```

to code paths used by these commands.

A harmless-looking debug line can turn valid JSON into:

```text
Starting validation...
{"valid":true}
```

and break the application.

### Rules

- Machine-readable stdout must remain machine-readable.
- Diagnostic output should use stderr, syslog, or the project's logging subsystem.
- Human-readable create/restore status may continue using the established output conventions.
- When changing logging, explicitly test JSON-producing commands with a JSON parser.

Treat stdout compatibility as part of the public API.

---

# 6. Archive Format Is a Security Boundary

Current archives use format v2 with the dedicated prefix:

```text
glinet-crossmodel/
```

Typical contents:

```text
glinet-crossmodel/
├── manifest.json
├── backup-info.txt
├── checksums.sha256
├── packages.json
├── portable/
├── uci/
├── extra/
├── artifacts/
└── source/
```

Do not weaken archive validation.

The implementation must continue protecting against:

- absolute paths
- `..` traversal
- unsafe member names
- unexpected top-level members
- duplicate member names
- symlinks
- hard links
- device files
- FIFOs
- sockets
- malformed archives
- excessive archive members
- incomplete checksum coverage
- duplicate checksum entries
- SHA-256 mismatches
- unsupported manifest versions

Validation should occur **before extraction/application whenever possible**.

Never replace safe extraction logic with a bare:

```sh
tar -xzf "$archive" -C /
```

or equivalent.

---

# 7. Backup Strategies

There are four major strategies.

## Portable Profile

Purpose:

Cross-model migration.

Portable profiles describe configuration semantically instead of copying source hardware topology.

Do not directly restore source-specific values such as:

- `radio0`, `radio1`, etc.
- Ethernet device assignments
- DSA/switch topology
- source physical interfaces
- factory MAC addresses
- host keys
- cloud identity
- raw flash state

Wi-Fi should be mapped using target capabilities such as:

- band
- role
- available radios
- target logical networks

Portable restore should adapt to the target.

---

## Clone

Purpose:

Replicate configuration to another router of the **same model**.

Clone must retain its same-model requirement.

Device-bound identity must continue to be sanitized or preserved from the target as appropriate.

Do not allow convenience changes to accidentally clone:

- MAC identity
- host SSH keys
- TLS private identity
- GL cloud identity
- node/device identity
- private VPN identity

unless explicitly intended by the design.

---

## Remote-Safe Clone

Purpose:

Same-model remote deployment without disconnecting the administrator.

This mode must prioritize continued remote management.

Preserve target-local management mechanisms including, where applicable:

- active SSH management path
- authorized keys
- WAN management
- GoodCloud
- rtty
- Tailscale
- ZeroTier
- other detected management state

When an active SSH connection would be disrupted, source connectivity configuration may need to be staged rather than activated immediately.

Do not weaken these protections.

---

## Device Snapshot

Purpose:

Disaster recovery of the **exact physical router**.

Device Snapshot must remain bound to the target device fingerprint.

A same-model match alone is not sufficient.

A fingerprint mismatch should fail unless the user explicitly invokes the dangerous override.

Never infer or silently enable that override.

---

# 8. Restore Safety

Restore operations must follow the safety sequence.

Broadly:

```text
archive
  ↓
inspect
  ↓
validate structure
  ↓
validate manifest
  ↓
verify checksums
  ↓
validate strategy compatibility
  ↓
create pre-restore snapshot
  ↓
apply configuration
  ↓
verify / complete
  ↓
activate only when appropriate
```

Before mutating the target, a pre-restore rollback snapshot is mandatory.

Do not make rollback snapshots optional merely to simplify an implementation.

If snapshot creation fails, restore should normally fail before applying changes.

---

# 9. Rollback Is Not Best-Effort Decoration

Rollback behavior is a core feature.

Changes involving restore must consider:

- which files will be modified;
- which files will be created;
- which UCI packages will change;
- what must be restored if an intermediate step fails;
- how rollback integrity is verified.

A restore failure after partial application must not simply return an error and leave the target in an unknown state when rollback is possible.

When modifying restore code, test at least one deliberately injected mid-restore failure when practical.

---

# 10. Remote Restore Activation Rules

Remote restores are different from local restores.

Do not reload network, wireless, or firewall state prematurely during a remote operation if doing so can terminate the SSH connection before the controller receives the result.

The implementation deliberately supports deferred activation.

Preserve this behavior.

A successful remote restore should be able to report success before connectivity-affecting reload/reboot actions occur.

---

# 11. Device Identity Must Be Treated Carefully

Do not casually copy source identity to another router.

Potential device-bound data includes:

- MAC addresses
- SSH host keys
- TLS private keys
- private WireGuard keys
- preshared keys
- certificates
- cloud identifiers
- GL DDNS/device registration
- GoodCloud identity
- rtty identity
- ZeroTier identity
- Tailscale state
- serial-bound data
- hardware identifiers
- vendor provisioning state

When uncertain whether a value represents device identity, preserve the target value or exclude the value until the behavior is understood.

---

# 12. Secrets

Never print, log, commit, persist, or expose:

- passwords
- SSH private-key contents
- WireGuard private keys
- preshared keys
- API tokens
- authentication tokens
- CSRF tokens
- session IDs
- TLS private keys
- sensitive credential files

Passwords for remote routers are intentionally handled using transient mode-0600 files.

They must not be:

- stored in router inventory;
- passed on the command line;
- logged;
- returned in API responses.

Saved router definitions may contain authentication metadata and private-key paths but never password values.

---

# 13. SSH Host Verification

Do not weaken SSH host verification for convenience.

The controller intentionally maintains:

```text
/root/.ssh/known_hosts
```

Current behavior uses deliberate first-contact enrollment followed by mismatch rejection.

Saved router inventory may also contain a verified fingerprint.

Do not replace this with:

```text
StrictHostKeyChecking=no
```

Do not silently delete and recreate known_hosts entries when a key changes.

A changed host key is a security event and should require deliberate user action.

---

# 14. Remote Temporary Files

Agentless operations create temporary endpoint files.

Every success and failure path must consider cleanup.

Use traps where appropriate.

Temporary files should be:

- unpredictable or operation-ID scoped;
- stored in `/tmp` where appropriate;
- removed after operations;
- removed after interrupted operations where reasonably possible.

Do not leave archives, credential material, scripts lists, or other operation artifacts behind without a reason.

---

# 15. Package Restoration

Package restoration is intentionally conservative.

Important rules:

- package installation is optional;
- feed failure must not invalidate an otherwise successful configuration restore;
- packages require explicit selection where applicable;
- kernel modules must not be automatically restored;
- architecture compatibility must be checked;
- already-installed packages should not be unnecessarily reinstalled.

Never implement "restore every package from the old router" blindly.

Especially do not automatically install:

```text
kmod-*
kernel-specific packages
hardware-specific packages
```

from another firmware/kernel environment.

---

# 16. Custom Files and Binaries

Custom paths are security-sensitive.

Continue validating paths before reading or writing them.

Reject unsafe forms including traversal.

Custom binaries require compatibility checks.

CPU architecture equality does not guarantee runtime compatibility.

Do not remove ELF validation merely because two routers report the same architecture.

---

# 17. GL.iNet vs Generic OpenWrt

The utility supports both:

- GL.iNet firmware 4.x
- generic OpenWrt

The platform adapter distinguishes behavior.

Where GL.iNet exposes a supported local interface, prefer documented/discovered capabilities.

Do not invent or assume undocumented GL RPC APIs.

Capability probe first.

Fallback safely to standard UCI where supported.

A feature must not unnecessarily make generic OpenWrt unusable.

---

# 18. Resource Constraints

Assume the target router may have:

- limited RAM;
- limited `/tmp`;
- slow flash;
- BusyBox tools;
- older OpenWrt userspace;
- limited package availability.

Avoid:

- large dependencies;
- unnecessary background daemons;
- unbounded logs;
- repeated archive extraction;
- unnecessary hashing;
- huge in-memory objects;
- writing verbose temporary data to persistent flash;
- excessive process spawning in hot loops.

Favor straightforward shell and Lua over adding heavyweight runtimes.

---

# 19. Shell Coding Rules

Files intended for router execution must remain compatible with their declared shell.

For `core.sh` and streamed CLI logic:

**Do not use Bash-only syntax.**

Avoid constructs such as:

```bash
[[ ... ]]
arrays=(...)
${array[@]}
<(process substitution)
declare
local -n
```

unless the file explicitly runs under Bash, which core router code should not.

Prefer:

```sh
case
test / [
while
for
sed
awk
uci
jsonfilter
ubus
```

when appropriate.

Quote variable expansions unless intentional splitting is required.

Be especially careful with:

- filenames
- user-provided strings
- SSH arguments
- command construction
- temporary paths

---

# 20. Lua / LuCI Rules

Server-side validation is mandatory.

JavaScript validation is only a convenience.

For state-changing LuCI API operations:

- require POST;
- require valid CSRF;
- validate all input;
- sanitize identifiers and paths;
- return useful HTTP status codes;
- do not return secrets.

Use existing helpers and conventions before adding parallel abstractions.

Do not build shell commands from unsanitized request values.

---

# 21. UI Rules

The LuCI UI should be functional first.

Do not redesign the entire interface while fixing an unrelated backend issue.

Preserve support for:

- local router mode;
- remote router mode;
- saved router inventory;
- backup strategy selection;
- category selection;
- validation;
- package review;
- restore warnings;
- dangerous overrides;
- profile management.

Destructive or dangerous operations should be explicit.

Do not hide important safety warnings simply to make the workflow shorter.

---

# 22. Logging Rules

Logging should be useful but must not break command output.

Prefer structured messages containing information such as:

```text
operation
component
stage
scope
strategy
result
reason
```

Never log secret values.

Good:

```text
INFO component=ssh host=192.168.8.1 auth=password stage=connect
```

Bad:

```text
DEBUG password=hunter2
```

For UCI changes, log the option name if useful but redact sensitive values.

Examples of sensitive option names include:

```text
password
passwd
secret
token
authkey
private_key
privatekey
preshared_key
tls_auth
tls_crypt
```

When adding logging, remember the machine-readable stdout rule.

---

# 23. Error Handling

Do not hide valuable failures with unconditional patterns such as:

```sh
some-important-command >/dev/null 2>&1 || true
```

unless failure is deliberately non-fatal and understood.

If a failure is intentionally tolerated:

- document why;
- preserve enough diagnostic information;
- avoid changing the final result incorrectly.

Errors should identify the stage that failed.

Prefer:

```text
Could not calculate SHA-256 on the remote router.
```

over:

```text
Operation failed.
```

Do not expose secrets just to provide better errors.

---

# 24. Scope Discipline

Do not perform broad unrelated refactors while implementing a focused task.

In particular, avoid simultaneously rewriting:

- archive format;
- restore engine;
- LuCI UI;
- SSH layer;
- logging;
- package handling;

unless the requested task actually requires those changes.

Small diffs are easier to reason about in a router recovery tool.

When architectural refactoring is required, preserve behavior first and improve structure second.

---

# 25. Generated and Built Artifacts

Do not hand-edit generated build output when the source file exists elsewhere.

The IPK build should package the checked-in runtime source.

Changes should be made to authoritative source files and then rebuilt.

Do not commit arbitrary test archives, credentials, router backups, private keys, or large generated artifacts.

---

# 26. Required Testing

Before considering a meaningful code change complete, run the repository test suite where possible:

```sh
sh tests/run.sh
```

Then build the OpenWrt package:

```sh
bash scripts/build-openwrt-ipk.sh
```

Inspect the resulting package/archive as appropriate.

Do not claim tests passed unless they were actually executed.

If the environment prevents a test from running, state that clearly.

---

# 27. Shell Validation

For modified shell code, perform syntax validation.

Examples:

```sh
sh -n path/to/file
```

Run ShellCheck when available and relevant.

Remember that ShellCheck success does not prove BusyBox runtime compatibility.

---

# 28. Lua Validation

For modified Lua files, perform syntax validation using an available Lua compiler/interpreter where practical.

Do not assume desktop Lua and target LuCI versions expose identical APIs.

Changes involving LuCI behavior may still require router testing.

---

# 29. JSON Contract Tests

If modifying:

- logging;
- CLI dispatch;
- facts;
- inspect;
- validation;
- package review;
- command invocation;

explicitly verify that machine-readable output remains valid.

At minimum check applicable commands such as:

```sh
glinet-crossmodel facts
glinet-crossmodel inspect ...
glinet-crossmodel validate ...
glinet-crossmodel packages ...
```

Parse the result.

Do not only visually inspect it.

---

# 30. Archive Security Tests

Changes involving archives, extraction, paths, manifests, or checksums should cover hostile cases such as:

```text
../ traversal
absolute paths
duplicate members
symlinks
hard links
bad checksums
missing checksums
unexpected top-level paths
malformed manifest
unsupported version
```

A security regression in archive handling is a blocking issue.

---

# 31. Restore Tests

Changes to restoration should exercise:

- success path;
- validation failure;
- partial apply failure;
- rollback path;
- rollback verification;
- category selection;
- strategy-specific behavior.

For connectivity-related changes also consider deferred remote activation.

---

# 32. Remote Tests

Changes affecting remote mode should consider:

- password authentication;
- key authentication;
- SSH agent authentication;
- connection timeout;
- authentication failure;
- changed host key;
- SCP upload;
- SCP download;
- SHA-256 verification;
- interrupted operations;
- remote cleanup;
- IPv4;
- IPv6 where applicable.

Do not mark remote behavior validated based solely on local mode tests.

---

# 33. Real Hardware Boundary

Unit/integration tests intentionally cannot prove every router-specific behavior.

Do not state that hardware/firmware support is verified unless it was actually tested.

Important real-router validation areas include:

- GL.iNet 4.x `ubus` UCI behavior;
- MediaTek radio mapping;
- Qualcomm radio mapping;
- Wi-Fi 6E;
- Wi-Fi 7;
- MLO;
- GL DDNS;
- WireGuard;
- OpenVPN;
- AmneziaWG;
- persistent-file discovery;
- Dropbear/SCP differences;
- Remote-Safe management path preservation;
- rollback after deliberately injected failure;
- GL Admin Panel integration.

Distinguish:

**implemented**

from:

**tested in automation**

from:

**validated on real hardware**

---

# 34. Documentation

Update documentation when changing:

- command syntax;
- archive format;
- safety behavior;
- restore strategy behavior;
- configuration options;
- LuCI workflow;
- package requirements;
- supported functionality.

Keep README examples aligned with actual behavior.

Do not document a capability as verified merely because code for it exists.

---

# 35. Versioning

Do not bump versions merely because files changed.

If the task requires a release/version bump, inspect:

```text
openwrt/luci-app-glinet-crossmodel-backup/Makefile
```

and the existing release workflow before changing version or package release numbers.

Keep:

- tool version;
- OpenWrt package version;
- package release;
- GitHub release/tag behavior

consistent.

---

# 36. Commit Discipline

When preparing a commit:

- keep changes focused;
- do not include credentials;
- do not include router backups;
- do not include unrelated formatting churn;
- do not modify generated files unnecessarily;
- describe safety-impacting changes explicitly.

Useful commit prefixes include:

```text
fix:
feat:
security:
logging:
docs:
test:
build:
release:
```

Use the repository's recent history as the stronger guide when conventions differ.

---

# 37. Before Editing

For any non-trivial task:

1. Confirm the target branch.
2. Read the relevant implementation.
3. Trace the complete call path.
4. Identify local-mode implications.
5. Identify remote-mode implications.
6. Identify archive-format implications.
7. Identify identity/security implications.
8. Identify rollback implications.
9. Identify JSON/stdout implications.
10. Inspect existing tests covering the area.

Do not implement based solely on README descriptions.

---

# 38. Before Finishing

Review the final diff and answer these questions:

- Could this brick a router?
- Could this cause loss of remote access?
- Could this weaken validation?
- Could this bypass rollback?
- Could this copy source device identity?
- Could this expose a secret?
- Could this break remote agentless mode?
- Could this break BusyBox compatibility?
- Could this contaminate JSON stdout?
- Could this leave remote temporary files behind?
- Could this install incompatible packages?
- Could this behave differently between local and remote mode unintentionally?

If the answer to any is "possibly", investigate before declaring the task complete.

---

# 39. Agent Completion Report

When finishing a substantial task, report:

### What changed

Briefly describe the implemented behavior.

### Files changed

List the meaningful files modified.

### Safety impact

State whether the change affects:

- restore behavior;
- rollback;
- identity;
- SSH;
- archive validation;
- connectivity.

### Tests

List the exact tests actually run.

Example:

```text
PASS sh tests/run.sh
PASS sh -n core.sh
PASS IPK build
NOT RUN real-router smoke test — no router available
```

### Remaining validation

Clearly identify anything requiring physical GL.iNet/OpenWrt hardware.

Do not hide untested areas.

---

# 40. Absolute Rules

The following rules should be treated as hard constraints unless a task explicitly requires redesigning them:

**DO NOT:**

- disable archive safety checks;
- bypass checksums;
- silently bypass model/fingerprint restrictions;
- silently enable dangerous restore overrides;
- disable SSH host-key verification;
- persist router passwords;
- put passwords on argv;
- log credentials;
- clone private device identity unintentionally;
- automatically restore kernel modules;
- reload connectivity during remote restore before a safe response point;
- make `core.sh` depend on the IPK being installed remotely;
- introduce Bash requirements into the streamed runtime;
- contaminate JSON stdout;
- remove mandatory pre-restore rollback creation;
- claim real-hardware validation that did not occur.

When safety and convenience conflict, choose safety.

---

# 41. Preferred Agent Behavior

Agents working in this repository should be proactive.

If you discover a small defect directly related to the requested change, fix it when doing so is low risk and testable.

If you discover a larger unrelated defect:

- document it;
- explain its impact;
- leave it for a separate change unless it blocks the current work.

Do not ask for permission for every ordinary implementation detail.

Inspect the code, make the best technically sound decision consistent with this document, implement it, and test it.

The goal is a backup and recovery tool that can be trusted on real GL.iNet and OpenWrt routers—not merely code that looks correct in a desktop development environment.
