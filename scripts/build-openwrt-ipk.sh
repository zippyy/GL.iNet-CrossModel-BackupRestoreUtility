#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/openwrt/luci-app-glinet-crossmodel-backup"
PAYLOAD_DIR="$PACKAGE_DIR/root"
MAKEFILE="$PACKAGE_DIR/Makefile"
OUTPUT_DIR="$ROOT_DIR/dist"
PACKAGE_NAME="luci-app-glinet-crossmodel-backup"

version="$(sed -n 's/^PKG_VERSION:=//p' "$MAKEFILE" | head -n1)"
release="$(sed -n 's/^PKG_RELEASE:=//p' "$MAKEFILE" | head -n1)"

[ -n "$version" ] || { echo 'PKG_VERSION is missing' >&2; exit 1; }
[ -n "$release" ] || { echo 'PKG_RELEASE is missing' >&2; exit 1; }
[ -d "$PAYLOAD_DIR" ] || { echo "Missing payload directory: $PAYLOAD_DIR" >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
control_dir="$work_dir/control"
data_dir="$work_dir/data"
mkdir -p "$control_dir" "$data_dir" "$OUTPUT_DIR"

cp -a "$PAYLOAD_DIR/." "$data_dir/"
chmod 0755 "$data_dir/usr/libexec/glinet-crossmodel-backup"
chmod 0755 "$data_dir/usr/libexec/glinet-crossmodel-remote"

installed_size="$(du -sk "$data_dir" | awk '{print $1}')"
cat > "$control_dir/control" <<EOF
Package: $PACKAGE_NAME
Version: $version-$release
Section: luci
Priority: optional
Maintainer: zippyy
Architecture: all
Installed-Size: $installed_size
Description: GL.iNet Cross-Model Backup and Restore
 Native LuCI utility for portable GL.iNet and OpenWrt configuration profiles.
EOF

cat > "$control_dir/postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
mkdir -p /root/glinet-crossmodel/profiles /tmp/glinet-crossmodel /root/.ssh
chmod 700 /root/.ssh
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
[ -x /etc/init.d/nginx ] && /etc/init.d/nginx restart >/dev/null 2>&1 || true
exit 0
EOF
chmod 0755 "$control_dir/postinst"
printf '2.0\n' > "$work_dir/debian-binary"

# GL.iNet firmware 4.0 / OpenWrt 21.02 opkg expects a gzip-compressed tar
# wrapper, not a Debian ar archive. Keep this order: debian-binary, data, control.
(
  cd "$data_dir"
  tar --owner=0 --group=0 --numeric-owner -czf "$work_dir/data.tar.gz" .
)
(
  cd "$control_dir"
  tar --owner=0 --group=0 --numeric-owner -czf "$work_dir/control.tar.gz" .
)

ipk="$OUTPUT_DIR/${PACKAGE_NAME}_${version}-${release}_all.ipk"
rm -f "$ipk" "$ipk.sha256"
(
  cd "$work_dir"
  tar --owner=0 --group=0 --numeric-owner -czf "$ipk" \
    ./debian-binary ./data.tar.gz ./control.tar.gz
)
sha256sum "$ipk" > "$ipk.sha256"

# Refuse to publish the old ar format or a malformed control archive.
tar -tzf "$ipk" | grep -qx './debian-binary'
tar -tzf "$ipk" | grep -qx './data.tar.gz'
tar -tzf "$ipk" | grep -qx './control.tar.gz'
tar -xOzf "$ipk" ./debian-binary | grep -qx '2.0'
tar -xOzf "$ipk" ./control.tar.gz > "$work_dir/verify-control.tar.gz"
tar -tzf "$work_dir/verify-control.tar.gz" | grep -qx './control'
tar -xOzf "$work_dir/verify-control.tar.gz" ./control | grep -qx "Package: $PACKAGE_NAME"
tar -xOzf "$ipk" ./data.tar.gz > "$work_dir/verify-data.tar.gz"
tar -tzf "$work_dir/verify-data.tar.gz" | grep -qx './usr/libexec/glinet-crossmodel-backup'
tar -tzf "$work_dir/verify-data.tar.gz" | grep -qx './usr/libexec/glinet-crossmodel-remote'

echo "Built $ipk"
