#!/bin/sh
# Regression tests for the destination LAN IP preservation restore policy
# (--preserve-destination-lan-ip / preserve_destination_lan_ip).
#
# Every assertion runs host-side without OpenWrt tooling: a recording mock uci
# answers network.lan.ipaddr from GCM_MOCK_LAN_IP, sandbox roots
# (GCM_CONFIG_TARGET_ROOT / GCM_STAGED_ROOT) keep raw-UCI strategy applies
# deterministic, and the portable LAN apply is observed through a recording
# adapter shim so no live /etc/config is ever touched.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CORE="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/glinet-crossmodel/core.sh"
CLI="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/bin/glinet-crossmodel"

TEST_ROOT=$(mktemp -d /tmp/gcm-preserve.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
PASS=0
ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$PASS" "$1"; }
fail() { printf 'not ok %s - %s\n' "$((PASS + 1))" "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected $2, got $1)"; ok "$3"; }

NODE_BIN=$(command -v node)
MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN" "$TEST_ROOT/logs" "$TEST_ROOT/staged"

cat > "$MOCK_BIN/uci" <<'EOF'
#!/bin/sh
# Recording mock uci:
#  - live reads of network.lan.ipaddr answer from GCM_MOCK_LAN_IP;
#  - `-c DIR show profile` / `-c DIR get profile.cfgN.option` answer from the
#    UCI-format fixture file at DIR/profile, so the real core.sh profile
#    readers (gcm_profile_sections / gcm_profile_get) run against the fixture;
#  - every state-changing invocation is a logged no-op.
[ -n "${GCM_MOCK_UCI_LOG:-}" ] && printf '%s\n' "$*" >> "$GCM_MOCK_UCI_LOG"
config_dir=''
operation=''
subject=''
previous=''
for argument in "$@"; do
	case "$argument" in
		-c) previous=-c ;;
		-q) previous=-q ;;
		show|get|set|commit|add|delete|add_list) operation=$argument; previous=$argument ;;
		*)
			if [ "$previous" = -c ]; then config_dir=$argument
			elif [ "$operation" = get ] && [ -z "$subject" ]; then subject=$argument
			fi
			previous=$argument
			;;
	esac
done
case "$operation:$subject" in
	get:network.lan.ipaddr)
		printf '%s\n' "${GCM_MOCK_LAN_IP:-}"
		exit 0
		;;
	get:network.lan)
		printf 'lan\n'
		exit 0
		;;
esac
# `-c DIR show profile` and `-c DIR get profile.cfgN.option` are answered from
# the fixture file; any other show/get without a -c config dir is a no-op.
if [ "$operation" = show ] && [ -n "$config_dir" ] && [ -f "$config_dir/profile" ]; then
	awk '
		/^[[:space:]]*config[[:space:]]+/ {
			n++
			rest = $0
			sub(/^[[:space:]]*config[[:space:]]+/, "", rest)
			type = rest
			sub(/[[:space:]].*/, "", type)
			printf "profile.cfg%d=%s\n", n, type
		}
	' "$config_dir/profile"
	exit 0
fi
if [ "$operation" = get ] && [ -n "$config_dir" ] && [ -f "$config_dir/profile" ]; then
	section=${subject%.*}
	option=${subject##*.}
	case "$section" in
		profile.cfg[0-9]*)
			index=${section#profile.cfg}
			value=$(awk -v idx="$index" -v wanted="$option" '
				/^[[:space:]]*config[[:space:]]+/ { n++; in_sec = (n == idx); next }
				in_sec && $1 == "option" && $2 == wanted {
					sub(/^[[:space:]]*option[[:space:]]+[^[:space:]]+[[:space:]]+/, "")
					print
					exit
				}
			' "$config_dir/profile")
			printf '%s\n' "$value" | tr -d "'\""
			exit 0
			;;
	esac
fi
exit 0
EOF
chmod +x "$MOCK_BIN/uci"
: > "$TEST_ROOT/uci.log"

export GCM_PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export GCM_MOCK_UCI_LOG="$TEST_ROOT/uci.log"
export GCM_LOG_DIR="$TEST_ROOT/logs" GCM_LOG_FILE="$TEST_ROOT/logs/gcm.log"
export GCM_FILE_LOG=1 GCM_SYSLOG=0 GCM_LOG_LEVEL=info
# shellcheck source=/dev/null
. "$CORE"

# --- IPv4 validation -------------------------------------------------------
assert_eq "$(gcm_valid_ipv4 192.168.80.1 && printf yes || printf no)" yes 'accepts valid IPv4'
assert_eq "$(gcm_valid_ipv4 10.0.0.1 && printf yes || printf no)" yes 'accepts 10.0.0.1'
assert_eq "$(gcm_valid_ipv4 '' && printf yes || printf no)" no 'rejects empty IPv4'
assert_eq "$(gcm_valid_ipv4 192.168.1 && printf yes || printf no)" no 'rejects three-octet IPv4'
assert_eq "$(gcm_valid_ipv4 192.168.1.1.1 && printf yes || printf no)" no 'rejects five-octet IPv4'
assert_eq "$(gcm_valid_ipv4 300.1.1.1 && printf yes || printf no)" no 'rejects out-of-range octet'
assert_eq "$(gcm_valid_ipv4 192.168.1.256 && printf yes || printf no)" no 'rejects 256 octet'
assert_eq "$(gcm_valid_ipv4 abc && printf yes || printf no)" no 'rejects hostname text'
assert_eq "$(gcm_valid_ipv4 192.168.1.x && printf yes || printf no)" no 'rejects alpha octet'
assert_eq "$(gcm_valid_ipv4 ' 192.168.1.1' && printf yes || printf no)" no 'rejects leading whitespace'
assert_eq "$(gcm_valid_ipv4 '192.168.1.1 ' && printf yes || printf no)" no 'rejects trailing whitespace'

# --- Raw UCI file parser and single-option rewrite --------------------------
rewrite_dir="$TEST_ROOT/rewrite"
mkdir -p "$rewrite_dir"
cat > "$rewrite_dir/network" <<'EOF'
config interface 'loopback'
	option ifname 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'

config interface 'lan'
	option type 'bridge'
	option proto 'static'
	option ipaddr '192.168.8.1'
	option netmask '255.255.255.0'

config interface 'lan2'
	option proto 'static'
	option ipaddr '10.9.9.1'
EOF
assert_eq "$(gcm_file_lan_ipaddr "$rewrite_dir/network")" '192.168.8.1' 'reads backup LAN IP from raw network file'
assert_eq "$(gcm_uci_file_option "$rewrite_dir/network" interface lan2 ipaddr)" '10.9.9.1' 'reads secondary interface option'
gcm_file_force_lan_ipaddr "$rewrite_dir/network" 192.168.80.1 || fail 'force rewrites primary lan ipaddr'
ok 'force rewrites primary lan ipaddr'
assert_eq "$(gcm_file_lan_ipaddr "$rewrite_dir/network")" '192.168.80.1' 'force replaces backup LAN IP with preserved destination'
assert_eq "$(gcm_uci_file_option "$rewrite_dir/network" interface lan2 ipaddr)" '10.9.9.1' 'force leaves secondary interface untouched'
assert_eq "$(gcm_uci_file_option "$rewrite_dir/network" interface loopback ipaddr)" '127.0.0.1' 'force leaves loopback untouched'
assert_eq "$(gcm_uci_file_option "$rewrite_dir/network" interface lan netmask)" '255.255.255.0' 'force leaves netmask untouched'
cat > "$rewrite_dir/network-no-ip" <<'EOF'
config interface 'lan'
	option type 'bridge'
	option proto 'static'
	option netmask '255.255.255.0'
EOF
gcm_file_force_lan_ipaddr "$rewrite_dir/network-no-ip" 192.168.80.1 || fail 'force inserts ipaddr when the LAN section has none'
ok 'force inserts ipaddr when the LAN section has none'
assert_eq "$(gcm_file_lan_ipaddr "$rewrite_dir/network-no-ip")" '192.168.80.1' 'inserted ipaddr is the preserved destination'
cat > "$rewrite_dir/network-no-lan" <<'EOF'
config interface 'wan'
	option proto 'dhcp'
	option ifname 'eth1'
EOF
# The suite runs under `set -eu`; a bare failing awk followed by rc=$? would
# have terminated this script before the helper could return. The guarded
# form must propagate the nonzero status without killing the caller.
if gcm_file_force_lan_ipaddr "$rewrite_dir/network-no-lan" 192.168.80.1 >/dev/null 2>&1; then fail 'force fails when no lan section exists'; else ok 'force fails when no lan section exists (set -e safe nonzero path)'; fi
if gcm_file_force_lan_ipaddr "$rewrite_dir/missing-file" 192.168.80.1 >/dev/null 2>&1; then fail 'force fails when the file is missing'; else ok 'force fails when the file is missing'; fi

# --- Subnet relationship helper ---------------------------------------------
if gcm_ipv4_same_subnet 192.168.80.50 192.168.80.1 255.255.255.0; then ok 'detects same-subnet addresses'; else fail 'detects same-subnet addresses'; fi
if gcm_ipv4_same_subnet 192.168.8.50 192.168.80.1 255.255.255.0; then fail 'detects cross-subnet addresses'; else ok 'detects cross-subnet addresses'; fi

# --- Capture policy -----------------------------------------------------------
export GCM_MOCK_LAN_IP=192.168.80.1
GCM_DESTINATION_LAN_IP=''
if gcm_capture_destination_lan_ip; then assert_eq "$GCM_DESTINATION_LAN_IP" '192.168.80.1' 'captures the target LAN IP'; else fail 'captures the target LAN IP'; fi
export GCM_MOCK_LAN_IP=''
if gcm_capture_destination_lan_ip >/dev/null 2>&1; then fail 'capture rejects a missing target LAN IP'; else ok 'capture rejects a missing target LAN IP'; fi
export GCM_MOCK_LAN_IP=not-an-ip
if gcm_capture_destination_lan_ip >/dev/null 2>&1; then fail 'capture rejects an invalid target LAN IP'; else ok 'capture rejects an invalid target LAN IP'; fi
export GCM_MOCK_LAN_IP=300.1.1.1
if gcm_capture_destination_lan_ip >/dev/null 2>&1; then fail 'capture rejects an out-of-range target LAN IP'; else ok 'capture rejects an out-of-range target LAN IP'; fi
export GCM_MOCK_LAN_IP='192.168.80.1 '
if gcm_capture_destination_lan_ip; then assert_eq "$GCM_DESTINATION_LAN_IP" '192.168.80.1' 'capture trims surrounding whitespace'; else fail 'capture trims surrounding whitespace'; fi

# --- Raw-UCI enforcement: clone, snapshot, remote-safe ------------------------
# Pristine backup fixture: the source LAN address is 192.168.8.1. (The rewrite
# fixture above was deliberately mutated by the force tests, so it cannot be
# reused as the backup input here.)
raw_src="$TEST_ROOT/raw-uci"
mkdir -p "$raw_src"
cat > "$raw_src/network" <<'EOF'
config interface 'loopback'
	option ifname 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'

config interface 'lan'
	option type 'bridge'
	option proto 'static'
	option ipaddr '192.168.8.1'
	option netmask '255.255.255.0'

config interface 'lan2'
	option proto 'static'
	option ipaddr '10.9.9.1'
EOF
assert_eq "$(gcm_file_lan_ipaddr "$raw_src/network")" '192.168.8.1' 'raw-UCI backup fixture carries the source LAN IP'

clone_dest="$TEST_ROOT/clone-dest"
rm -rf "$clone_dest"; mkdir -p "$clone_dest/etc/config"
GCM_PRESERVE_DESTINATION_LAN_IP=1 GCM_DESTINATION_LAN_IP=192.168.80.1 GCM_CONFIG_TARGET_ROOT="$clone_dest" gcm_apply_raw_uci "$raw_src" clone lan >/dev/null 2>&1
assert_eq "$(gcm_file_lan_ipaddr "$clone_dest/etc/config/network")" '192.168.80.1' 'clone restores the preserved destination LAN IP'
grep -Fq 'set network.lan.ipaddr' "$GCM_MOCK_UCI_LOG" && { echo 'clone path issued an intermediate uci set for the backup IP' >&2; exit 1; }
grep -Fq 'stage="preserve-lan-ip"' "$GCM_LOG_FILE" || { echo 'clone enforcement diagnostic missing' >&2; exit 1; }
grep -Fq 'result="preserved"' "$GCM_LOG_FILE" || { echo 'clone enforcement result diagnostic missing' >&2; exit 1; }
ok 'clone enforces preservation before commit without intermediate IP set'

rm -rf "$clone_dest"; mkdir -p "$clone_dest/etc/config"
GCM_PRESERVE_DESTINATION_LAN_IP=0 GCM_DESTINATION_LAN_IP='' GCM_CONFIG_TARGET_ROOT="$clone_dest" gcm_apply_raw_uci "$raw_src" clone lan >/dev/null 2>&1
assert_eq "$(gcm_file_lan_ipaddr "$clone_dest/etc/config/network")" '192.168.8.1' 'clone with preservation disabled applies the backup LAN IP'

snap_dest="$TEST_ROOT/snap-dest"
rm -rf "$snap_dest"; mkdir -p "$snap_dest/etc/config"
GCM_PRESERVE_DESTINATION_LAN_IP=1 GCM_DESTINATION_LAN_IP=192.168.80.1 GCM_CONFIG_TARGET_ROOT="$snap_dest" gcm_apply_raw_uci "$raw_src" snapshot lan >/dev/null 2>&1
assert_eq "$(gcm_file_lan_ipaddr "$snap_dest/etc/config/network")" '192.168.80.1' 'snapshot restores the preserved destination LAN IP even under whole-file replacement'

remote_stage="$TEST_ROOT/staged/remote-safe"
rm -rf "$remote_stage"; mkdir -p "$remote_stage" "$TEST_ROOT/rs-dest/etc/config"
SSH_CONNECTION='10.10.0.2 22 10.10.0.2 22' GCM_PRESERVE_DESTINATION_LAN_IP=1 GCM_DESTINATION_LAN_IP=192.168.80.1 GCM_STAGED_ROOT="$remote_stage" GCM_CONFIG_TARGET_ROOT="$TEST_ROOT/rs-dest" gcm_apply_raw_uci "$raw_src" remote-safe lan >/dev/null 2>&1
assert_eq "$(gcm_file_lan_ipaddr "$remote_stage/network")" '192.168.80.1' 'remote-safe stages the preserved destination LAN IP'
if [ -f "$TEST_ROOT/rs-dest/etc/config/network" ]; then echo 'remote-safe over SSH must stage, not commit, the network package' >&2; exit 1; fi
ok 'remote-safe over SSH stages connectivity and never commits during restore'
unset SSH_CONNECTION

# --- Post-apply verification gate ---------------------------------------------
export GCM_PRESERVE_DESTINATION_LAN_IP=1 GCM_DESTINATION_LAN_IP=192.168.80.1 GCM_MOCK_LAN_IP=192.168.80.1
if gcm_verify_destination_lan_ip clone; then ok 'verification passes when the committed LAN IP matches the preserved value'; else fail 'verification passes when the committed LAN IP matches the preserved value'; fi
export GCM_MOCK_LAN_IP=192.168.8.1
if gcm_verify_destination_lan_ip clone >/dev/null 2>&1; then fail 'verification fails when the committed LAN IP lost the preserved value'; else ok 'verification fails when the committed LAN IP lost the preserved value'; fi
export GCM_PRESERVE_DESTINATION_LAN_IP=1 GCM_DESTINATION_LAN_IP='' GCM_MOCK_LAN_IP=''
if gcm_verify_destination_lan_ip clone; then ok 'verification no-ops when no destination IP was captured'; else fail 'verification no-ops when no destination IP was captured'; fi
export GCM_PRESERVE_DESTINATION_LAN_IP=0 GCM_DESTINATION_LAN_IP='' GCM_MOCK_LAN_IP=192.168.8.1
if gcm_verify_destination_lan_ip clone; then ok 'verification no-ops when preservation is disabled'; else fail 'verification no-ops when preservation is disabled'; fi
export GCM_PRESERVE_DESTINATION_LAN_IP=1 GCM_DESTINATION_LAN_IP=192.168.80.1 GCM_MOCK_LAN_IP=192.168.80.1
remote_stage2="$TEST_ROOT/staged/verify"
rm -rf "$remote_stage2"; mkdir -p "$remote_stage2"
cp "$raw_src/network" "$remote_stage2/network"
gcm_file_force_lan_ipaddr "$remote_stage2/network" 192.168.80.1
SSH_CONNECTION='10.10.0.2 22 10.10.0.2 22' GCM_STAGED_ROOT="$remote_stage2" gcm_verify_destination_lan_ip remote-safe >/dev/null 2>&1 || { echo 'remote-safe staged verification failed' >&2; exit 1; }
ok 'remote-safe verification inspects the staged network file'
unset SSH_CONNECTION
export GCM_PRESERVE_DESTINATION_LAN_IP=0

# --- Extra-tree duplicate network config ---------------------------------------
# A persistent extra member that carries its own copy of the network package
# (e.g. leftover keep.d behavior) must never reintroduce the backed-up LAN
# address after raw-UCI apply enforced the preserved address. The member is
# rewritten to the captured destination IP before installation, so the final
# committed state is correct without relying on the post-apply verification
# rollback path. Source and extra member both carry 192.168.8.1; the
# destination before restore is 192.168.80.1.
extra_tree="$TEST_ROOT/extra-tree"
rm -rf "$extra_tree"; mkdir -p "$extra_tree/etc/config"
cp "$raw_src/network" "$extra_tree/etc/config/network"
assert_eq "$(gcm_file_lan_ipaddr "$extra_tree/etc/config/network")" '192.168.8.1' 'extra-tree duplicate network fixture carries the source LAN IP'
extra_dest="$TEST_ROOT/extra-dest"
rm -rf "$extra_dest"; mkdir -p "$extra_dest/etc/config"
cp "$raw_src/network" "$extra_dest/etc/config/network"
gcm_file_force_lan_ipaddr "$extra_dest/etc/config/network" 192.168.80.1
assert_eq "$(gcm_file_lan_ipaddr "$extra_dest/etc/config/network")" '192.168.80.1' 'extra-tree destination baseline carries the preserved LAN IP'
# The apply leaf returns success while leaving the preserved address in
# place; no rollback layer exists below it, so a correct final state with a
# zero return proves the overwrite was prevented rather than detected after.
extra_out=$(GCM_PRESERVE_DESTINATION_LAN_IP=1 GCM_DESTINATION_LAN_IP=192.168.80.1 GCM_EXTRA_TARGET_ROOT="$extra_dest" gcm_apply_extra_tree "$extra_tree") || { echo 'extra-tree apply failed under preservation' >&2; exit 1; }
assert_eq "$(gcm_file_lan_ipaddr "$extra_dest/etc/config/network")" '192.168.80.1' 'preserve-enabled extra-tree duplicate network cannot overwrite the preserved destination LAN IP'
printf '%s\n' "$extra_out" | grep -Fq 'PRESERVED=persistent:' || { echo 'extra-tree rewrite stdout marker missing' >&2; exit 1; }
if printf '%s\n' "$extra_out" | grep -Fq 'SKIPPED=persistent:'; then echo 'extra-tree network member must be rewritten, not skipped' >&2; exit 1; fi
grep -Fq 'member="extra/etc/config/network"' "$GCM_LOG_FILE" || { echo 'extra-tree rewrite diagnostic missing' >&2; exit 1; }
grep -Fq 'result="preserved"' "$GCM_LOG_FILE" || { echo 'extra-tree preserved diagnostic missing' >&2; exit 1; }
ok 'extra-tree duplicate network member is rewritten to the preserved destination IP without rollback'
rm -rf "$extra_dest"; mkdir -p "$extra_dest/etc/config"
cp "$raw_src/network" "$extra_dest/etc/config/network"
gcm_file_force_lan_ipaddr "$extra_dest/etc/config/network" 192.168.80.1
extra_off=$(GCM_PRESERVE_DESTINATION_LAN_IP=0 GCM_DESTINATION_LAN_IP='' GCM_EXTRA_TARGET_ROOT="$extra_dest" gcm_apply_extra_tree "$extra_tree") || { echo 'extra-tree apply failed with preservation disabled' >&2; exit 1; }
assert_eq "$(gcm_file_lan_ipaddr "$extra_dest/etc/config/network")" '192.168.8.1' 'preservation-disabled extra-tree duplicate network keeps historical overwrite behavior'
printf '%s\n' "$extra_off" | grep -Fq 'APPLIED=persistent:' || { echo 'extra-tree apply marker missing when preservation is disabled' >&2; exit 1; }
ok 'extra-tree duplicate network applies the backup address when preservation is disabled'

# --- Portable archive fixtures -------------------------------------------------
build_portable() {
	archive=$1
	fixture=$2
	work="$TEST_ROOT/pkg-$(basename "$archive")"
	rm -rf "$work"
	mkdir -p "$work/glinet-crossmodel/portable" "$work/glinet-crossmodel/source"
	cp "$fixture" "$work/glinet-crossmodel/portable/profile"
	cat > "$work/glinet-crossmodel/manifest.json" <<'EOF'
{"format":"glinet-crossmodel/v2","format_version":2,"tool_version":"2.0.0","backup_strategy":"portable","profile_uuid":"44444444-4444-4444-4444-444444444444","profile_name":"Preserve fixture","notes":"","source_model":"Fixture","firmware_version":"4.8.2","openwrt_version":"23.05","architecture":"test-arch","kernel_version":"6.6","device_fingerprint":""}
EOF
	printf 'fixture\n' > "$work/glinet-crossmodel/backup-info.txt"
	printf '{}\n' > "$work/glinet-crossmodel/packages.json"
	(cd "$work" && find glinet-crossmodel -type f ! -name checksums.sha256 | sort | while IFS= read -r path; do sha256sum "$path"; done > glinet-crossmodel/checksums.sha256)
	tar -C "$work" -czf "$archive" glinet-crossmodel
}

cat > "$TEST_ROOT/profile-a" <<'EOF'
config lan
	option protocol 'static'
	option address '192.168.8.1'
	option netmask '255.255.255.0'
	option gateway '192.168.8.1'
config dhcp
	option start '100'
	option limit '150'
config reservation
	option name 'printer'
	option mac '00:11:22:33:44:55'
	option ip '192.168.8.50'
EOF
cat > "$TEST_ROOT/profile-same" <<'EOF'
config lan
	option protocol 'static'
	option address '192.168.8.1'
	option netmask '255.255.255.0'
EOF
cat > "$TEST_ROOT/profile-in-subnet" <<'EOF'
config lan
	option protocol 'static'
	option address '192.168.8.1'
	option netmask '255.255.255.0'
config reservation
	option name 'printer'
	option mac '00:11:22:33:44:55'
	option ip '192.168.8.50'
EOF
cat > "$TEST_ROOT/profile-ok" <<'EOF'
config lan
	option protocol 'static'
	option address '192.168.8.1'
	option netmask '255.255.255.0'
config reservation
	option name 'printer'
	option mac '00:11:22:33:44:55'
	option ip '192.168.80.50'
EOF

archive_a="$TEST_ROOT/a.tar.gz"
archive_same="$TEST_ROOT/same.tar.gz"
archive_in_subnet="$TEST_ROOT/in-subnet.tar.gz"
archive_ok="$TEST_ROOT/ok.tar.gz"
build_portable "$archive_a" "$TEST_ROOT/profile-a"
build_portable "$archive_same" "$TEST_ROOT/profile-same"
build_portable "$archive_in_subnet" "$TEST_ROOT/profile-in-subnet"
build_portable "$archive_ok" "$TEST_ROOT/profile-ok"

# --- Validation plan integration ----------------------------------------------
run_validate() {
	# run_validate MOCK_IP PRESERVE_FLAG ARCHIVE CATEGORIES OUT
	mock_ip=$1
	preserve_flag=$2
	archive=$3
	categories=$4
	out=$5
	shift 5
	GCM_MOCK_LAN_IP="$mock_ip" GCM_LIB="$CORE" sh "$CLI" validate "$archive" --categories "$categories" "$@" > "$out" 2>/dev/null || return 1
	"$NODE_BIN" -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$out" || return 1
	return 0
}

run_validate 192.168.80.1 flag "$archive_a" lan,dhcp "$TEST_ROOT/plan-on.json" --preserve-destination-lan-ip || { echo 'preserve-enabled validation failed' >&2; exit 1; }
grep -Fq '"compatible":true' "$TEST_ROOT/plan-on.json" || { echo 'preserve-enabled plan must be compatible' >&2; exit 1; }
grep -Fq '"preserve_destination_lan_ip":1' "$TEST_ROOT/plan-on.json" || { echo 'plan must echo the normalized flag' >&2; exit 1; }
grep -Fq '"destination_lan_ip":"192.168.80.1"' "$TEST_ROOT/plan-on.json" || { echo 'plan must carry the captured destination IP' >&2; exit 1; }
grep -Fq 'Destination LAN IP 192.168.80.1 will be preserved instead of backup LAN IP 192.168.8.1.' "$TEST_ROOT/plan-on.json" || { echo 'plan must report preserve-instead-of under will_preserve' >&2; exit 1; }
grep -Fq 'Static DHCP reservation(s) from the backup reference 192.168.8.50, which is outside the preserved destination subnet' "$TEST_ROOT/plan-on.json" || { echo 'plan must warn about cross-subnet static reservations' >&2; exit 1; }
ok 'validation plan reports preservation with the differing backup IP and a DHCP conflict warning'

run_validate 192.168.8.1 flag "$archive_same" lan "$TEST_ROOT/plan-same.json" --preserve-destination-lan-ip || { echo 'same-IP validation failed' >&2; exit 1; }
grep -Fq 'Destination LAN IP 192.168.8.1 will be preserved.' "$TEST_ROOT/plan-same.json" || { echo 'same-IP plan must report plain preservation' >&2; exit 1; }
grep -Fq 'instead of backup LAN IP' "$TEST_ROOT/plan-same.json" && { echo 'same-IP plan must not claim a differing backup IP' >&2; exit 1; }
ok 'validation plan preserves normally when destination and backup addresses are equal'

run_validate 192.168.80.1 noflag "$archive_a" lan "$TEST_ROOT/plan-off.json"
grep -Fq '"preserve_destination_lan_ip":0' "$TEST_ROOT/plan-off.json" || { echo 'omitted flag must keep the historical default of disabled' >&2; exit 1; }
grep -Fq 'LAN IP: 192.168.8.1 will apply.' "$TEST_ROOT/plan-off.json" || { echo 'disabled plan must report the backup LAN IP under will_apply' >&2; exit 1; }
grep -Fq 'Destination LAN IP 192.168.80.1 will be preserved' "$TEST_ROOT/plan-off.json" && { echo 'disabled plan must not claim preservation' >&2; exit 1; }
ok 'validation plan with preservation disabled reports LAN IP will_apply'

run_validate '' flag "$archive_same" lan "$TEST_ROOT/plan-missing.json" --preserve-destination-lan-ip || true
grep -Fq '"compatible":false' "$TEST_ROOT/plan-missing.json" || { echo 'missing destination IP must block validation' >&2; exit 1; }
grep -Fq 'Cannot preserve destination LAN IP because network.lan.ipaddr is not defined on the target. Disable preservation or set a LAN address first.' "$TEST_ROOT/plan-missing.json" || { echo 'missing-IP incompatibility message missing' >&2; exit 1; }
ok 'validation blocks when preservation is enabled and the destination LAN IP is missing'

run_validate 192.168.80.1 flag "$archive_ok" lan,dhcp "$TEST_ROOT/plan-ok.json" --preserve-destination-lan-ip || { echo 'in-subnet validation failed' >&2; exit 1; }
grep -Fq 'outside the preserved destination subnet' "$TEST_ROOT/plan-ok.json" && { echo 'in-subnet reservations must not warn' >&2; exit 1; }
ok 'no DHCP conflict warning when the backup reservation is inside the preserved subnet'

grep -Fq 'stage="preserve-lan-ip"' "$GCM_LOG_FILE" || { echo 'structured preserve-lan-ip diagnostics missing' >&2; exit 1; }
grep -Fq 'result="captured"' "$GCM_LOG_FILE" || { echo 'structured captured diagnostic missing' >&2; exit 1; }
grep -Fq 'destination_lan_ip="192.168.80.1"' "$GCM_LOG_FILE" || { echo 'structured destination IP diagnostic missing' >&2; exit 1; }
grep -Fq 'preserve_destination_lan_ip="1"' "$GCM_LOG_FILE" || { echo 'structured request flag diagnostic missing' >&2; exit 1; }
ok 'structured preserve-lan-ip diagnostics are emitted'

# --- In-process validation state reset ----------------------------------------
# gcm_validate can be invoked repeatedly inside one shell process (restore runs
# a mandatory validation first). A stale GCM_DESTINATION_LAN_IP from an earlier
# operation must never leak into a later plan when no capture happens.
export GCM_MOCK_LAN_IP=192.168.80.1
GCM_DESTINATION_LAN_IP=192.168.80.1
GCM_ACTION=validate
plan_reset=$(gcm_validate "$archive_a" lan 0 0)
printf '%s\n' "$plan_reset" | grep -Fq '"preserve_destination_lan_ip":0' || { echo 'reset validation plan must report preservation disabled' >&2; exit 1; }
if printf '%s\n' "$plan_reset" | grep -Fq '"destination_lan_ip":"192.168.80.1"'; then echo 'stale destination IP leaked into a non-preserving plan' >&2; exit 1; fi
printf '%s\n' "$plan_reset" | grep -Fq '"destination_lan_ip":""' || { echo 'reset validation plan must carry an empty destination IP' >&2; exit 1; }
ok 'validation entry resets stale preserved-IP state when no capture happens'

# --- Portable LAN apply and restore flow --------------------------------------
# The mock uci answers `-c DIR show/get profile` from the fixture file, so the
# real core.sh profile readers (gcm_profile_sections / gcm_profile_get) run
# unmodified. Only the adapter (uci set/commit surface) is recorded.
gcm_adapter_set() { printf '%s=%s\n' "$1.$2.$3" "$4" >> "$GCM_ADAPTER_LOG"; }
gcm_adapter_commit() { printf 'commit:%s\n' "$1" >> "$GCM_ADAPTER_LOG"; }

portable_dir="$TEST_ROOT/portable-cfg"
mkdir -p "$portable_dir"
cp "$TEST_ROOT/profile-a" "$portable_dir/profile"

export GCM_ADAPTER_LOG="$TEST_ROOT/adapter.log"
: > "$GCM_ADAPTER_LOG"
export GCM_PRESERVE_DESTINATION_LAN_IP=1 GCM_DESTINATION_LAN_IP=192.168.80.1 GCM_MOCK_LAN_IP=192.168.80.1
gcm_apply_portable_lan_dhcp_dns "$portable_dir" lan >/dev/null 2>&1 || { echo 'portable LAN apply failed under preservation' >&2; exit 1; }
grep -Fq 'network.lan.proto=static' "$GCM_ADAPTER_LOG" || { echo 'portable LAN apply must still stage other logical settings' >&2; exit 1; }
if grep -Fq 'network.lan.ipaddr=' "$GCM_ADAPTER_LOG"; then echo 'preserve-enabled portable apply must not stage the backup address' >&2; exit 1; fi
ok 'portable apply preserves the destination LAN IP while other LAN settings restore'

: > "$GCM_ADAPTER_LOG"
export GCM_PRESERVE_DESTINATION_LAN_IP=0 GCM_DESTINATION_LAN_IP=''
gcm_apply_portable_lan_dhcp_dns "$portable_dir" lan >/dev/null 2>&1 || { echo 'portable LAN apply failed with preservation disabled' >&2; exit 1; }
grep -Fq 'network.lan.ipaddr=192.168.8.1' "$GCM_ADAPTER_LOG" || { echo 'disabled portable apply must stage the backup address' >&2; exit 1; }
ok 'portable apply with preservation disabled stages the backup LAN IP'

gcm_pre_restore_snapshot() {
	snapshot_root="$TEST_ROOT/snapshot-$1"
	mkdir -p "$snapshot_root"
	printf '%s\n' "$snapshot_root"
}
gcm_rollback_snapshot() { return 0; }

export GCM_MOCK_LAN_IP=192.168.80.1
: > "$GCM_ADAPTER_LOG"
GCM_ACTION=restore GCM_COMPONENT=restore
restore_on=$(gcm_restore "$archive_a" lan '' 0 0 0 1)
printf '%s\n' "$restore_on" | grep -Fq 'RESTORE=success' || { echo 'preserve-enabled restore failed' >&2; exit 1; }
printf '%s\n' "$restore_on" | grep -Fq 'PRESERVED=portable:network.lan.ipaddr:destination-ip-retained' || { echo 'portable preserve log missing' >&2; exit 1; }
if grep -Fq 'network.lan.ipaddr=' "$GCM_ADAPTER_LOG"; then echo 'end-to-end preserve restore staged the backup address' >&2; exit 1; fi
ok 'end-to-end portable restore with preservation enabled never stages the backup LAN IP'

: > "$GCM_ADAPTER_LOG"
restore_off=$(gcm_restore "$archive_a" lan '' 0 0 0 0)
printf '%s\n' "$restore_off" | grep -Fq 'RESTORE=success' || { echo 'legacy restore failed' >&2; exit 1; }
grep -Fq 'network.lan.ipaddr=192.168.8.1' "$GCM_ADAPTER_LOG" || { echo 'legacy restore must apply the backup address' >&2; exit 1; }
ok 'end-to-end portable restore without preservation applies the backup LAN IP'

export GCM_MOCK_LAN_IP=''
if gcm_restore "$archive_a" lan '' 0 0 0 1 >/dev/null 2>&1; then echo 'restore with missing destination IP must be blocked'; exit 1; fi
ok 'restore is blocked when preservation is enabled and the destination LAN IP is missing'

# --- CLI flag parsing parity ---------------------------------------------------
if GCM_LIB="$CORE" sh "$CLI" restore "$TEST_ROOT/definitely-missing.tar.gz" --preserve-destination-lan-ip >/dev/null 2>&1; then echo 'missing archive should not restore'; exit 1; fi
ok 'CLI restore accepts --preserve-destination-lan-ip and proceeds to archive handling'

printf 'all preserve-lan-ip regression tests passed (%s checks)\n' "$PASS"
