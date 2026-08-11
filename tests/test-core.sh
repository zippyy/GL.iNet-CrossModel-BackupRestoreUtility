#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/glinet-crossmodel/core.sh"

TEST_ROOT=$(mktemp -d /tmp/gcm-tests.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
PASS=0

ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$PASS" "$1"; }
fail() { printf 'not ok %s - %s\n' "$((PASS + 1))" "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected $2, got $1)"; ok "$3"; }
assert_true() { "$@" || fail "$*"; ok "$*"; }
assert_false() { if "$@"; then fail "$*"; fi; ok "rejects: $*"; }

make_v2() {
	archive=$1; strategy=$2; model=$3; version=$4
	work="$TEST_ROOT/build-$strategy-$version"
	rm -rf "$work"; mkdir -p "$work/glinet-crossmodel/source"
	printf '{"format":"glinet-crossmodel/v2","format_version":%s,"tool_version":"2.0.0","backup_strategy":"%s","profile_uuid":"11111111-1111-1111-1111-111111111111","profile_name":"Fixture","notes":"","source_model":"%s","firmware_version":"4.8.2","openwrt_version":"23.05","architecture":"test-arch","kernel_version":"6.6","device_fingerprint":"fixture-fingerprint"}\n' "$version" "$strategy" "$model" > "$work/glinet-crossmodel/manifest.json"
	printf 'fixture\n' > "$work/glinet-crossmodel/backup-info.txt"
	printf '{}\n' > "$work/glinet-crossmodel/packages.json"
	(cd "$work" && find glinet-crossmodel -type f ! -name checksums.sha256 | sort | while IFS= read -r path; do sha256sum "$path"; done > glinet-crossmodel/checksums.sha256)
	tar -C "$work" -czf "$archive" glinet-crossmodel
}

printf '1..41\n'

assert_true gcm_safe_member 'glinet-crossmodel/manifest.json'
assert_false gcm_safe_member '../etc/shadow'
assert_false gcm_safe_member '/etc/shadow'

assert_eq "$(gcm_band_from_values 2g '' auto anything)" '2.4' 'maps explicit 2.4 GHz band'
assert_eq "$(gcm_band_from_values '' 11a 36 radio0)" '5' 'maps 802.11a capability to 5 GHz'
assert_eq "$(gcm_band_from_values 6g '' auto radio0)" '6' 'maps explicit 6 GHz band'
flint_bands=$(sed -n "s/^[[:space:]]*option band '\([^']*\)'.*/\1/p" "$ROOT/tests/fixtures/flint2/wireless" | while IFS= read -r fixture_band; do gcm_band_from_values "$fixture_band" '' auto fixture; done | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "$flint_bands" '2.4 5' 'maps dual-band Flint fixture capabilities'
triband_bands=$(sed -n "s/^[[:space:]]*option band '\([^']*\)'.*/\1/p" "$ROOT/tests/fixtures/triband-6e/wireless" | while IFS= read -r fixture_band; do gcm_band_from_values "$fixture_band" '' auto fixture; done | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "$triband_bands" '2.4 5 6' 'maps tri-band 6E fixture capabilities'

assert_true gcm_firewall_zone_exists lan 'wan lan guest'
assert_false gcm_firewall_zone_exists vpn 'wan lan guest'

assert_true gcm_strategy_compatible clone 'GL-MT6000' 'gl-mt6000' '' '' 0
assert_false gcm_strategy_compatible clone 'GL-MT6000' 'GL-MT3000' '' '' 0
assert_false gcm_strategy_compatible clone 'OpenWrt router' 'OpenWrt router' '' '' 0
assert_true gcm_strategy_compatible snapshot A A fingerprint fingerprint 0
assert_false gcm_strategy_compatible snapshot A A fingerprint other 0

assert_true gcm_raw_excluded_package remote-safe dropbear
assert_true gcm_raw_excluded_package remote-safe tailscale
assert_true gcm_persistent_denied remote-safe /root/.ssh/authorized_keys
assert_false gcm_persistent_denied snapshot /var/lib/tailscale/tailscaled.state
assert_true gcm_persistent_denied clone /etc/openvpn/server.key
assert_true gcm_raw_package_selected network lan
assert_false gcm_raw_package_selected wireless lan
assert_true gcm_raw_package_selected gl_vpn vpn
assert_true gcm_raw_package_selected custom_service persistent

assert_eq "$(gcm_package_class 1.0 false 1.0 '')" same 'classifies same package version'
assert_eq "$(gcm_package_class 1.0 false '' 1.1)" available 'classifies feed-available package'
assert_eq "$(gcm_package_class 1.0 true '' 1.0)" kmod 'classifies kernel package separately'
assert_true gcm_package_arch_compatible all 'all aarch64_cortex-a53'
assert_false gcm_package_arch_compatible mips_24kc 'all aarch64_cortex-a53'

elf_fixture="$TEST_ROOT/aarch64.elf"
printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000\267\000' > "$elf_fixture"
assert_eq "$(gcm_elf_signature "$elf_fixture")" '2:1:183:0' 'parses ELF class, endianness, machine, and ABI'
assert_true gcm_binary_compatible "$elf_fixture" aarch64_cortex-a53
assert_false gcm_binary_compatible "$elf_fixture" arm_cortex-a7

vpn_network="$TEST_ROOT/vpn-network"
gcm_extract_network_vpn_blocks "$ROOT/tests/fixtures/gl-amnezia/network" "$vpn_network"
gcm_sanitize_file "$vpn_network"
gcm_remove_uci_options "$vpn_network" 'device ifname macaddr private_key privatekey preshared_key secret token authkey'
if grep -Eq "config device|private_key|preshared_key|option device" "$vpn_network" || ! grep -q "option proto 'amneziawg'" "$vpn_network" || ! grep -q "option Jc '4'" "$vpn_network"; then fail 'extracts AmneziaWG structure without topology or private identity'; fi
ok 'extracts AmneziaWG structure without topology or private identity'

status_fixture="$TEST_ROOT/opkg-status"
printf 'Package: user-tool\nVersion: 1.2\nArchitecture: all\nSection: utils\nDescription: Fixture tool\nDepends: libc\nInstalled-Size: 12\nStatus: install user installed\n\nPackage: kmod-fixture\nVersion: 6.6\nArchitecture: test\nSection: kernel\nStatus: install ok installed\nAuto-Installed: yes\n\n' > "$status_fixture"
status_tsv=$(gcm_package_status_tsv "$status_fixture")
printf '%s\n' "$status_tsv" | awk -F '\t' '$1=="user-tool" && $8=="true" && $9=="false"{found=1} END{exit found?0:1}' || fail 'parses enriched user-installed package fields'
ok 'parses enriched user-installed package fields'
printf '%s\n' "$status_tsv" | awk -F '\t' '$1=="kmod-fixture" && $8=="false" && $9=="true"{found=1} END{exit found?0:1}' || fail 'parses kmod and automatic-install flags'
ok 'parses kmod and automatic-install flags'

sanitize="$TEST_ROOT/sanitize"
printf "config interface 'lan'\n\toption macaddr '00:11:22:33:44:55'\n\toption private_key 'secret'\n\toption proto 'static'\n" > "$sanitize"
gcm_sanitize_file "$sanitize"
if grep -Eq 'macaddr|private_key' "$sanitize" || ! grep -q "option proto 'static'" "$sanitize"; then fail 'sanitization removes only identity fields'; fi
ok 'sanitization removes identity fields and preserves structure'

vpn_sanitize="$TEST_ROOT/openvpn-sanitize"
printf "config server 'main'\n\toption username 'user'\n\toption password 'secret'\n\toption key '/etc/openvpn/server.key'\n\toption port '1194'\n" > "$vpn_sanitize"
gcm_remove_uci_options "$vpn_sanitize" 'username password key'
if grep -Eq 'username|password|option key' "$vpn_sanitize" || ! grep -q "option port '1194'" "$vpn_sanitize"; then fail 'VPN sanitization removes credentials and retains structure'; fi
ok 'VPN sanitization removes credentials and retains structure'

rollback_fixture="$TEST_ROOT/rollback"
mkdir -p "$rollback_fixture/glinet-crossmodel-rollback/etc/config"
printf 'original\n' > "$rollback_fixture/glinet-crossmodel-rollback/etc/config/fixture"
printf '%064d  glinet-crossmodel-rollback/etc/config/fixture\n' 0 > "$rollback_fixture/glinet-crossmodel-rollback/checksums.sha256"
reject_bad_rollback() { gcm_rollback_snapshot "$rollback_fixture" >/dev/null 2>&1; }
assert_false reject_bad_rollback

archive="$TEST_ROOT/good.tar.gz"
make_v2 "$archive" portable Fixture 2
gcm_inspect "$archive" json | grep -q '"format_version":2' || fail 'inspects and verifies v2 archive'
ok 'inspects and verifies v2 archive'

bad="$TEST_ROOT/bad-version.tar.gz"
make_v2 "$bad" portable Fixture 99
if gcm_inspect "$bad" json >/dev/null 2>&1; then fail 'rejects unsupported profile version'; fi
ok 'rejects unsupported profile version'

gcm_adapter_set() { :; }
section='portable-source-section'
gcm_set_if_value network lan ipaddr 192.0.2.1
assert_eq "$section" 'portable-source-section' 'semantic setter does not clobber caller section state'

# The remaining malicious-archive checks are run by test-security.sh so this
# file stays portable across GNU tar and bsdtar hosts.
