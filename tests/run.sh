#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
sh "$ROOT/tests/test-core.sh"
sh "$ROOT/tests/test-security.sh"
sh "$ROOT/tests/test-controller-security.sh"
sh -n "$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/glinet-crossmodel/core.sh"
sh -n "$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/bin/glinet-crossmodel"
sh -n "$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/libexec/glinet-crossmodel-remote"
sh -n "$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/libexec/gcm-glui-integrate"
sh -n "$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/libexec/glinet-crossmodel-backup"
sh -n "$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/libexec/glinet-crossmodel-validate"
sh -n "$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/etc/init.d/gcm-glui-integration"
sh -n "$ROOT/scripts/real-router-smoke.sh"
