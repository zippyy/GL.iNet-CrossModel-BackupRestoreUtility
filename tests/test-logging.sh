#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CORE="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/glinet-crossmodel/core.sh"
CLI="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/bin/glinet-crossmodel"
TEST_ROOT=$(mktemp -d /tmp/gcm-logging.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
NODE_BIN=$(command -v node)

export GCM_LOG_DIR="$TEST_ROOT/logs" GCM_LOG_FILE="$TEST_ROOT/logs/gcm.log"
export GCM_FILE_LOG=1 GCM_SYSLOG=0 GCM_LOG_LEVEL=trace
. "$CORE"

GCM_OP_ID=11111111-1111-1111-1111-111111111111
GCM_COMPONENT=test
gcm_diag INFO 'stage=redaction' 'password=TEST-PASSWORD-DO-NOT-LOG' 'private_key=TEST-PRIVATE-KEY-DO-NOT-LOG' 'token=TEST-TOKEN-DO-NOT-LOG' 'safe_value=visible'
grep -Fq 'safe_value="visible"' "$GCM_LOG_FILE"
grep -Fq '[REDACTED]' "$GCM_LOG_FILE"
if grep -Eq 'TEST-PASSWORD-DO-NOT-LOG|TEST-PRIVATE-KEY-DO-NOT-LOG|TEST-TOKEN-DO-NOT-LOG' "$GCM_LOG_FILE"; then
	echo 'Secret redaction test failed.' >&2; exit 1
fi
GCM_EFFECTIVE_MAX_LOG_KB=64
dd if=/dev/zero bs=1024 count=65 2>/dev/null | tr '\000' x > "$GCM_LOG_FILE"
gcm_diag INFO 'stage=rotation' 'result=success'
[ -f "$GCM_LOG_FILE.1" ]
[ "$(wc -c < "$GCM_LOG_FILE" | tr -d ' ')" -lt 65536 ]

empty="$TEST_ROOT/empty.list"
: > "$empty"
portable="$TEST_ROOT/portable.tar.gz"
clone="$TEST_ROOT/clone.tar.gz"
GCM_LIB="$CORE" sh "$CLI" create --output "$portable" --strategy portable --name 'JSON safety portable' --categories packages --scripts-list "$empty" --binaries-list "$empty" >/dev/null
GCM_LIB="$CORE" sh "$CLI" create --output "$clone" --strategy clone --name 'JSON safety clone' --categories packages --scripts-list "$empty" --binaries-list "$empty" >/dev/null

GCM_LIB="$CORE" sh "$CLI" facts > "$TEST_ROOT/facts.json"
GCM_LIB="$CORE" sh "$CLI" inspect "$portable" > "$TEST_ROOT/inspect.json"
GCM_LIB="$CORE" sh "$CLI" validate "$portable" --categories packages > "$TEST_ROOT/validate.json"
GCM_LIB="$CORE" sh "$CLI" packages "$portable" > "$TEST_ROOT/packages.json"

"$NODE_BIN" -e 'const fs=require("fs"); for (const f of process.argv.slice(1)) JSON.parse(fs.readFileSync(f,"utf8"));' \
	"$TEST_ROOT/facts.json" "$TEST_ROOT/inspect.json" "$TEST_ROOT/validate.json" "$TEST_ROOT/packages.json"

# Exercise success and failure restore control flow without writing host state.
gcm_pre_restore_snapshot() { snapshot_root="$TEST_ROOT/mock-snapshot"; mkdir -p "$snapshot_root"; printf '%s\n' "$snapshot_root"; }
GCM_ACTION=restore GCM_COMPONENT=restore GCM_OP_ID=22222222-2222-2222-2222-222222222222
restore_output=$(gcm_restore "$portable" packages '' 0 0 0)
printf '%s\n' "$restore_output" | grep -Fq 'RESTORE=success'

gcm_apply_portable_wifi() { return 1; }
gcm_rollback_snapshot() { gcm_diag INFO 'action=rollback' 'stage=verification' 'result=success'; return 0; }
if gcm_restore "$portable" wifi '' 0 0 0 >/dev/null 2>&1; then
	echo 'Injected failed restore unexpectedly succeeded.' >&2; exit 1
fi
grep -Fq 'rollback_result="success"' "$GCM_LOG_FILE"

if GCM_LIB="$CORE" sh "$CLI" restore "$TEST_ROOT/missing.tar.gz" --categories packages >/dev/null 2>&1; then
	echo 'Missing-archive restore unexpectedly succeeded.' >&2; exit 1
fi

echo 'logging, redaction, JSON stdout, create, restore, and rollback tests passed'
