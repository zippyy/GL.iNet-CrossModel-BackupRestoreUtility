#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CORE="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/glinet-crossmodel/core.sh"
CLI="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/bin/glinet-crossmodel"
REMOTE="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/libexec/glinet-crossmodel-remote"
TEST_ROOT=$(mktemp -d /tmp/gcm-remote-logging.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
NODE_BIN=$(command -v node)
MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN" "$TEST_ROOT/logs"

printf '%s\n' '#!/bin/sh' 'shift 2' 'exec "$@"' > "$MOCK_BIN/sshpass"
printf '%s\n' '#!/bin/sh' \
	'previous=""; last=""' \
	'for argument in "$@"; do previous=$last; last=$argument; done' \
	'if [ "${GCM_FAKE_AUTH_FAILURE:-0}" = 1 ]; then echo "Permission denied (publickey,password)." >&2; exit 255; fi' \
	'if [ "${GCM_FAKE_HOST_MISMATCH:-0}" = 1 ]; then echo "REMOTE HOST IDENTIFICATION HAS CHANGED" >&2; exit 255; fi' \
	'if [ "${GCM_FAKE_CHECKSUM_MISMATCH:-0}" = 1 ] && printf "%s" "$last" | grep -q sha256sum; then printf "%064d  fake\n" 0; exit 0; fi' \
	'if [ "${GCM_FAKE_SKIP_RESTORE:-0}" = 1 ] && printf "%s" "$last" | grep -q "sh -s --.*restore"; then printf "RESTORE=success\n"; exit 0; fi' \
	'exec sh -c "$last"' > "$MOCK_BIN/ssh"
printf '%s\n' '#!/bin/sh' \
	'if [ "${GCM_FAKE_SCP_FAILURE:-0}" = 1 ]; then echo "scp: /tmp/remote: No space left on device" >&2; exit 1; fi' \
	'previous=""; last=""' \
	'for argument in "$@"; do previous=$last; last=$argument; done' \
	'case "$previous" in *:*) previous=${previous#*:} ;; esac' \
	'case "$last" in *:*) last=${last#*:} ;; esac' \
	'cp "$previous" "$last"' > "$MOCK_BIN/scp"
chmod 755 "$MOCK_BIN/sshpass" "$MOCK_BIN/ssh" "$MOCK_BIN/scp"

empty="$TEST_ROOT/empty.list"; password_file="$TEST_ROOT/password"; key_file="$TEST_ROOT/id_test"
: > "$empty"; printf '%s\n' 'TEST-REMOTE-PASSWORD-DO-NOT-LOG' > "$password_file"; printf '%s\n' 'TEST-PRIVATE-KEY-CONTENT-DO-NOT-LOG' > "$key_file"
chmod 600 "$empty" "$password_file" "$key_file"

export GCM_CORE="$CORE" GCM_CLI="$CLI" GCM_KNOWN_HOSTS="$TEST_ROOT/known_hosts"
export GCM_PATH="$MOCK_BIN:/usr/sbin:/usr/bin:/sbin:/bin"
export GCM_LOG_DIR="$TEST_ROOT/logs" GCM_LOG_FILE="$TEST_ROOT/logs/gcm.log" GCM_FILE_LOG=1 GCM_SYSLOG=0 GCM_LOG_LEVEL=debug
: > "$GCM_KNOWN_HOSTS"; chmod 600 "$GCM_KNOWN_HOSTS"

for auth in password key agent; do
	case "$auth" in password) credential=$password_file ;; key) credential=$key_file ;; agent) credential=- ;; esac
	sh "$REMOTE" facts 127.0.0.1 22 root "$auth" "$credential" > "$TEST_ROOT/facts-$auth.json"
	"$NODE_BIN" -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$TEST_ROOT/facts-$auth.json"
done

operation_id=33333333-3333-3333-3333-333333333333
archive="$TEST_ROOT/remote.tar.gz"
sh "$REMOTE" create "$archive" portable "$operation_id" 'Remote test' 'Mock agentless endpoint' packages "$empty" "$empty" 127.0.0.1 22 root key "$key_file" >/dev/null
sh "$REMOTE" validate "$archive" "$operation_id" packages 0 0 127.0.0.1 22 root agent - > "$TEST_ROOT/remote-validate.json"
sh "$REMOTE" packages "$archive" "$operation_id" 127.0.0.1 22 root key "$key_file" > "$TEST_ROOT/remote-packages.json"
"$NODE_BIN" -e 'const fs=require("fs"); JSON.parse(fs.readFileSync(process.argv[1],"utf8")); JSON.parse(fs.readFileSync(process.argv[2],"utf8"));' "$TEST_ROOT/remote-validate.json" "$TEST_ROOT/remote-packages.json"
GCM_FAKE_SKIP_RESTORE=1 sh "$REMOTE" restore "$archive" "$operation_id" packages '' 0 0 0 0 127.0.0.1 22 root agent - >/dev/null

if GCM_FAKE_AUTH_FAILURE=1 sh "$REMOTE" facts 127.0.0.1 22 root agent - >/dev/null 2>&1; then echo 'Mock authentication failure unexpectedly succeeded.' >&2; exit 1; fi
if GCM_FAKE_HOST_MISMATCH=1 sh "$REMOTE" facts 127.0.0.1 22 root agent - >/dev/null 2>&1; then echo 'Mock host fingerprint mismatch unexpectedly succeeded.' >&2; exit 1; fi
if GCM_FAKE_SCP_FAILURE=1 sh "$REMOTE" validate "$archive" "$operation_id" packages 0 0 127.0.0.1 22 root agent - >/dev/null 2>&1; then echo 'Mock SCP failure unexpectedly succeeded.' >&2; exit 1; fi
if GCM_FAKE_CHECKSUM_MISMATCH=1 sh "$REMOTE" validate "$archive" "$operation_id" packages 0 0 127.0.0.1 22 root agent - >/dev/null 2>&1; then echo 'Mock checksum mismatch unexpectedly succeeded.' >&2; exit 1; fi

GCM_REMOTE_LIBRARY_ONLY=1 . "$REMOTE"
[ "$(classify_ssh_error 'Connection timed out')" = timeout ]
[ "$(classify_ssh_error 'Could not resolve hostname router')" = dns-failure ]
[ "$(classify_ssh_error 'No route to host')" = host-unreachable ]
[ "$(classify_ssh_error 'Connection refused')" = connection-refused ]
[ "$(classify_ssh_error 'REMOTE HOST IDENTIFICATION HAS CHANGED')" = changed-host-key ]
[ "$(classify_ssh_error 'Permission denied (publickey,password)')" = authentication-failure ]

grep -Fq 'reason="authentication-failure"' "$GCM_LOG_FILE"
grep -Fq 'reason="changed-host-key"' "$GCM_LOG_FILE"
grep -Fq 'reason="remote-disk-full"' "$GCM_LOG_FILE"
grep -Fq 'reason="checksum-mismatch"' "$GCM_LOG_FILE"
grep -Fq 'op=33333333-3333-3333-3333-333333333333 component=remote scope=remote' "$GCM_LOG_FILE"
if grep -Eq 'TEST-REMOTE-PASSWORD-DO-NOT-LOG|TEST-PRIVATE-KEY-CONTENT-DO-NOT-LOG' "$GCM_LOG_FILE"; then echo 'Remote credential contents leaked into diagnostics.' >&2; exit 1; fi

echo 'remote auth, create, validate, restore, packages, failures, checksums, cleanup, JSON, and secret tests passed'
