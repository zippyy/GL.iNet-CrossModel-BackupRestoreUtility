#!/bin/sh
# Adversarial archive-security suite against the VENDORED canonical runtime.
# Every unsafe case must fail in gcm_check_archive_members (pre-extraction
# scan) or gcm_inspect (which verifies checksums + manifest before use).
set -eu

. "$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)/test/harness.sh"
. "$CORE"

payload="$TEST_ROOT/payload"
mkdir -p "$payload/glinet-crossmodel/source"

printf 'not a gzip archive\n' > "$TEST_ROOT/malformed.tar.gz"
if gcm_check_archive_members "$TEST_ROOT/malformed.tar.gz" v2 >/dev/null 2>&1; then fail 'malformed archive accepted'; fi
ok 'rejects malformed archive'

# Traversal via tar transform.
if tar --help 2>&1 | grep -q -- '--transform'; then
  tar -C "$payload" --transform='s#^glinet-crossmodel#../escape#' -czf "$TEST_ROOT/traversal.tar.gz" glinet-crossmodel
else
  tar -C "$payload" -s ',^glinet-crossmodel,../escape,' -czf "$TEST_ROOT/traversal.tar.gz" glinet-crossmodel
fi
if gcm_check_archive_members "$TEST_ROOT/traversal.tar.gz" v2 >/dev/null 2>&1; then fail 'traversal archive accepted'; fi
ok 'rejects traversal member'

# Absolute path member.
mkdir -p "$payload/tmp-abs"
printf 'x\n' > "$payload/tmp-abs/escaped"
( cd "$payload" && tar --transform='s#^tmp-abs#/etc#' -czf "$TEST_ROOT/absolute.tar.gz" tmp-abs 2>/dev/null ) || true
if gcm_check_archive_members "$TEST_ROOT/absolute.tar.gz" v2 >/dev/null 2>&1; then fail 'absolute-path archive accepted'; fi
ok 'rejects absolute-path member'

# Symlink member.
mkdir -p "$payload/glinet-crossmodel/links"
ln -s /etc/shadow "$payload/glinet-crossmodel/links/shadow"
tar -C "$payload" -czf "$TEST_ROOT/symlink.tar.gz" glinet-crossmodel
if gcm_check_archive_members "$TEST_ROOT/symlink.tar.gz" v2 >/dev/null 2>&1; then fail 'symlink archive accepted'; fi
rm "$payload/glinet-crossmodel/links/shadow"
ok 'rejects symlink member'

# Hardlink member (GNU tar --hard-dereference not needed: create real link).
printf 'target\n' > "$payload/glinet-crossmodel/hard-target"
ln "$payload/glinet-crossmodel/hard-target" "$payload/glinet-crossmodel/hard-link"
tar -C "$payload" -czf "$TEST_ROOT/hardlink.tar.gz" glinet-crossmodel
if gcm_check_archive_members "$TEST_ROOT/hardlink.tar.gz" v2 >/dev/null 2>&1; then fail 'hardlink archive accepted'; fi
rm "$payload/glinet-crossmodel/hard-link" "$payload/glinet-crossmodel/hard-target"
ok 'rejects hardlink member'

# Duplicate member path (two entries with the same name).
printf 'first\n' > "$payload/glinet-crossmodel/dup"
printf 'second\n' > "$payload/glinet-crossmodel/dup2"
( cd "$payload" && tar -czf "$TEST_ROOT/dup.tar.gz" glinet-crossmodel/dup glinet-crossmodel/dup glinet-crossmodel/dup2 2>/dev/null || true )
if gcm_check_archive_members "$TEST_ROOT/dup.tar.gz" v2 >/dev/null 2>&1; then fail 'duplicate-member archive accepted'; fi
rm -f "$payload/glinet-crossmodel/dup" "$payload/glinet-crossmodel/dup2"
ok 'rejects duplicate member paths'

# Expansion-bomb size guards from the pre-extraction listing.
bomb="$TEST_ROOT/bomb-payload"
rm -rf "$bomb"; mkdir -p "$bomb/glinet-crossmodel/source"
printf 'tiny\n' > "$bomb/glinet-crossmodel/manifest.json"
( cd "$bomb" && tar -czf "$TEST_ROOT/bomb.tar.gz" glinet-crossmodel )
if GCM_ARCHIVE_MAX_FILE_BYTES=4 GCM_ARCHIVE_MAX_TOTAL_BYTES=65536 gcm_check_archive_members "$TEST_ROOT/bomb.tar.gz" v2 >/dev/null 2>&1; then fail 'oversize member accepted'; fi
ok 'rejects per-file expansion limit'
if GCM_ARCHIVE_MAX_FILE_BYTES=65536 GCM_ARCHIVE_MAX_TOTAL_BYTES=1 gcm_check_archive_members "$TEST_ROOT/bomb.tar.gz" v2 >/dev/null 2>&1; then fail 'oversize total accepted'; fi
ok 'rejects total expansion limit'
if ! GCM_ARCHIVE_MAX_FILE_BYTES=65536 GCM_ARCHIVE_MAX_TOTAL_BYTES=65536 gcm_check_archive_members "$TEST_ROOT/bomb.tar.gz" v2 >/dev/null 2>&1; then fail 'within-limit archive rejected'; fi
ok 'accepts within-limit archive'

# Wrong checksum, missing checksum, duplicate checksum entry, unlisted member.
tree="$TEST_ROOT/good-tree"
rm -rf "$tree"; mkdir -p "$tree/glinet-crossmodel/source"
printf '{"format":"glinet-crossmodel/v2","format_version":2,"backup_strategy":"portable","profile_uuid":"11111111-1111-1111-1111-111111111111","profile_name":"Fixture","source_model":"Fixture"}\n' > "$tree/glinet-crossmodel/manifest.json"
printf 'fixture\n' > "$tree/glinet-crossmodel/backup-info.txt"
printf '{}\n' > "$tree/glinet-crossmodel/packages.json"

# Wrong checksum.
( cd "$tree" && sha256sum glinet-crossmodel/manifest.json | sed 's/^/0000000000000000000000000000000000000000000000000000000000000000  /' | awk '{print $2, $1}' > glinet-crossmodel/checksums.sha256 )
tar -C "$tree" -czf "$TEST_ROOT/wrong.tar.gz" glinet-crossmodel
if gcm_inspect "$TEST_ROOT/wrong.tar.gz" json >/dev/null 2>&1; then fail 'wrong-checksum archive accepted'; fi
ok 'rejects wrong checksum'

# Duplicate checksum entry for one member.
( cd "$tree" && sha256sum glinet-crossmodel/manifest.json > glinet-crossmodel/checksums.sha256 && sha256sum glinet-crossmodel/backup-info.txt >> glinet-crossmodel/checksums.sha256 && sha256sum glinet-crossmodel/manifest.json >> glinet-crossmodel/checksums.sha256 )
tar -C "$tree" -czf "$TEST_ROOT/dupcheck.tar.gz" glinet-crossmodel
if gcm_inspect "$TEST_ROOT/dupcheck.tar.gz" json >/dev/null 2>&1; then fail 'duplicate-checksum archive accepted'; fi
ok 'rejects duplicate checksum entries'

# Missing checksum file.
rm -f "$tree/glinet-crossmodel/checksums.sha256"
tar -C "$tree" -czf "$TEST_ROOT/nocheck.tar.gz" glinet-crossmodel
if gcm_inspect "$TEST_ROOT/nocheck.tar.gz" json >/dev/null 2>&1; then fail 'missing-checksum archive accepted'; fi
ok 'rejects missing checksums.sha256'

# Unlisted payload member.
( cd "$tree" && find glinet-crossmodel -type f ! -name checksums.sha256 | sort | while IFS= read -r p; do sha256sum "$p"; done > glinet-crossmodel/checksums.sha256 )
printf 'rogue\n' > "$tree/glinet-crossmodel/extra-rogue"
tar -C "$tree" -czf "$TEST_ROOT/unlisted.tar.gz" glinet-crossmodel
if gcm_inspect "$TEST_ROOT/unlisted.tar.gz" json >/dev/null 2>&1; then fail 'unlisted-member archive accepted'; fi
rm -f "$tree/glinet-crossmodel/extra-rogue"
ok 'rejects unlisted payload member'

# Unknown manifest format version.
printf '{"format":"glinet-crossmodel/v2","format_version":99,"backup_strategy":"portable","profile_uuid":"11111111-1111-1111-1111-111111111111"}\n' > "$tree/glinet-crossmodel/manifest.json"
( cd "$tree" && find glinet-crossmodel -type f ! -name checksums.sha256 | sort | while IFS= read -r p; do sha256sum "$p"; done > glinet-crossmodel/checksums.sha256 )
tar -C "$tree" -czf "$TEST_ROOT/unknownver.tar.gz" glinet-crossmodel
if gcm_inspect "$TEST_ROOT/unknownver.tar.gz" json >/dev/null 2>&1; then fail 'unknown-version archive accepted'; fi
ok 'rejects unknown manifest version'

# Malformed manifest (not JSON).
printf 'not json at all\n' > "$tree/glinet-crossmodel/manifest.json"
( cd "$tree" && find glinet-crossmodel -type f ! -name checksums.sha256 | sort | while IFS= read -r p; do sha256sum "$p"; done > glinet-crossmodel/checksums.sha256 )
tar -C "$tree" -czf "$TEST_ROOT/badmanifest.tar.gz" glinet-crossmodel
if gcm_inspect "$TEST_ROOT/badmanifest.tar.gz" json >/dev/null 2>&1; then fail 'malformed-manifest archive accepted'; fi
ok 'rejects malformed manifest'

# Invalid strategy in a structurally valid v2 manifest.
printf '{"format":"glinet-crossmodel/v2","format_version":2,"backup_strategy":"teleport","profile_uuid":"11111111-1111-1111-1111-111111111111"}\n' > "$tree/glinet-crossmodel/manifest.json"
( cd "$tree" && find glinet-crossmodel -type f ! -name checksums.sha256 | sort | while IFS= read -r p; do sha256sum "$p"; done > glinet-crossmodel/checksums.sha256 )
tar -C "$tree" -czf "$TEST_ROOT/badstrategy.tar.gz" glinet-crossmodel
if gcm_inspect "$TEST_ROOT/badstrategy.tar.gz" json >/dev/null 2>&1; then fail 'invalid-strategy archive accepted'; fi
ok 'rejects invalid strategy in manifest'

# Valid v2 archive inspects cleanly (control).
printf '{"format":"glinet-crossmodel/v2","format_version":2,"tool_version":"2.0.0","backup_strategy":"portable","profile_uuid":"11111111-1111-1111-1111-111111111111","profile_name":"Fixture","notes":"","source_model":"Fixture","firmware_version":"4.8.2","openwrt_version":"23.05","architecture":"test-arch","kernel_version":"6.6","device_fingerprint":""}\n' > "$tree/glinet-crossmodel/manifest.json"
( cd "$tree" && find glinet-crossmodel -type f ! -name checksums.sha256 | sort | while IFS= read -r p; do sha256sum "$p"; done > glinet-crossmodel/checksums.sha256 )
tar -C "$tree" -czf "$TEST_ROOT/valid.tar.gz" glinet-crossmodel
gcm_inspect "$TEST_ROOT/valid.tar.gz" json | grep -q '"format_version":2' || fail 'valid v2 archive did not inspect'
ok 'valid v2 archive inspects and verifies'

# Legacy v1 detection (profile/ prefix).
legacy="$TEST_ROOT/legacy-tree"
rm -rf "$legacy"; mkdir -p "$legacy/profile"
printf '{"model":"Fixture","firmware":"4.8.2","architecture":"test-arch"}\n' > "$legacy/profile/meta.json"
( cd "$legacy" && tar -czf "$TEST_ROOT/legacy-v1.tar.gz" profile )
kind=$(gcm_extract_archive "$TEST_ROOT/legacy-v1.tar.gz" "$TEST_ROOT/legacy-out") || fail 'legacy v1 extract failed'
assert_eq "$kind" legacy-v1 'detects legacy v1 archive prefix'
gcm_inspect "$TEST_ROOT/legacy-v1.tar.gz" json | grep -q '"archive_kind":"legacy-v1"' || fail 'legacy v1 inspect did not report legacy kind'
ok 'legacy v1 archives are detected and labeled legacy'

echo "archive security tests passed ($PASS checks)"
