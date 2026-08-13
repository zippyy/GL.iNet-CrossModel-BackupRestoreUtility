#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/glinet-crossmodel/core.sh"
TEST_ROOT=$(mktemp -d /tmp/gcm-security.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

payload="$TEST_ROOT/payload"
mkdir -p "$payload/glinet-crossmodel"
printf '{}\n' > "$payload/glinet-crossmodel/manifest.json"

printf 'not a gzip archive\n' > "$TEST_ROOT/malformed.tar.gz"
if gcm_check_archive_members "$TEST_ROOT/malformed.tar.gz" v2 >/dev/null 2>&1; then
	echo 'Malformed archive was accepted.' >&2; exit 1
fi

if tar --help 2>&1 | grep -q -- '--transform'; then
	tar -C "$payload" --transform='s#^glinet-crossmodel#../escape#' -czf "$TEST_ROOT/traversal.tar.gz" glinet-crossmodel
else
	tar -C "$payload" -s ',^glinet-crossmodel,../escape,' -czf "$TEST_ROOT/traversal.tar.gz" glinet-crossmodel
fi
if gcm_check_archive_members "$TEST_ROOT/traversal.tar.gz" v2 >/dev/null 2>&1; then
	echo 'Traversal archive was accepted.' >&2; exit 1
fi

mkdir -p "$payload/glinet-crossmodel/links"
ln -s /etc/shadow "$payload/glinet-crossmodel/links/shadow"
tar -C "$payload" -czf "$TEST_ROOT/symlink.tar.gz" glinet-crossmodel
if gcm_check_archive_members "$TEST_ROOT/symlink.tar.gz" v2 >/dev/null 2>&1; then
	echo 'Symlink archive was accepted.' >&2; exit 1
fi
rm "$payload/glinet-crossmodel/links/shadow"

printf '{"format_version":2}\n' > "$payload/glinet-crossmodel/manifest.json"
printf '%064d  glinet-crossmodel/manifest.json\n' 0 > "$payload/glinet-crossmodel/checksums.sha256"
tar -C "$payload" -czf "$TEST_ROOT/tampered.tar.gz" glinet-crossmodel
if gcm_inspect "$TEST_ROOT/tampered.tar.gz" json >/dev/null 2>&1; then
	echo 'Bad SHA-256 archive was accepted.' >&2; exit 1
fi

printf '{"format":"glinet-crossmodel/v2","format_version":2}\n' > "$payload/glinet-crossmodel/manifest.json"
(cd "$payload" && sha256sum glinet-crossmodel/manifest.json > glinet-crossmodel/checksums.sha256)
printf 'unlisted payload\n' > "$payload/glinet-crossmodel/extra-file"
tar -C "$payload" -czf "$TEST_ROOT/unlisted.tar.gz" glinet-crossmodel
if gcm_inspect "$TEST_ROOT/unlisted.tar.gz" json >/dev/null 2>&1; then
	echo 'Unlisted payload member was accepted.' >&2; exit 1
fi

rm -f "$payload/glinet-crossmodel/extra-file"
printf '{"format":"glinet-crossmodel/v2","format_version":2,"backup_strategy":"portable","profile_uuid":"../../root"}\n' > "$payload/glinet-crossmodel/manifest.json"
(cd "$payload" && sha256sum glinet-crossmodel/manifest.json > glinet-crossmodel/checksums.sha256)
tar -C "$payload" -czf "$TEST_ROOT/unsafe-uuid.tar.gz" glinet-crossmodel
if gcm_inspect "$TEST_ROOT/unsafe-uuid.tar.gz" json >/dev/null 2>&1; then
	echo 'Unsafe manifest profile UUID was accepted.' >&2; exit 1
fi

echo 'security archive tests passed'
