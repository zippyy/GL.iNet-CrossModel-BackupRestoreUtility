# Shared harness for native-engine tests.
# Sources the VENDORED canonical runtime (runtime/native/core.sh) with sandbox
# roots so no test can touch a live tree. Mirrors the harness methodology used
# by main's own tests (tests/test-core.sh, tests/test-preserve-lan-ip.sh).
#
# IMPORTANT: this file does NOT source core.sh. Tests that need a mock uci on
# PATH must call gcm_mock_uci_install() BEFORE `. "$CORE"` so core.sh's PATH
# assignment picks up the mock directory.
#
# Usage:
#   . "$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)/test/harness.sh"
#   gcm_mock_uci_install          # optional
#   . "$CORE"

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CORE="$ROOT/runtime/native/core.sh"
CLI="$ROOT/runtime/native/glinet-crossmodel"

TEST_ROOT=$(mktemp -d /tmp/gcm-docker-native.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
PASS=0

ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$PASS" "$1"; }
fail() { printf 'not ok %s - %s\n' "$((PASS + 1))" "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected [$2], got [$1])"; ok "$3"; }
assert_true() { "$@" || fail "$*"; ok "$*"; }
assert_false() { if "$@"; then fail "$*"; fi; ok "rejects: $*"; }

# Sandbox roots (mirrors the GCM_* overrides main's tests set).
export GCM_LOG_DIR="$TEST_ROOT/logs"
export GCM_LOG_FILE="$TEST_ROOT/logs/gcm.log"
export GCM_FILE_LOG=1
export GCM_SYSLOG=0
export GCM_LOG_LEVEL="${GCM_LOG_LEVEL:-info}"
mkdir -p "$GCM_LOG_DIR"

# Recording mock uci. State-changing calls are logged; `-c DIR` reads answer
# from a profile fixture when present (same shape as main's preserve test).
gcm_mock_uci_install() {
  mock_bin="$TEST_ROOT/bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/uci" <<'EOF'
#!/bin/sh
[ -n "${GCM_MOCK_UCI_LOG:-}" ] && printf '%s\n' "$*" >> "$GCM_MOCK_UCI_LOG"
config_dir=''
operation=''
subject=''
previous=''
for argument in "$@"; do
  case "$argument" in
    -c) previous=-c ;;
    -q) previous=-q ;;
    show|get|set|commit|add|delete|add_list|import|export|revert) operation=$argument; previous=$argument ;;
    *)
      if [ "$previous" = -c ]; then config_dir=$argument
      elif [ "$operation" = get ] && [ -z "$subject" ]; then subject=$argument
      fi
      previous=$argument
      ;;
  esac
done
# Injection hook: GCM_MOCK_UCI_FAIL_ON contains a substring; when it matches the
# full invocation the mock fails with the configured exit code.
if [ -n "${GCM_MOCK_UCI_FAIL_ON:-}" ] && printf '%s' "$*" | grep -q "$GCM_MOCK_UCI_FAIL_ON"; then
  exit "${GCM_MOCK_UCI_FAIL_CODE:-1}"
fi
case "$operation:$subject" in
  get:network.lan.ipaddr) printf '%s\n' "${GCM_MOCK_LAN_IP:-}"; exit 0 ;;
  get:network.lan) printf 'lan\n'; exit 0 ;;
esac
if [ "$operation" = show ] && [ -n "$config_dir" ] && [ -f "$config_dir/profile" ]; then
  awk '/^[[:space:]]*config[[:space:]]+/ { n++; rest=$0; sub(/^[[:space:]]*config[[:space:]]+/, "", rest); type=rest; sub(/[[:space:]].*/, "", type); printf "profile.cfg%d=%s\n", n, type }' "$config_dir/profile"
  exit 0
fi
if [ "$operation" = get ] && [ -n "$config_dir" ] && [ -f "$config_dir/profile" ]; then
  section=${subject%.*}; option=${subject##*.}
  case "$section" in
    profile.cfg[0-9]*)
      index=${section#profile.cfg}
      awk -v idx="$index" -v wanted="$option" '
        /^[[:space:]]*config[[:space:]]+/ { n++; in_sec = (n == idx); next }
        in_sec && $1 == "option" && $2 == wanted { sub(/^[[:space:]]*option[[:space:]]+[^[:space:]]+[[:space:]]+/, ""); print; exit }
      ' "$config_dir/profile" | tr -d "'\""
      exit 0 ;;
  esac
fi
# export: emit the config file content when one exists at the recorded path.
if [ "$operation" = export ]; then
  pkg=$subject
  # no-op export (empty) is valid for missing packages; callers test existence first.
  exit 0
fi
exit 0
EOF
  chmod +x "$mock_bin/uci"
  export GCM_PATH="$mock_bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export GCM_MOCK_UCI_LOG="$TEST_ROOT/uci.log"
  : > "$GCM_MOCK_UCI_LOG"
}

# Build a valid v2 archive from an on-disk glinet-crossmodel tree.
make_v2() {
  archive=$1; tree=$2
  (cd "$tree" && find glinet-crossmodel -type f ! -name checksums.sha256 | sort | while IFS= read -r p; do sha256sum "$p"; done > glinet-crossmodel/checksums.sha256)
  tar -C "$tree" -czf "$archive" glinet-crossmodel
}

# Minimal valid v2 manifest fixture writer.
write_manifest() {
  tree=$1; strategy=$2; model=$3; version=$4; fingerprint=${5:-}
  mkdir -p "$tree/glinet-crossmodel/source"
  printf '{"format":"glinet-crossmodel/v2","format_version":%s,"tool_version":"2.0.0","backup_strategy":"%s","profile_uuid":"11111111-1111-1111-1111-111111111111","profile_name":"Fixture","notes":"","source_model":"%s","firmware_version":"4.8.2","openwrt_version":"23.05","architecture":"test-arch","kernel_version":"6.6","device_fingerprint":"%s"}\n' \
    "$version" "$strategy" "$model" "$fingerprint" > "$tree/glinet-crossmodel/manifest.json"
  printf 'fixture\n' > "$tree/glinet-crossmodel/backup-info.txt"
  printf '{}\n' > "$tree/glinet-crossmodel/packages.json"
}
