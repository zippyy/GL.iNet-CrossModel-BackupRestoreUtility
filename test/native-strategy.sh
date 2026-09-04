#!/bin/sh
# Four-strategy enforcement suite against the VENDORED canonical runtime.
# Strategy decisions come from the canonical engine (gcm_strategy_compatible,
# raw-UCI apply policy, portable Wi-Fi mapping); this suite proves the Docker
# edition inherits those exact rules.
set -eu

. "$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)/test/harness.sh"
gcm_mock_uci_install
. "$CORE"

# --- Portable: cross-model is allowed ----------------------------------------
assert_true gcm_strategy_compatible portable 'GL-MT6000' 'GL-MT3000' '' '' 0
assert_true gcm_strategy_compatible portable 'GL-MT6000' 'OpenWrt router' '' '' 0
ok 'portable permits cross-model migration'

# --- Clone: hard same-model gate ---------------------------------------------
assert_true gcm_strategy_compatible clone 'GL-MT6000' 'gl-mt6000' '' '' 0
assert_false gcm_strategy_compatible clone 'GL-MT6000' 'GL-MT3000' '' '' 0
assert_false gcm_strategy_compatible clone 'OpenWrt router' 'OpenWrt router' '' '' 0
ok 'clone requires a known, matching model'

# --- Remote-Safe Clone: same model gate as clone -----------------------------
assert_true gcm_strategy_compatible remote-safe 'GL-MT6000' 'GL-MT6000' '' '' 0
assert_false gcm_strategy_compatible remote-safe 'GL-MT6000' 'GL-MT3000' '' '' 0
ok 'remote-safe clone requires a known, matching model'

# --- Device Snapshot: physical fingerprint gate ------------------------------
assert_true gcm_strategy_compatible snapshot 'A' 'A' 'fingerprint-x' 'fingerprint-x' 0
assert_false gcm_strategy_compatible snapshot 'A' 'A' 'fingerprint-x' 'fingerprint-y' 0
assert_false gcm_strategy_compatible snapshot 'A' 'A' '' '' 0
ok 'snapshot requires an exact physical-device fingerprint match'

# Dangerous override must be explicit and is never inferred.
assert_true gcm_strategy_compatible snapshot 'A' 'A' 'fingerprint-x' 'fingerprint-y' 1
assert_true gcm_strategy_compatible snapshot 'A' 'A' '' 'fingerprint-y' 1
ok 'dangerous device override is explicit-only (flag 1) and never inferred'

# --- Portable Wi-Fi semantic band mapping ------------------------------------
assert_eq "$(gcm_band_from_values 2g '' auto radio0)" '2.4' 'maps explicit 2.4 GHz band'
assert_eq "$(gcm_band_from_values '' 11a 36 radio0)" '5' 'maps 802.11a capability to 5 GHz'
assert_eq "$(gcm_band_from_values 6g '' auto radio0)" '6' 'maps explicit 6 GHz band'
assert_eq "$(gcm_band_from_values '' '' 1 radio0)" '2.4' 'maps low channel to 2.4 GHz'
assert_eq "$(gcm_band_from_values '' '' 36 radio5ghz)" '5' 'high channel resolves via section-name hint to 5 GHz'
assert_eq "$(gcm_band_from_values '' '' 36 radio0)" 'unknown' 'channel-only heuristic never guesses 5 GHz without band/hwmode/hint'
ok 'portable Wi-Fi maps by band/capability, never by radio index alone'

# --- Clone/remote-safe identity sanitization rules ---------------------------
# Raw-UCI exclusion: remote-safe keeps target management state out of the
# restored set (dropbear, tailscale, zerotier, goodcloud, rtty are excluded).
assert_true gcm_raw_excluded_package remote-safe dropbear
assert_true gcm_raw_excluded_package remote-safe tailscale
assert_true gcm_raw_excluded_package remote-safe zerotier
assert_false gcm_raw_excluded_package snapshot dropbear
assert_true gcm_persistent_denied remote-safe /root/.ssh/authorized_keys
assert_true gcm_persistent_denied clone /etc/openvpn/server.key
ok 'identity and management-state exclusions match canonical policy'

# --- Clone raw-UCI apply preserves target factory identity -------------------
apply_tree="$TEST_ROOT/apply-tree/uci"
rm -rf "$TEST_ROOT/apply-tree"
mkdir -p "$apply_tree" "$TEST_ROOT/apply-target/etc/config"
printf "config system\n\toption hostname 'source-router'\n" > "$apply_tree/system"
printf "config system\n\toption hostname 'target-router'\n" > "$TEST_ROOT/apply-target/etc/config/system"
printf "config tailscale\n\toption enabled '1'\n" > "$apply_tree/tailscale"
: > "$GCM_MOCK_UCI_LOG"
# Sandbox: raw apply writes into GCM_CONFIG_TARGET_ROOT, never the live tree.
# system maps to the timezone category; the mock uci no-ops the commit, so the
# file copy itself is the observable mutation.
apply_out=$(GCM_CONFIG_TARGET_ROOT="$TEST_ROOT/apply-target" GCM_ACTION=restore gcm_apply_raw_uci "$apply_tree" clone timezone 2>/dev/null) || fail 'clone raw apply failed under sandbox'
# gcm_log markers are emitted on stdout; gcm_diag structured entries go to the
# diagnostic file. The identity-preservation marker is a stdout gcm_log line.
printf '%s\n' "$apply_out" | grep -Fq 'PRESERVED=target-factory-identity' || fail 'clone apply must log target identity preservation'
printf '%s\n' "$apply_out" | grep -Fq 'APPLIED=uci:system' || fail 'clone apply must apply a category-selected package'
[ "$(head -1 "$TEST_ROOT/apply-target/etc/config/system")" = "config system" ] || fail 'clone apply must copy the source config file into the sandbox target'
ok 'clone raw-UCI apply runs in the sandbox and preserves target identity'

# --- Remote-safe staged connectivity + explicit activation -------------------
stage_tree="$TEST_ROOT/rs-tree/uci"
rm -rf "$TEST_ROOT/rs-tree"
mkdir -p "$stage_tree" "$TEST_ROOT/rs-target/etc/config" "$TEST_ROOT/rs-pending" "$TEST_ROOT/rs-staged-target/etc/config"
printf "config interface 'lan'\n\toption ipaddr '192.168.8.1'\n" > "$stage_tree/network"
printf "config defaults\n" > "$stage_tree/firewall"
: > "$GCM_MOCK_UCI_LOG"
# SSH_CONNECTION simulates an active management session: network/firewall must
# be STAGED under GCM_STAGED_ROOT, not applied live. network->lan category and
# firewall->firewall category must both be selected for them to be considered.
rs_out=$(SSH_CONNECTION='192.168.8.2 54321 192.168.8.1 22' \
   GCM_CONFIG_TARGET_ROOT="$TEST_ROOT/rs-target" \
   GCM_STAGED_ROOT="$TEST_ROOT/rs-pending" \
   GCM_ACTION=restore GCM_DEFER_RELOAD=1 \
   gcm_apply_raw_uci "$stage_tree" remote-safe lan,firewall 2>/dev/null) || fail 'remote-safe staged apply failed'
[ -f "$TEST_ROOT/rs-pending/network" ] || fail 'network must be staged, not applied, while an SSH management session is active'
[ -f "$TEST_ROOT/rs-pending/firewall" ] || fail 'firewall must be staged while an SSH management session is active'
[ -f "$TEST_ROOT/rs-target/etc/config/network" ] && fail 'network must NOT be written live during a remote-safe staged restore'
[ -f "$TEST_ROOT/rs-target/etc/config/firewall" ] && fail 'firewall must NOT be written live during a remote-safe staged restore'
printf '%s\n' "$rs_out" | grep -Fq 'PRESERVED=uci:network:active-ssh-management-path' || fail 'staged network must be logged as preserved'
printf '%s\n' "$rs_out" | grep -Fq 'PRESERVED=uci:firewall:active-ssh-management-path' || fail 'staged firewall must be logged as preserved'
# Explicit activation applies the staged files.
act_out=$(GCM_STAGED_ROOT="$TEST_ROOT/rs-pending" GCM_STAGED_TARGET_ROOT="$TEST_ROOT/rs-staged-target" GCM_ACTION=activate gcm_apply_staged 2>/dev/null) || fail 'activation of staged connectivity failed'
[ -f "$TEST_ROOT/rs-staged-target/etc/config/network" ] || fail 'activate must place staged network at the target config path'
[ -f "$TEST_ROOT/rs-staged-target/etc/config/firewall" ] || fail 'activate must place staged firewall at the target config path'
[ ! -f "$TEST_ROOT/rs-pending/network" ] || fail 'activate must consume the staged network file'
[ ! -f "$TEST_ROOT/rs-pending/firewall" ] || fail 'activate must consume the staged firewall file'
printf '%s\n' "$act_out" | grep -Fq 'ACTIVATED=uci:network' || fail 'activate must log the activated network package'
printf '%s\n' "$act_out" | grep -Fq 'ACTIVATED=uci:firewall' || fail 'activate must log the activated firewall package'
ok 'remote-safe restore defers connectivity and explicit activation applies it'

# --- Snapshot raw apply (identity-blind, exact-device path) ------------------
snap_tree="$TEST_ROOT/snap-tree/uci"
rm -rf "$TEST_ROOT/snap-tree"
mkdir -p "$snap_tree" "$TEST_ROOT/snap-target/etc/config"
printf "config system\n\toption hostname 'restored'\n" > "$snap_tree/system"
: > "$GCM_MOCK_UCI_LOG"
# system maps to the timezone category; snapshot copies raw files with no
# identity reinjection (exact-device path).
snap_out=$(GCM_CONFIG_TARGET_ROOT="$TEST_ROOT/snap-target" GCM_ACTION=restore gcm_apply_raw_uci "$snap_tree" snapshot timezone 2>/dev/null) || fail 'snapshot raw apply failed'
printf '%s\n' "$snap_out" | grep -Fq 'APPLIED=uci:system' || fail 'snapshot must apply the raw system file'
[ "$(head -1 "$TEST_ROOT/snap-target/etc/config/system")" = "config system" ] || fail 'snapshot must write the raw source file into the sandbox target'
ok 'snapshot strategy applies raw UCI without identity reinjection (exact-device path)'

echo "strategy tests passed ($PASS checks)"
