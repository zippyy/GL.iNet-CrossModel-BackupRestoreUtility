#!/bin/sh
# Non-destructive hardware smoke test. It reads facts/configuration, creates a
# temporary Portable Profile, validates it against the same router, runs
# Package Review, and relies on the coordinator's remote cleanup traps. It does
# not restore, reload services, reboot, or change persistent router state.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
REMOTE="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/libexec/glinet-crossmodel-remote"
CORE="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/glinet-crossmodel/core.sh"
CLI="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/bin/glinet-crossmodel"

usage() {
	echo 'Usage: real-router-smoke.sh HOST PORT USER password|key|agent CREDENTIAL' >&2
	echo 'CREDENTIAL is a mode-0600 password file, private-key path, or - for agent.' >&2
	exit 2
}

[ "$#" -eq 5 ] || usage
host=$1; port=$2; user=$3; auth=$4; credential=$5
smoke_dir=$(mktemp -d /tmp/gcm-router-smoke.XXXXXX)
case "$smoke_dir" in /tmp/gcm-router-smoke.*) ;; *) echo 'Could not create a safe smoke-test directory.' >&2; exit 1 ;; esac
trap 'rm -rf "$smoke_dir"' EXIT HUP INT TERM

archive="$smoke_dir/portable-smoke.tar.gz"
empty="$smoke_dir/empty.list"
known_hosts="$smoke_dir/known_hosts"
: > "$empty"
: > "$known_hosts"
chmod 600 "$empty" "$known_hosts"
operation_id="smoke-$(date +%s)-$$"
categories='wifi,lan,dhcp,dns,firewall,timezone,ddns,vpn,packages'

export GCM_CORE="$CORE" GCM_CLI="$CLI" GCM_KNOWN_HOSTS="$known_hosts"
"$REMOTE" facts "$host" "$port" "$user" "$auth" "$credential"
"$REMOTE" create "$archive" portable "$operation_id" 'Hardware smoke test' 'Non-destructive temporary profile' "$categories" "$empty" "$empty" "$host" "$port" "$user" "$auth" "$credential"
GCM_LIB="$CORE" "$CLI" inspect "$archive" --human
"$REMOTE" validate "$archive" "$operation_id" "$categories" 0 "$host" "$port" "$user" "$auth" "$credential"
"$REMOTE" packages "$archive" "$operation_id" "$host" "$port" "$user" "$auth" "$credential"
echo 'Non-destructive real-router smoke test passed.'
