#!/bin/sh
# Builds the legacy gzip/tar IPK format accepted by GL.iNet OpenWrt 21.02 opkg.
set -eu

ROOT=$(pwd)
SOURCE="$ROOT/openwrt/glui-integration"
BUILD="$ROOT/.build/glui-integration"
DIST="$ROOT/dist"
PACKAGE='luci-app-glinet-crossmodel-backup-glui'
VERSION='1.1.0-21'
OUTPUT="$DIST/${PACKAGE}_${VERSION}_all.ipk"

rm -rf "$BUILD"
mkdir -p "$BUILD/CONTROL" "$BUILD/etc/init.d" "$BUILD/usr/libexec" "$BUILD/www/js" "$DIST"

install -m 0644 "$SOURCE/CONTROL/control" "$BUILD/CONTROL/control"
install -m 0755 "$SOURCE/CONTROL/postinst" "$BUILD/CONTROL/postinst"
install -m 0755 "$SOURCE/CONTROL/prerm" "$BUILD/CONTROL/prerm"
install -m 0755 "$SOURCE/files/etc/init.d/gcm-glui-integration" "$BUILD/etc/init.d/gcm-glui-integration"
install -m 0755 "$SOURCE/files/usr/libexec/gcm-glui-integrate" "$BUILD/usr/libexec/gcm-glui-integrate"
install -m 0644 "$SOURCE/files/www/js/gcm-glui-hook.js" "$BUILD/www/js/gcm-glui-hook.js"

# GL.iNet's older opkg accepts this legacy ipkg layout, not Debian's ar layout.
tar -C "$BUILD" -czf "$OUTPUT" ./CONTROL ./etc ./usr ./www

tar -tzf "$OUTPUT" | grep -qx './CONTROL/control'
tar -tzf "$OUTPUT" | grep -qx './www/js/gcm-glui-hook.js'

printf '%s\n' "$OUTPUT"
