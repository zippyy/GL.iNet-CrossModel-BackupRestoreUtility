#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$ROOT_DIR/openwrt/luci-app-glinet-crossmodel-backup"
FILES_DIR="$PKG_DIR/root"
MAKEFILE="$PKG_DIR/Makefile"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"

package_name="$(sed -n 's/^PKG_NAME:=//p' "$MAKEFILE" | head -n1)"
version="$(sed -n 's/^PKG_VERSION:=//p' "$MAKEFILE" | head -n1)"
release="$(sed -n 's/^PKG_RELEASE:=//p' "$MAKEFILE" | head -n1)"
depends_raw="$(sed -n 's/^  DEPENDS:=//p' "$MAKEFILE" | head -n1)"
title="$(sed -n 's/^  TITLE:=//p' "$MAKEFILE" | head -n1)"

[[ -n "$package_name" ]] || { echo 'PKG_NAME not found in OpenWrt package Makefile' >&2; exit 1; }
[[ -n "$version" ]] || { echo 'PKG_VERSION not found in OpenWrt package Makefile' >&2; exit 1; }
[[ -n "$release" ]] || { echo 'PKG_RELEASE not found in OpenWrt package Makefile' >&2; exit 1; }
[[ -d "$FILES_DIR" ]] || { echo 'OpenWrt package root payload is missing' >&2; exit 1; }

# Legacy GL.iNet opkg builds expect the conventional ", " separator in
# Debian-style dependency fields. A no-space comma list can be rejected during
# control-file parsing as a malformed IPK.
depends_words="${depends_raw//+/}"
read -r -a dependency_list <<< "$depends_words"
depends=""
for dependency in "${dependency_list[@]}"; do
  depends+="${depends:+$depends, }$dependency"
done

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
control_dir="$work_dir/control"
data_dir="$work_dir/data"
mkdir -p "$control_dir" "$data_dir" "$OUTPUT_DIR"

# Package every file below root/ exactly where OpenWrt expects it.
cp -a "$FILES_DIR/." "$data_dir/"
chmod 0755 \
  "$data_dir/usr/libexec/glinet-crossmodel-backup" \
  "$data_dir/usr/libexec/glinet-crossmodel-remote"

installed_size="$(du -sk "$data_dir" | awk '{print $1}')"
cat > "$control_dir/control" <<EOF
Package: $package_name
Version: ${version}-${release}
Architecture: all
Installed-Size: $installed_size
Section: luci
Priority: optional
Depends: $depends
Maintainer: Tech Relay
Description: ${title:-GL.iNet Cross-Model Backup / Restore}
 Native LuCI utility for portable GL.iNet/OpenWrt configuration profiles.
 It can run locally or coordinate LAN router backup and restore operations
 over SSH from a main GL.iNet control router.
EOF

cat > "$control_dir/postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0

mkdir -p /root/glinet-crossmodel/profiles /tmp/glinet-crossmodel /root/.ssh
chmod 700 /root/.ssh
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true

[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
[ -x /etc/init.d/nginx ] && /etc/init.d/nginx restart >/dev/null 2>&1 || true
exit 0
EOF
chmod 0755 "$control_dir/postinst"

printf '2.0\n' > "$work_dir/debian-binary"
(
  cd "$control_dir"
  tar --format=gnu --owner=0 --group=0 --numeric-owner -czf "$work_dir/control.tar.gz" .
)
(
  cd "$data_dir"
  tar --format=gnu --owner=0 --group=0 --numeric-owner -czf "$work_dir/data.tar.gz" .
)

ipk="$OUTPUT_DIR/${package_name}_${version}-${release}_all.ipk"
rm -f "$ipk"
(
  cd "$work_dir"
  ar rcs "$ipk" debian-binary control.tar.gz data.tar.gz
)

# Fail the build unless the result has the exact IPK container and a valid
# OpenWrt control file. This catches malformed packages before release upload.
mapfile -t ar_members < <(ar t "$ipk")
[[ "${ar_members[*]}" == "debian-binary control.tar.gz data.tar.gz" ]] || {
  printf 'Invalid IPK ar members: %s\n' "${ar_members[*]}" >&2
  exit 1
}
[[ "$(ar p "$ipk" debian-binary)" == "2.0" ]] || { echo 'Invalid debian-binary member' >&2; exit 1; }
ar p "$ipk" control.tar.gz | tar -xOzf - ./control > "$work_dir/control-check"
grep -qx "Package: $package_name" "$work_dir/control-check"
grep -qx "Architecture: all" "$work_dir/control-check"
grep -qx "Depends: $depends" "$work_dir/control-check"
ar p "$ipk" data.tar.gz | tar -tzf - >/dev/null

sha256sum "$ipk" > "${ipk}.sha256"
echo "Built $ipk"
echo "Depends: $depends"
