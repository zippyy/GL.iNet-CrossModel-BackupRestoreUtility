#!/bin/sh
# Restore failure-injection + verified-rollback suite against the VENDORED
# canonical runtime.
#
# Proves the full chain on a sandboxed fake target:
#   pre-state (hashed)
#   -> mandatory pre-restore snapshot (stub captures the sandbox target's UCI
#      files, hashes them, and verifies the snapshot before restore proceeds)
#   -> partial mutation (clone raw-UCI apply writes the source config)
#   -> injected failure (mock uci commit fails)
#   -> automatic rollback (REAL gcm_rollback_snapshot under GCM_ROLLBACK_TARGET_ROOT)
#   -> post-state == pre-state (SHA-256 verified over the whole tree)
#
# The snapshot stub mirrors exactly the stubbing main's own test suite uses
# (tests/test-preserve-lan-ip.sh) so the REAL rollback engine runs unmodified.
set -eu

. "$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)/test/harness.sh"
gcm_mock_uci_install
. "$CORE"

# Stable host-side facts so clone validation passes.
gcm_source_model() { printf 'Test-Router\n'; }
gcm_board_name() { printf 'test-board\n'; }
gcm_firmware_version() { printf '4.8.2\n'; }
gcm_openwrt_version() { printf '23.05\n'; }
gcm_architecture() { printf 'test-arch\n'; }
gcm_device_fingerprint() { printf 'unavailable\n'; }

# Faithful pre-restore snapshot stub: captures the sandbox live target's
# /etc/config files, hashes them, and verifies before restore proceeds.
# (The real function reads the literal host /etc/config; this redirects the
# same logic at the sandbox. Rollback below is the REAL gcm_rollback_snapshot.)
gcm_pre_restore_snapshot() {
  profile_id=$1
  root="$TEST_ROOT/snapshot/$profile_id"
  snapshot_root="$root/glinet-crossmodel-rollback"
  rm -rf "$root"
  mkdir -p "$snapshot_root/etc/config" "$snapshot_root/uci-delta"
  for source in "$GCM_LIVE_ROOT"/etc/config/*; do
    [ -f "$source" ] && [ ! -L "$source" ] && cp -p "$source" "$snapshot_root/etc/config/"
  done
  : > "$snapshot_root/created-paths.txt"
  printf 'created_at=fake\nmodel=%s\n' "$(gcm_source_model)" > "$snapshot_root/rollback-info.txt"
  (cd "$root" && find glinet-crossmodel-rollback -type f ! -name checksums.sha256 | sort | while IFS= read -r p; do sha256sum "$p"; done > glinet-crossmodel-rollback/checksums.sha256)
  # The snapshot must be verified before restore proceeds (canonical rule).
  (cd "$root" && sha256sum -c glinet-crossmodel-rollback/checksums.sha256 >/dev/null 2>&1) || { echo 'snapshot verification failed' >&2; return 1; }
  printf '%s\n' "$root"
}

# ---- Build a clone v2 archive whose uci/network differs from the target ----
LIVE="$TEST_ROOT/live"
SNAP_SRC="$TEST_ROOT/snapshot-src"
TARGET_ROOT="$TEST_ROOT/target-root"
ARCHIVE_TREE="$TEST_ROOT/archive-tree"
rm -rf "$LIVE" "$SNAP_SRC" "$TARGET_ROOT" "$ARCHIVE_TREE"
mkdir -p "$LIVE/etc/config" "$ARCHIVE_TREE/glinet-crossmodel/source" "$ARCHIVE_TREE/glinet-crossmodel/uci"

# Pre-state: the live target has a stable network config.
cat > "$LIVE/etc/config/network" <<'EOF'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.168.80.1'
	option netmask '255.255.255.0'
EOF
cp -a "$LIVE/etc/config/network" "$SNAP_SRC-pre" 2>/dev/null || true

# Source archive: a DIFFERENT network config (would move the router).
cat > "$ARCHIVE_TREE/glinet-crossmodel/uci/network" <<'EOF'
config interface 'lan'
	option proto 'static'
	option ipaddr '10.99.99.1'
	option netmask '255.255.255.0'
EOF
printf '{"format":"glinet-crossmodel/v2","format_version":2,"tool_version":"2.0.0","backup_strategy":"clone","profile_uuid":"22222222-2222-2222-2222-222222222222","profile_name":"Clone fixture","notes":"","source_model":"Test-Router","firmware_version":"4.8.2","openwrt_version":"23.05","architecture":"test-arch","kernel_version":"6.6","device_fingerprint":""}\n' > "$ARCHIVE_TREE/glinet-crossmodel/manifest.json"
printf 'clone fixture\n' > "$ARCHIVE_TREE/glinet-crossmodel/backup-info.txt"
printf '{}\n' > "$ARCHIVE_TREE/glinet-crossmodel/packages.json"
ARCHIVE="$TEST_ROOT/clone.tar.gz"
make_v2 "$ARCHIVE" "$ARCHIVE_TREE"

hash_tree() {
  (cd "$1" && find . -type f | sort | while IFS= read -r f; do sha256sum "$f"; done)
}

# Pre-state hash (the sandbox "live" tree doubles as the rollback target).
export GCM_LIVE_ROOT="$LIVE"
export GCM_CONFIG_TARGET_ROOT="$TARGET_ROOT"
export GCM_ROLLBACK_TARGET_ROOT="$TARGET_ROOT"
export GCM_UCI_DELTA_DIR="$TEST_ROOT/uci-delta"
export GCM_MOCK_UCI_LOG="$TEST_ROOT/uci.log"
mkdir -p "$TARGET_ROOT/etc/config" "$TEST_ROOT/uci-delta"
cp -a "$LIVE/etc/config/network" "$TARGET_ROOT/etc/config/network"
: > "$GCM_MOCK_UCI_LOG"

PRE_HASH=$(hash_tree "$TARGET_ROOT")

# ---- Control: without an injected failure the restore applies and changes the
# target (proves the apply path is not vacuous). ----
control_out=$(GCM_ACTION=restore GCM_COMPONENT=restore gcm_restore "$ARCHIVE" lan '' 0 0 0 0 2>/dev/null) || true
printf '%s\n' "$control_out" | grep -Fq 'RESTORE=success' || { echo 'control restore did not succeed' >&2; exit 1; }
grep -Fq '10.99.99.1' "$TARGET_ROOT/etc/config/network" || { echo 'control restore must have applied the source config' >&2; exit 1; }
ok 'control: restore without failure applies the source network config'

# Reset the target to pre-state for the failure run.
cp -a "$LIVE/etc/config/network" "$TARGET_ROOT/etc/config/network"
: > "$GCM_MOCK_UCI_LOG"

# ---- Injected failure: uci commit of network fails mid-apply. ----
fail_out=$(GCM_MOCK_UCI_FAIL_ON='commit network' GCM_ACTION=restore GCM_COMPONENT=restore \
  gcm_restore "$ARCHIVE" lan '' 0 0 0 0 2>/dev/null) || true

printf '%s\n' "$fail_out" | grep -Fq 'RESTORE=failed;attempting-rollback' || { echo 'restore must report failure and attempt rollback' >&2; exit 1; }
printf '%s\n' "$fail_out" | grep -Fq 'ROLLBACK=verified:all-snapshot-files-restored' || { echo 'rollback must verify' >&2; exit 1; }
ok 'injected mid-apply failure triggers automatic verified rollback'

POST_HASH=$(hash_tree "$TARGET_ROOT")
[ "$PRE_HASH" = "$POST_HASH" ] || { echo 'target tree hash changed across rollback' >&2; echo "PRE:$PRE_HASH" >&2; echo "POST:$POST_HASH" >&2; exit 1; }
ok 'post-rollback target tree is byte-identical to pre-state (SHA-256 verified)'

grep -Fq '10.99.99.1' "$TARGET_ROOT/etc/config/network" && { echo 'source config must not survive rollback' >&2; exit 1; }
grep -Fq '192.168.80.1' "$TARGET_ROOT/etc/config/network" || { echo 'pre-state config must be restored' >&2; exit 1; }
ok 'pre-state LAN config is restored byte-for-byte'

# ---- Rollback-integrity failure is surfaced loudly. ----
# Corrupt the snapshot checksum and prove rollback FAILS (never silent).
BROKEN_SNAPSHOT="$TEST_ROOT/snapshot-broken"
rm -rf "$BROKEN_SNAPSHOT"
mkdir -p "$BROKEN_SNAPSHOT/glinet-crossmodel-rollback/etc/config"
cp -a "$LIVE/etc/config/network" "$BROKEN_SNAPSHOT/glinet-crossmodel-rollback/etc/config/network"
printf '%064d  glinet-crossmodel-rollback/etc/config/network\n' 0 > "$BROKEN_SNAPSHOT/glinet-crossmodel-rollback/checksums.sha256"
broken_out=$(GCM_ROLLBACK_TARGET_ROOT="$TARGET_ROOT" gcm_rollback_snapshot "$BROKEN_SNAPSHOT" 2>/dev/null) || true
printf '%s\n' "$broken_out" | grep -Fq 'ROLLBACK=failed:' || { echo 'corrupt snapshot rollback must fail loudly' >&2; exit 1; }
ok 'rollback integrity failure is surfaced as ROLLBACK=failed'

echo "rollback failure-injection tests passed ($PASS checks)"
