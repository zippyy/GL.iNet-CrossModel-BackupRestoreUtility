#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CONTROLLER="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/lua/luci/controller/glinet_crossmodel.lua"
VIEW="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/lua/luci/view/glinet_crossmodel/index.htm"

require_text() {
	needle=$1
	file=$2
	message=$3
	if ! grep -Fq "$needle" "$file"; then
		echo "$message" >&2
		exit 1
	fi
}

# GL.iNet's LuCI 21.02 path follows LuCI's standard request-value transport.
# Depending solely on a custom HTTP header causes every state-changing API
# request to return the user-visible 403 CSRF error on affected firmware.
require_text "body.token=csrf" "$VIEW" \
	'JSON API requests do not send the LuCI token in the request body; affected POSTs return 403.'
require_text "form.append('token',csrf)" "$VIEW" \
	'Multipart imports do not send the LuCI token as a form value; affected POSTs return 403.'
require_text 'supplied = input.token' "$CONTROLLER" \
	'The controller does not validate the CSRF token transported in JSON requests.'
require_text 'input.token = nil' "$CONTROLLER" \
	'The controller retains the CSRF token in the action input after validation.'
require_text 'http.formvalue("token", true)' "$CONTROLLER" \
	'The controller does not validate the multipart LuCI token form value.'

if grep -Fq "X-CSRF-Token" "$VIEW" || grep -Fq 'HTTP_X_CSRF_TOKEN' "$CONTROLLER"; then
	echo 'CSRF validation still depends on the incompatible custom-header transport.' >&2
	exit 1
fi

echo 'LuCI CSRF request-body transport checks passed'
