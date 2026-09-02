#!/bin/sh
# Static contract checks for the destination LAN IP preservation option across
# the LuCI view, controller, CLI, and remote helper. These assert the wiring
# that the host-side policy tests cannot reach (checkbox default/placement,
# plan-key invalidation, strict normalization, and positional arity).

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
VIEW="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/lua/luci/view/glinet_crossmodel/index.htm"
CONTROLLER="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/lua/luci/controller/glinet_crossmodel.lua"
CLI="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/bin/glinet-crossmodel"
REMOTE="$ROOT/openwrt/luci-app-glinet-crossmodel-backup/root/usr/libexec/glinet-crossmodel-remote"

require_text() {
	needle=$1
	file=$2
	message=$3
	if ! grep -Fq -- "$needle" "$file"; then
		echo "$message" >&2
		exit 1
	fi
}
reject_text() {
	needle=$1
	file=$2
	message=$3
	if grep -Fq -- "$needle" "$file"; then
		echo "$message" >&2
		exit 1
	fi
}

# --- View: checkbox lives in the validation/restore dialog, not backup form ----
require_text 'id="preserve-destination-ip" type="checkbox" checked' "$VIEW" \
	'The restore checkbox must exist and default to checked.'
require_text 'Preserve destination router LAN IP' "$VIEW" \
	'The restore checkbox label is missing.'
require_text "Keep the target router's current LAN management IP instead of applying the IP stored in the backup." "$VIEW" \
	'The preferred help text is missing.'
require_text 'Restore options' "$VIEW" \
	'The checkbox must be grouped under a Restore options heading.'
require_text 'id="validation-content"' "$VIEW" \
	'The Restore options block must live in the validation modal (after the plan).'
# The checkbox must sit inside the validation modal, never in the backup
# creation section (which contains create-profile and the category pickers).
validation_modal_start=$(grep -n 'id="validation-modal"' "$VIEW" | cut -d: -f1 | head -n1)
create_section_line=$(grep -n 'id="create-profile"' "$VIEW" | cut -d: -f1 | head -n1)
checkbox_line=$(grep -n 'id="preserve-destination-ip"' "$VIEW" | cut -d: -f1 | head -n1)
[ -n "$validation_modal_start" ] && [ -n "$checkbox_line" ] || { echo 'Validation modal or checkbox line not found.' >&2; exit 1; }
[ "$checkbox_line" -gt "$validation_modal_start" ] || { echo 'The restore checkbox must be inside the validation modal, not the backup form.' >&2; exit 1; }
if [ -n "$create_section_line" ] && [ "$checkbox_line" -lt "$create_section_line" ]; then
	echo 'The restore checkbox must not appear before the backup creation section.' >&2; exit 1
fi

# --- View: plan key, explicit requests, stale invalidation, confirmation -------
require_text "preserve:byId('preserve-destination-ip').checked" "$VIEW" \
	'The plan key must include the checkbox state.'
require_text "body.preserve_destination_lan_ip=byId('preserve-destination-ip').checked" "$VIEW" \
	'Validation must send an explicit preserve_destination_lan_ip value.'
require_text "body.preserve_destination_lan_ip=preserve" "$VIEW" \
	'Restore must send an explicit preserve_destination_lan_ip value.'
require_text "byId('preserve-destination-ip').addEventListener('change'" "$VIEW" \
	'Toggling the checkbox must invalidate and re-run validation.'
require_text "state.lastPlan=null;state.planKey='';validateProfile(state.selectedProfile,state.dangerousOverride)" "$VIEW" \
	'The checkbox change handler must clear the validated plan before re-validating.'
require_text 'Destination LAN IP ' "$VIEW" \
	'The restore confirmation must mention the preserved destination LAN IP.'

# --- Controller: strict normalization and both-actions wiring ------------------
require_text 'normalize_preserve_flag' "$CONTROLLER" \
	'The controller must implement strict preserve-flag normalization.'
require_text 'Invalid preserve_destination_lan_ip value.' "$CONTROLLER" \
	'The controller must reject malformed preserve values.'
require_text 'preserve_destination_lan_ip = preserve' "$CONTROLLER" \
	'Restore dispatch logging must include the normalized flag.'
require_text '--preserve-destination-lan-ip' "$CONTROLLER" \
	'The local CLI invocation must pass --preserve-destination-lan-ip.'
# Remote arguments: preserve is appended after the extra flags in both actions.
require_text 'table.insert(arguments, preserve)' "$CONTROLLER" \
	'The remote argument list must carry the normalized preserve value.'

# --- CLI: flag on both validate and restore, omitted keeps historical default --
require_text '--preserve-destination-lan-ip' "$CLI" \
	'The CLI usage text must document the flag for validate and restore.'
cli_validate_count=$(grep -c 'preserve_ip=1; shift' "$CLI")
[ "$cli_validate_count" -eq 2 ] || { echo 'CLI must parse the flag in both validate and restore.' >&2; exit 1; }

# --- Remote helper: positional arity and streamed flag --------------------------
require_text "glinet-crossmodel-remote validate ARCHIVE UUID CATEGORIES OVERRIDE PRESERVE HOST PORT USER AUTH CREDENTIAL" "$REMOTE" \
	'Remote validate usage must document the PRESERVE positional.'
require_text "glinet-crossmodel-remote restore ARCHIVE UUID CATEGORIES PACKAGES DIRECT OVERRIDE ALLOW_LEGACY PRESERVE HOST PORT USER AUTH CREDENTIAL" "$REMOTE" \
	'Remote restore usage must document the PRESERVE positional.'
require_text 'credential=${10}' "$REMOTE" \
	'Remote validate must read the credential as the tenth positional (POSIX ${10}).'
require_text 'port=${10}' "$REMOTE" \
	'Remote restore must read the port as the tenth positional (POSIX ${10}).'
require_text '[ "$preserve" = 1 ] && set -- "$@" --preserve-destination-lan-ip' "$REMOTE" \
	'Remote validate/restore must forward --preserve-destination-lan-ip to the streamed CLI.'
remote_forward_count=$(grep -c 'preserve" = 1 \] && set -- "\$@" --preserve-destination-lan-ip' "$REMOTE")
[ "$remote_forward_count" -eq 2 ] || { echo 'The remote helper must forward the preserve flag for both validate and restore.' >&2; exit 1; }

echo 'preserve-lan-ip UI/controller/CLI/remote contract checks passed'
