#!/bin/sh
# Deterministically vendor the canonical router runtime from `main` into
# runtime/native/, pin the exact source commit, and record SHA-256 sums.
#
# Usage:
#   scripts/sync-native-runtime.sh <main-commit-sha>
#
# The Docker edition never downloads or executes code fetched from GitHub at
# runtime: the image contains this reviewed, pinned runtime and streams it to
# managed routers over SSH exactly like the native controller does.
#
# Only the router-side runtime files needed by the controller are copied.
# LuCI views/controllers, init scripts, package Makefiles, and the GL Admin
# Panel hook are intentionally NOT vendored (they are package-only files).
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
runtime_dir="$root/runtime/native"
commit=${1:-}

[ -n "$commit" ] || { echo "usage: scripts/sync-native-runtime.sh <main-commit-sha>" >&2; exit 2; }
case "$commit" in
	*[!0-9a-f]*|'') echo "error: commit must be a full hex SHA-1" >&2; exit 2 ;;
	????????????????????????????????????????) ;;
	*) echo "error: commit must be a full 40-character SHA-1" >&2; exit 2 ;;
esac

# The commit must exist in this repository's object store.
git -C "$root" cat-file -e "$commit^{commit}" 2>/dev/null || {
	echo "error: commit $commit is not present in this repository" >&2
	exit 1
}

# Runtime files vendored from main (allowlist).
# Paths are relative to the repository root on main. Destination names under
# runtime/native/ are the basenames of these paths.
copy_files="
openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/glinet-crossmodel/core.sh
openwrt/luci-app-glinet-crossmodel-backup/root/usr/bin/glinet-crossmodel
openwrt/luci-app-glinet-crossmodel-backup/root/usr/libexec/glinet-crossmodel-backup
openwrt/luci-app-glinet-crossmodel-backup/root/usr/libexec/glinet-crossmodel-validate
openwrt/luci-app-glinet-crossmodel-backup/root/usr/libexec/glinet-crossmodel-remote
"

mkdir -p "$runtime_dir"

# Strip surrounding whitespace into a positional list.
set -- $(printf '%s\n' "$copy_files" | sed '/^[[:space:]]*$/d')
[ "$#" -gt 0 ] || { echo "error: no runtime files configured" >&2; exit 1; }

for src in "$@"; do
	git -C "$root" cat-file -e "$commit:$src" 2>/dev/null || {
		echo "error: $commit does not contain $src" >&2
		exit 1
	}
	dest=$(basename "$src")
	git -C "$root" show "$commit:$src" > "$runtime_dir/$dest"
	chmod 0755 "$runtime_dir/$dest"
done

printf '%s\n' "$commit" > "$root/runtime/UPSTREAM_MAIN_COMMIT"

# Deterministic checksum manifest (sorted, relative paths only).
(
	cd "$runtime_dir"
	find . -maxdepth 1 -type f ! -name SHA256SUMS | sort | while IFS= read -r f; do
		sha256sum "$f"
	done
) > "$runtime_dir/SHA256SUMS"

# Structural sanity: the vendored core must declare the v2 format marker.
grep -q "GCM_CORE_LOADED=1" "$runtime_dir/core.sh" || { echo "error: vendored core.sh missing GCM_CORE_LOADED marker" >&2; exit 1; }
grep -q "glinet-crossmodel/v2" "$runtime_dir/core.sh" || { echo "error: vendored core.sh missing v2 format marker" >&2; exit 1; }

echo "Vendored native runtime from $commit into runtime/native/"
echo "Files: $#  (see runtime/UPSTREAM_MAIN_COMMIT, runtime/native/SHA256SUMS)"
