#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CONTROLLER="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/lua/luci/controller/glinet_crossmodel.lua"
REMOTE="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/libexec/glinet-crossmodel-remote"
VIEW="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/lua/luci/view/glinet_crossmodel/index.htm"
KEEP="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/lib/upgrade/keep.d/glinet-crossmodel"

if grep -Eq 'password[[:space:]]*=[[:space:]]*connection\.password' "$CONTROLLER"; then
	echo 'Router inventory persists the submitted password.' >&2
	exit 1
fi
grep -Fq 'fs.chmod(path, "0600")' "$CONTROLLER"
grep -Fq 'cleanup_credential(connection, credential)' "$CONTROLLER"
grep -Fq 'StrictHostKeyChecking=accept-new' "$REMOTE"
grep -Fq 'UserKnownHostsFile="$KNOWN_HOSTS"' "$REMOTE"
grep -Fq 'sha256sum' "$REMOTE"
grep -Fq 'HTTP_X_CSRF_TOKEN' "$CONTROLLER"
grep -Fq 'dispatcher.context.authtoken' "$CONTROLLER"
grep -Fq 'luci.dispatcher.context.authtoken' "$VIEW"
grep -Fq 'jsonc.stringify(token)' "$VIEW"
if grep -Fq 'dispatcher.context.authsession' "$CONTROLLER" || grep -Fq 'luci.dispatcher.context.authsession' "$VIEW"; then
	echo 'CSRF protection must use LuCI authtoken, not the login session ID.' >&2
	exit 1
fi
grep -Fq "X-CSRF-Token']=" "$VIEW"
grep -Fq "current ~= connection.saved.verified_fingerprint" "$CONTROLLER"
grep -Fxq '/root/.ssh/known_hosts' "$KEEP"
grep -Fq 'function action_settings_save()' "$CONTROLLER"
grep -Fq "byId('save-storage').addEventListener" "$VIEW"
grep -Fq 'function action_diagnostics()' "$CONTROLLER"
grep -Fq 'function action_logging_save()' "$CONTROLLER"
grep -Fq 'function action_logs_clear()' "$CONTROLLER"
grep -Fq 'id="diagnostic-log"' "$VIEW"
grep -Fq "jsonRequest('/api/logging-save'" "$VIEW"
grep -Fq "jsonRequest('/api/logs-clear'" "$VIEW"
grep -Fq 'GCM_OP_ID=' "$CONTROLLER"
if grep -Eqi 'md5(sum)?' "$REMOTE"; then
	echo 'Remote coordinator still uses MD5.' >&2
	exit 1
fi
echo 'controller credential and SSH transport checks passed'
