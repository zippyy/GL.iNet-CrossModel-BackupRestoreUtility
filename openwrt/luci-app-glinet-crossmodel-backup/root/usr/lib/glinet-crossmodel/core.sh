#!/bin/sh
# Shared runtime for GL.iNet Cross-Model Backup.
# BusyBox ash/POSIX shell compatible. This file is streamed with the CLI for
# agentless remote operation; do not add dependencies on package-only helpers.

# Consumed by the concatenated streamed CLI later in the same shell process.
# shellcheck disable=SC2034
GCM_CORE_LOADED=1
GCM_FORMAT_VERSION=2
GCM_FORMAT_NAME='glinet-crossmodel/v2'
GCM_PREFIX='glinet-crossmodel'
GCM_TOOL_VERSION='2.0.0'
GCM_MAX_FILE_BYTES=${GCM_MAX_FILE_BYTES:-8388608}
GCM_MAX_TOTAL_BYTES=${GCM_MAX_TOTAL_BYTES:-33554432}
GCM_PATH=${GCM_PATH:-/usr/sbin:/usr/bin:/sbin:/bin}
PATH=$GCM_PATH
export PATH

gcm_log() { printf '%s\n' "$*"; }
gcm_die() { gcm_log "ERROR: $*" >&2; return 1; }
gcm_have() { command -v "$1" >/dev/null 2>&1; }
gcm_trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
gcm_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

gcm_json_escape() {
	printf '%s' "$1" | awk 'BEGIN{ORS=""} {
		if (NR > 1) printf "\\n";
		gsub(/\\/, "\\\\"); gsub(/\"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r");
		printf "%s", $0
	}'
}

gcm_json_array_file() {
	file=$1
	first=1
	printf '['
	[ -f "$file" ] && while IFS= read -r item || [ -n "${item:-}" ]; do
		[ -n "$item" ] || continue
		[ "$first" -eq 1 ] || printf ','
		first=0
		printf '"%s"' "$(gcm_json_escape "$item")"
	done < "$file"
	printf ']'
}

gcm_valid_uuid() {
	case "$1" in ''|*[!A-Fa-f0-9-]*) return 1 ;; esac
	[ "${#1}" -ge 8 ] && [ "${#1}" -le 64 ]
}

gcm_uuid() {
	if [ -r /proc/sys/kernel/random/uuid ]; then
		value=$(gcm_trim "$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)")
		if gcm_valid_uuid "$value"; then printf '%s\n' "$value"; return; fi
	fi
	seed="$(date +%s 2>/dev/null || printf 0)-$$-$(uname -n 2>/dev/null || printf router)"
	if gcm_have sha256sum; then
		digest=$(printf '%s' "$seed" | sha256sum | awk '{print $1}')
	else
		digest=$(printf '%s' "$seed" | cksum | awk '{print $1}')
	fi
	printf '%s-%s-%s-%s-%s\n' "$(printf '%s' "$digest" | cut -c1-8)" "$(printf '%s' "$digest" | cut -c9-12)" "$(printf '%s' "$digest" | cut -c13-16)" "$(printf '%s' "$digest" | cut -c17-20)" "$(printf '%s' "$digest" | cut -c21-32)"
}

gcm_valid_strategy() {
	case "$1" in portable|clone|remote-safe|snapshot) return 0 ;; *) return 1 ;; esac
}

gcm_strategy_label() {
	case "$1" in
		portable) printf 'Portable Profile\n' ;;
		clone) printf 'Clone\n' ;;
		remote-safe) printf 'Remote-Safe Clone\n' ;;
		snapshot) printf 'Device Snapshot\n' ;;
		*) printf 'Unknown\n' ;;
	esac
}

gcm_has_category() {
	case ",$1," in *,$2,*) return 0 ;; *) return 1 ;; esac
}

gcm_valid_categories() {
	rest=$1
	canonical=''
	[ -n "$rest" ] || return 1
	while [ -n "$rest" ]; do
		part=${rest%%,*}
		if [ "$rest" = "$part" ]; then rest=''; else rest=${rest#*,}; fi
		case "$part" in wifi|lan|dhcp|dns|firewall|timezone|ddns|vpn|packages|persistent|custom-files|custom-binaries) ;;
			*) return 1 ;;
		esac
		case ",$canonical," in *,$part,*) ;; *) canonical="${canonical:+$canonical,}$part" ;; esac
	done
	printf '%s\n' "$canonical"
}

gcm_safe_absolute_path() {
	raw=$1
	case "$raw" in /*) ;; *) return 1 ;; esac
	case "$raw" in /|*//*|*\"*|*\'*|*[!A-Za-z0-9_./+@%:,=-]*) return 1 ;; esac
	case "/${raw#/}/" in */./*|*/../*) return 1 ;; esac
	printf '%s\n' "$raw"
}

gcm_safe_member() {
	raw=${1#./}
	case "$raw" in '') return 1 ;; /*|*//*|*\\*|*[!A-Za-z0-9_./+@%:,=-]*) return 1 ;; esac
	case "/$raw/" in */./*|*/../*) return 1 ;; esac
	return 0
}

gcm_member_under_prefix() {
	raw=${1#./}
	case "$raw" in "$GCM_PREFIX"|"$GCM_PREFIX"/*) return 0 ;; *) return 1 ;; esac
}

gcm_check_archive_members() {
	archive=$1
	mode=${2:-v2}
	[ -f "$archive" ] || gcm_die 'Archive is missing.' || return 1
	members=$(mktemp /tmp/gcm-members.XXXXXX) || return 1
	if ! tar -tzf "$archive" > "$members" 2>/dev/null; then
		rm -f "$members"; gcm_die 'Archive is malformed or unreadable.'; return 1
	fi
	[ -s "$members" ] || { rm -f "$members"; gcm_die 'Archive is empty.'; return 1; }
	member_count=$(wc -l < "$members" | tr -d ' ')
	[ "$member_count" -le 5000 ] || { rm -f "$members"; gcm_die 'Archive has too many members.'; return 1; }
	if sed 's#^\./##' "$members" | sort | uniq -d | grep -q .; then rm -f "$members"; gcm_die 'Archive contains duplicate member paths.'; return 1; fi
	while IFS= read -r member || [ -n "$member" ]; do
		gcm_safe_member "$member" || { rm -f "$members"; gcm_die "Archive contains an unsafe member: $member"; return 1; }
		case "$mode" in
			v2) gcm_member_under_prefix "$member" || { rm -f "$members"; gcm_die "Archive contains an unexpected top-level member: $member"; return 1; } ;;
			legacy) case "${member#./}" in profile|profile/*) ;; *) rm -f "$members"; gcm_die "Legacy archive contains data outside profile/: $member"; return 1 ;; esac ;;
		esac
	done < "$members"
	# Only regular files and directories are legal. This also rejects links,
	# FIFOs, sockets, block/character devices, and other extraction side effects.
	if tar -tzvf "$archive" 2>/dev/null | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END{exit bad?0:1}'; then
		rm -f "$members"; gcm_die 'Archive contains a non-file/non-directory member.'; return 1
	fi
	rm -f "$members"
}

gcm_archive_kind() {
	archive=$1
	first=$(tar -tzf "$archive" 2>/dev/null | sed -n '1p' || true)
	case "${first#./}" in
		"$GCM_PREFIX"|"$GCM_PREFIX"/*) printf 'v2\n' ;;
		profile|profile/*) printf 'legacy-v1\n' ;;
		*) printf 'unknown\n' ;;
	esac
}

gcm_extract_archive() {
	archive=$1
	destination=$2
	kind=$(gcm_archive_kind "$archive")
	case "$kind" in
		v2) gcm_check_archive_members "$archive" v2 || return 1 ;;
		legacy-v1) gcm_check_archive_members "$archive" legacy || return 1 ;;
		*) gcm_die 'Archive does not use a supported v2 or legacy v1 prefix.'; return 1 ;;
	esac
	mkdir -p "$destination" || return 1
	tar -C "$destination" -xzf "$archive" || { gcm_die 'Archive extraction failed.'; return 1; }
	printf '%s\n' "$kind"
}

gcm_manifest_field() {
	manifest=$1
	field=$2
	if gcm_have jsonfilter; then
		jsonfilter -i "$manifest" -e "@.$field" 2>/dev/null | sed -n '1p'
		return
	fi
	sed -n 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p;s/.*"'"$field"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p;s/.*"'"$field"'"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$manifest" | sed -n '1p'
}

gcm_validate_v2_manifest() {
	manifest=$1
	[ -f "$manifest" ] || { gcm_die 'Archive is missing manifest.json.'; return 1; }
	manifest_format=$(gcm_manifest_field "$manifest" format)
	manifest_version=$(gcm_manifest_field "$manifest" format_version)
	manifest_strategy=$(gcm_manifest_field "$manifest" backup_strategy)
	manifest_profile_id=$(gcm_manifest_field "$manifest" profile_uuid)
	[ "$manifest_format" = "$GCM_FORMAT_NAME" ] || { gcm_die 'Manifest format identifier is invalid.'; return 1; }
	[ "$manifest_version" = "$GCM_FORMAT_VERSION" ] || { gcm_die "Unsupported archive format version: ${manifest_version:-missing}"; return 1; }
	gcm_valid_strategy "$manifest_strategy" || { gcm_die 'Manifest backup strategy is invalid.'; return 1; }
	gcm_valid_uuid "$manifest_profile_id" || { gcm_die 'Manifest profile UUID is invalid.'; return 1; }
	if [ "$manifest_strategy" = snapshot ]; then
		manifest_fingerprint=$(gcm_manifest_field "$manifest" device_fingerprint)
		case "$manifest_fingerprint" in *[!A-Fa-f0-9]*|'') gcm_die 'Device Snapshot fingerprint is invalid.'; return 1 ;; esac
		[ "${#manifest_fingerprint}" -eq 64 ] || { gcm_die 'Device Snapshot fingerprint length is invalid.'; return 1; }
	fi
}

gcm_generate_checksums() {
	root=$1
	list=$(mktemp /tmp/gcm-check-list.XXXXXX) || return 1
	(
		cd "$root" || exit 1
		find "$GCM_PREFIX" -type f ! -name checksums.sha256 | sort > "$list"
		while IFS= read -r path || [ -n "$path" ]; do
			gcm_safe_member "$path" || exit 1
			sha256sum "$path"
		done < "$list" > "$GCM_PREFIX/checksums.sha256"
	) || { rm -f "$list"; gcm_die 'Could not generate SHA-256 payload hashes.'; return 1; }
	rm -f "$list"
}

gcm_verify_checksums() {
	prefix_dir=$1
	checksums="$prefix_dir/checksums.sha256"
	[ -s "$checksums" ] || { gcm_die 'Archive is missing checksums.sha256.'; return 1; }
	if awk '{print $2}' "$checksums" | sort | uniq -d | grep -q .; then gcm_die 'SHA-256 manifest contains duplicate member paths.'; return 1; fi
	actual=$(mktemp /tmp/gcm-hash-actual.XXXXXX) || return 1
	declared=$(mktemp /tmp/gcm-hash-declared.XXXXXX) || { rm -f "$actual"; return 1; }
	(
		cd "$(dirname "$prefix_dir")" || exit 1
		find "$GCM_PREFIX" -type f ! -name checksums.sha256 | sort > "$actual"
	) || { rm -f "$actual" "$declared"; gcm_die 'Could not enumerate archive payload members.'; return 1; }
	awk '{print $2}' "$checksums" | sort > "$declared"
	if ! cmp -s "$actual" "$declared"; then
		rm -f "$actual" "$declared"
		gcm_die 'SHA-256 manifest does not exactly cover every archive payload file.'
		return 1
	fi
	rm -f "$actual" "$declared"
	while IFS= read -r line || [ -n "$line" ]; do
		hash=${line%% *}
		path=${line#*  }
		[ "$path" != "$line" ] || { gcm_die 'Malformed SHA-256 manifest entry.'; return 1; }
		case "$hash" in *[!A-Fa-f0-9]*|'') gcm_die 'Malformed SHA-256 digest.'; return 1 ;; esac
		[ "${#hash}" -eq 64 ] || { gcm_die 'Malformed SHA-256 digest length.'; return 1; }
		gcm_safe_member "$path" || { gcm_die "Unsafe SHA-256 member path: $path"; return 1; }
		case "$path" in "$GCM_PREFIX"/*) ;; *) gcm_die "SHA-256 entry is outside $GCM_PREFIX/: $path"; return 1 ;; esac
		[ -f "$(dirname "$prefix_dir")/$path" ] || { gcm_die "SHA-256 entry references a missing payload: $path"; return 1; }
	done < "$checksums"
	(cd "$(dirname "$prefix_dir")" && sha256sum -c "$GCM_PREFIX/checksums.sha256" >/dev/null 2>&1) || { gcm_die 'Archive SHA-256 verification failed.'; return 1; }
}

gcm_board_json_value() {
	field=$1
	if [ -s /etc/board.json ] && gcm_have jsonfilter; then
		jsonfilter -i /etc/board.json -e "$field" 2>/dev/null | sed -n '1p'
	fi
}

gcm_source_model() {
	model=$(cat /tmp/sysinfo/model 2>/dev/null || true)
	[ -n "$model" ] || model=$(gcm_board_json_value '@.model.name')
	[ -n "$model" ] || model=$(gcm_board_json_value '@.model')
	[ -n "$model" ] || model='OpenWrt router'
	printf '%s\n' "$model"
}

gcm_board_name() {
	board=$(cat /tmp/sysinfo/board_name 2>/dev/null || true)
	[ -n "$board" ] || board=$(gcm_board_json_value '@.board_name')
	printf '%s\n' "${board:-unknown}"
}

gcm_openwrt_version() {
	version=''
	[ -r /etc/openwrt_release ] && . /etc/openwrt_release
	version=${DISTRIB_RELEASE:-}
	[ -n "$version" ] || version=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.version' 2>/dev/null || true)
	printf '%s\n' "${version:-unknown}"
}

gcm_firmware_version() {
	version=$(cat /etc/glversion 2>/dev/null || true)
	[ -n "$version" ] || version=$(gcm_openwrt_version)
	printf '%s\n' "${version:-unknown}"
}

gcm_architecture() {
	arch=''
	[ -r /etc/openwrt_release ] && . /etc/openwrt_release
	arch=${DISTRIB_ARCH:-}
	[ -n "$arch" ] || arch=$(uname -m 2>/dev/null || true)
	printf '%s\n' "${arch:-unknown}"
}

gcm_supported_package_arches() {
	if gcm_have opkg; then opkg print-architecture 2>/dev/null | awk '$1=="arch"{print $2}'; fi
	printf 'all\nnoarch\n%s\n' "$(gcm_architecture)"
}

gcm_opkg_run() {
	if gcm_have timeout; then timeout 30 opkg "$@"; else opkg "$@"; fi
}

gcm_package_arch_compatible() {
	package_arch=$1
	supported=$2
	case "$package_arch" in ''|all|noarch) return 0 ;; esac
	case " $supported " in *" $package_arch "*) return 0 ;; *) return 1 ;; esac
}

gcm_elf_signature() {
	file=$1
	[ -f "$file" ] || return 1
	header=$(dd if="$file" bs=1 count=20 2>/dev/null | od -An -tu1) || return 1
	set -- $header
	[ "$#" -ge 20 ] || return 1
	[ "$1" = 127 ] && [ "$2" = 69 ] && [ "$3" = 76 ] && [ "$4" = 70 ] || return 1
	class=$5; data=$6; osabi=$8; low=${19}; high=${20}
	case "$data" in 1) machine=$((low + high * 256)) ;; 2) machine=$((high + low * 256)) ;; *) return 1 ;; esac
	printf '%s:%s:%s:%s\n' "$class" "$data" "$machine" "$osabi"
}

gcm_expected_elf() {
	case "$(gcm_lower "$1")" in
		aarch64*|arm64*) printf '2:183\n' ;;
		arm*) printf '1:40\n' ;;
		mips64*) printf '2:8\n' ;;
		mips*) printf '1:8\n' ;;
		x86_64*|amd64*) printf '2:62\n' ;;
		i386*|i486*|i586*|i686*|x86*) printf '1:3\n' ;;
		riscv64*) printf '2:243\n' ;;
		powerpc64*|ppc64*) printf '2:21\n' ;;
		powerpc*|ppc*) printf '1:20\n' ;;
		*) printf 'unknown\n' ;;
	esac
}

gcm_binary_compatible() {
	file=$1
	target_arch=$2
	signature=$(gcm_elf_signature "$file") || return 1
	expected=$(gcm_expected_elf "$target_arch")
	[ "$expected" = unknown ] && return 0
	expected_class=${expected%%:*}
	expected_machine=${expected#*:}
	case "$signature" in "$expected_class":*:"$expected_machine":*) return 0 ;; *) return 1 ;; esac
}

gcm_platform_adapter() {
	if [ -s /etc/glversion ]; then
		case "$(cat /etc/glversion 2>/dev/null)" in 4.*|v4.*) printf 'glinet-4\n'; return ;; esac
	fi
	printf 'openwrt-uci\n'
}

gcm_gl_rpc_has() {
	method=$1
	[ "$(gcm_platform_adapter)" = glinet-4 ] || return 1
	gcm_have ubus || return 1
	ubus -v list uci 2>/dev/null | grep -q "[\"']${method}[\"']"
}

gcm_adapter_set() {
	adapter_package=$1; adapter_section=$2; adapter_option=$3; adapter_value=$4
	if gcm_gl_rpc_has set && case "$adapter_section" in @*) false ;; *) true ;; esac; then
		adapter_request=$(printf '{"config":"%s","section":"%s","values":{"%s":"%s"}}' "$(gcm_json_escape "$adapter_package")" "$(gcm_json_escape "$adapter_section")" "$(gcm_json_escape "$adapter_option")" "$(gcm_json_escape "$adapter_value")")
		if ubus call uci set "$adapter_request" >/dev/null 2>&1; then return 0; fi
	fi
	uci set "$adapter_package.$adapter_section.$adapter_option=$adapter_value"
}

gcm_adapter_commit() {
	adapter_commit_package=$1
	if gcm_gl_rpc_has commit; then
		adapter_commit_request=$(printf '{"config":"%s"}' "$(gcm_json_escape "$adapter_commit_package")")
		if ubus call uci commit "$adapter_commit_request" >/dev/null 2>&1; then return 0; fi
	fi
	uci commit "$adapter_commit_package"
}

gcm_band_from_values() {
	band=$1
	hwmode=$2
	channel=$3
	hint=$4
	case "$(gcm_lower "$band")" in 2g|2.4g|2.4ghz) printf '2.4\n'; return ;; 5g|5ghz) printf '5\n'; return ;; 6g|6ghz) printf '6\n'; return ;; esac
	case "$(gcm_lower "$hwmode")" in *11b*|*11g*) printf '2.4\n'; return ;; *11a*) printf '5\n'; return ;; esac
	case "$channel" in ''|auto) ;; *[!0-9]*) ;; *) [ "$channel" -le 14 ] 2>/dev/null && { printf '2.4\n'; return; } ;; esac
	# The section name is only a final discovery hint; it is never persisted as
	# the portable identity of a radio.
	case "$(gcm_lower "$hint")" in *6g*) printf '6\n' ;; *5g*) printf '5\n' ;; *2g*) printf '2.4\n' ;; *) printf 'unknown\n' ;; esac
}

gcm_radio_band() {
	radio=$1
	band=$(uci -q get "wireless.$radio.band" 2>/dev/null || true)
	hwmode=$(uci -q get "wireless.$radio.hwmode" 2>/dev/null || true)
	channel=$(uci -q get "wireless.$radio.channel" 2>/dev/null || true)
	gcm_band_from_values "$band" "$hwmode" "$channel" "$radio"
}

gcm_firewall_zone_exists() {
	zone=$1
	zones=$2
	case " $zones " in *" $zone "*) return 0 ;; *) return 1 ;; esac
}

gcm_model_known() {
	case "$(gcm_lower "$1")" in ''|unknown|'openwrt router'|'generic openwrt') return 1 ;; *) return 0 ;; esac
}

gcm_strategy_compatible() {
	strategy=$1; source_model=$2; target_model=$3; source_fingerprint=$4; target_fingerprint=$5; override=$6
	case "$strategy" in
		portable|legacy-portable) return 0 ;;
		clone|remote-safe) gcm_model_known "$source_model" && gcm_model_known "$target_model" && [ "$(gcm_lower "$source_model")" = "$(gcm_lower "$target_model")" ] ;;
		snapshot) [ "$override" = 1 ] || { [ -n "$source_fingerprint" ] && [ "$source_fingerprint" != unavailable ] && [ "$source_fingerprint" = "$target_fingerprint" ]; } ;;
		*) return 1 ;;
	esac
}

gcm_detect_bands() {
	uci -q show wireless 2>/dev/null | sed -n 's/^wireless\.\([^=]*\)=wifi-device$/\1/p' | while IFS= read -r radio; do
		gcm_radio_band "$radio"
	done | awk '$0!="unknown"&&!seen[$0]++' | sort
}

gcm_capability_csv() {
	caps="adapter:$(gcm_platform_adapter)"
	for band in $(gcm_detect_bands); do caps="$caps,wifi-$band-ghz"; done
	[ -x /etc/init.d/gl_ddns ] && caps="$caps,gl-ddns"
	gcm_gl_rpc_has set && caps="$caps,gl-jsonrpc-uci"
	gcm_have nft && caps="$caps,firewall4"
	gcm_have iptables && caps="$caps,firewall3"
	gcm_have wg && caps="$caps,wireguard"
	[ -e /dev/net/tun ] && caps="$caps,tun"
	printf '%s\n' "$caps"
}

gcm_device_fingerprint() {
	material=$(mktemp /tmp/gcm-fingerprint.XXXXXX) || return 1
	{
		printf 'board=%s\n' "$(gcm_board_name)"
		printf 'model=%s\n' "$(gcm_source_model)"
		for serial_file in /proc/device-tree/serial-number /sys/firmware/devicetree/base/serial-number /tmp/sysinfo/board_serial; do
			[ -r "$serial_file" ] && { printf 'serial='; tr -d '\000\r\n' < "$serial_file"; printf '\n'; break; }
		done
		if [ -s /etc/board.json ]; then
			sed -n 's/.*"macaddr"[[:space:]]*:[[:space:]]*"\([0-9A-Fa-f:]*\)".*/factory-mac=\1/p' /etc/board.json | sort -u
		fi
	} > "$material"
	# Refuse a weak fingerprint that contains only fallback/unknown fields.
	if ! grep -q '^serial=.' "$material" && ! grep -q '^factory-mac=.' "$material"; then
		rm -f "$material"; printf 'unavailable\n'; return
	fi
	sha256sum "$material" | awk '{print $1}'
	rm -f "$material"
}

gcm_facts_json() {
	hostname=$(uci -q get system.@system[0].hostname 2>/dev/null || hostname 2>/dev/null || printf router)
	bands=$(mktemp /tmp/gcm-bands.XXXXXX) || return 1
	gcm_detect_bands > "$bands"
	printf '{"tool_version":"%s","adapter":"%s","hostname":"%s","model":"%s","board":"%s","firmware":"%s","openwrt":"%s","architecture":"%s","kernel":"%s","device_fingerprint":"%s","bands":' \
		"$GCM_TOOL_VERSION" "$(gcm_platform_adapter)" "$(gcm_json_escape "$hostname")" "$(gcm_json_escape "$(gcm_source_model)")" "$(gcm_json_escape "$(gcm_board_name)")" "$(gcm_json_escape "$(gcm_firmware_version)")" "$(gcm_json_escape "$(gcm_openwrt_version)")" "$(gcm_json_escape "$(gcm_architecture)")" "$(gcm_json_escape "$(uname -r 2>/dev/null || printf unknown)")" "$(gcm_device_fingerprint)"
	gcm_json_array_file "$bands"
	printf ',"capabilities":"%s"}\n' "$(gcm_json_escape "$(gcm_capability_csv)")"
	rm -f "$bands"
}

gcm_package_status_tsv() {
	status=${1:-/usr/lib/opkg/status}
	[ -r "$status" ] || return 0
	awk -v kernel="$(uname -r 2>/dev/null || printf unknown)" '
		function emit(){
			if(name!="" && status ~ / installed$/){
				user=(status ~ / user installed$/ && auto!="yes" && auto!="1")?"true":"false";
				kmod=(name ~ /^kmod-/ || section ~ /kernel/)?"true":"false";
				gsub(/\t/," ",desc); gsub(/\t/," ",depends);
				printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",name,version,arch,section,desc,depends,size,user,kmod
			}
			name=version=arch=section=desc=depends=size=status=auto=""
		}
		BEGIN{name=""}
		/^$/ {emit(); next}
		/^Package: / {name=substr($0,10); next}
		/^Version: / {version=substr($0,10); next}
		/^Architecture: / {arch=substr($0,15); next}
		/^Section: / {section=substr($0,10); next}
		/^Description: / {desc=substr($0,14); next}
		/^Depends: / {depends=substr($0,10); next}
		/^Installed-Size: / {size=substr($0,17); next}
		/^Status: / {status=substr($0,9); next}
		/^Auto-Installed: / {auto=tolower(substr($0,17)); next}
		END{emit()}
	' "$status"
}

gcm_packages_json() {
	destination=$1
	tsv=$2
	printf '{"source_kernel":"%s","packages":[' "$(gcm_json_escape "$(uname -r 2>/dev/null || printf unknown)")" > "$destination"
	first=1
	while IFS="$(printf '\t')" read -r name version arch section description depends size user kmod || [ -n "${name:-}" ]; do
		[ -n "$name" ] || continue
		[ "$first" -eq 1 ] || printf ',' >> "$destination"
		first=0
		case "$size" in ''|*[!0-9]*) size=0 ;; esac
		printf '{"name":"%s","version":"%s","architecture":"%s","section":"%s","description":"%s","dependencies":"%s","installed_size":%s,"user_installed":%s,"kmod":%s,"source_kernel":"%s"}' \
			"$(gcm_json_escape "$name")" "$(gcm_json_escape "$version")" "$(gcm_json_escape "$arch")" "$(gcm_json_escape "$section")" "$(gcm_json_escape "$description")" "$(gcm_json_escape "$depends")" "$size" "$user" "$kmod" "$(gcm_json_escape "$(uname -r 2>/dev/null || printf unknown)")" >> "$destination"
	done < "$tsv"
	printf ']}\n' >> "$destination"
}

gcm_csv_json_array() {
	value=$1
	tmp=$(mktemp /tmp/gcm-csv.XXXXXX) || return 1
	: > "$tmp"
	while [ -n "$value" ]; do
		part=${value%%,*}
		if [ "$value" = "$part" ]; then value=''; else value=${value#*,}; fi
		[ -n "$part" ] && printf '%s\n' "$part" >> "$tmp"
	done
	gcm_json_array_file "$tmp"
	rm -f "$tmp"
}

gcm_save_uci_export() {
	package=$1
	destination=$2
	if uci -q show "$package" >/dev/null 2>&1; then
		uci -q export "$package" > "$destination" 2>/dev/null || true
		[ -s "$destination" ] || rm -f "$destination"
	fi
}

gcm_portable_add() {
	config_dir=$1
	type=$2
	shift 2
	section=$(uci -c "$config_dir" add profile "$type" 2>/dev/null) || return 1
	while [ "$#" -ge 2 ]; do
		option=$1
		value=$2
		shift 2
		[ -n "$value" ] || continue
		uci -c "$config_dir" set "profile.$section.$option=$value" 2>/dev/null || return 1
	done
}

gcm_uci_get() { uci -q get "$1" 2>/dev/null || true; }

gcm_capture_portable_wifi() {
	config_dir=$1
	uci -q show wireless 2>/dev/null | sed -n 's/^wireless\.\([^=]*\)=wifi-iface$/\1/p' | while IFS= read -r iface; do
		device=$(gcm_uci_get "wireless.$iface.device")
		band=$(gcm_radio_band "$device")
		ssid=$(gcm_uci_get "wireless.$iface.ssid")
		network=$(gcm_uci_get "wireless.$iface.network")
		disabled=$(gcm_uci_get "wireless.$iface.disabled")
		case "$(gcm_lower "$network $iface $ssid")" in *guest*) role=guest ;; *lan*) role=main ;; *) role=other ;; esac
		case "$disabled" in 1|true|yes) enabled=0 ;; *) enabled=1 ;; esac
		gcm_portable_add "$config_dir" wifi \
			band "$band" role "$role" ssid "$ssid" enabled "$enabled" \
			encryption "$(gcm_uci_get "wireless.$iface.encryption")" \
			key "$(gcm_uci_get "wireless.$iface.key")" \
			hidden "$(gcm_uci_get "wireless.$iface.hidden")" \
			isolation "$(gcm_uci_get "wireless.$iface.isolate")" \
			ieee80211r "$(gcm_uci_get "wireless.$iface.ieee80211r")" \
			mobility_domain "$(gcm_uci_get "wireless.$iface.mobility_domain")" || exit 1
	done
}

gcm_capture_portable_lan_dhcp_dns() {
	config_dir=$1
	if uci -q get network.lan >/dev/null 2>&1; then
		gcm_portable_add "$config_dir" lan \
			protocol "$(gcm_uci_get network.lan.proto)" \
			address "$(gcm_uci_get network.lan.ipaddr)" \
			netmask "$(gcm_uci_get network.lan.netmask)" \
			gateway "$(gcm_uci_get network.lan.gateway)" \
			dns "$(gcm_uci_get network.lan.dns)"
	fi
	if uci -q get dhcp.lan >/dev/null 2>&1; then
		gcm_portable_add "$config_dir" dhcp \
			start "$(gcm_uci_get dhcp.lan.start)" \
			limit "$(gcm_uci_get dhcp.lan.limit)" \
			leasetime "$(gcm_uci_get dhcp.lan.leasetime)" \
			ignore "$(gcm_uci_get dhcp.lan.ignore)" \
			dhcpv6 "$(gcm_uci_get dhcp.lan.dhcpv6)" \
			ra "$(gcm_uci_get dhcp.lan.ra)"
	fi
	uci -q show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^=]*\)=host$/\1/p' | while IFS= read -r host; do
		gcm_portable_add "$config_dir" reservation \
			name "$(gcm_uci_get "dhcp.$host.name")" \
			mac "$(gcm_uci_get "dhcp.$host.mac")" \
			ip "$(gcm_uci_get "dhcp.$host.ip")" \
			hostid "$(gcm_uci_get "dhcp.$host.hostid")" || exit 1
	done
	if uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1; then
		gcm_portable_add "$config_dir" dns \
			servers "$(gcm_uci_get dhcp.@dnsmasq[0].server)" \
			local "$(gcm_uci_get dhcp.@dnsmasq[0].local)" \
			domain "$(gcm_uci_get dhcp.@dnsmasq[0].domain)" \
			rebind_protection "$(gcm_uci_get dhcp.@dnsmasq[0].rebind_protection)" \
			localservice "$(gcm_uci_get dhcp.@dnsmasq[0].localservice)"
	fi
}

gcm_capture_portable_firewall() {
	config_dir=$1
	uci -q show firewall 2>/dev/null | sed -n 's/^firewall\.\([^=]*\)=\(rule\|redirect\)$/\1 \2/p' | while read -r section kind; do
		case "$kind" in
			rule)
				gcm_portable_add "$config_dir" firewall_rule \
					name "$(gcm_uci_get "firewall.$section.name")" src "$(gcm_uci_get "firewall.$section.src")" \
					dest "$(gcm_uci_get "firewall.$section.dest")" proto "$(gcm_uci_get "firewall.$section.proto")" \
					src_ip "$(gcm_uci_get "firewall.$section.src_ip")" dest_ip "$(gcm_uci_get "firewall.$section.dest_ip")" \
					src_port "$(gcm_uci_get "firewall.$section.src_port")" dest_port "$(gcm_uci_get "firewall.$section.dest_port")" \
					target "$(gcm_uci_get "firewall.$section.target")" family "$(gcm_uci_get "firewall.$section.family")" \
					enabled "$(gcm_uci_get "firewall.$section.enabled")" || exit 1
				;;
			redirect)
				gcm_portable_add "$config_dir" port_forward \
					name "$(gcm_uci_get "firewall.$section.name")" src "$(gcm_uci_get "firewall.$section.src")" \
					dest "$(gcm_uci_get "firewall.$section.dest")" proto "$(gcm_uci_get "firewall.$section.proto")" \
					src_dport "$(gcm_uci_get "firewall.$section.src_dport")" dest_ip "$(gcm_uci_get "firewall.$section.dest_ip")" \
					dest_port "$(gcm_uci_get "firewall.$section.dest_port")" target "$(gcm_uci_get "firewall.$section.target")" \
					enabled "$(gcm_uci_get "firewall.$section.enabled")" || exit 1
				;;
		esac
	done
}

gcm_capture_portable_ddns() {
	config_dir=$1
	if uci -q show gl_ddns >/dev/null 2>&1; then
		# GL DDNS domain/account fields are device-bound. Only portable user
		# preferences are retained; restore reinitializes identity locally.
		uci -q show gl_ddns 2>/dev/null | sed -n 's/^gl_ddns\.\([^.=]*\)=.*/\1/p' | sort -u | while IFS= read -r source; do
			case "$(gcm_lower "$source")" in *v6*) family=ipv6 ;; *) family=ipv4 ;; esac
			gcm_portable_add "$config_dir" gl_ddns \
				family "$family" enabled "$(gcm_uci_get "gl_ddns.$source.enabled")" \
				enabled_ssh "$(gcm_uci_get "gl_ddns.$source.enabled_ssh")" \
				http_port "$(gcm_uci_get "gl_ddns.$source.http_port")" \
				https_port "$(gcm_uci_get "gl_ddns.$source.https_port")" || exit 1
		done
	elif uci -q show ddns >/dev/null 2>&1; then
		uci -q show ddns 2>/dev/null | sed -n 's/^ddns\.\([^=]*\)=service$/\1/p' | while IFS= read -r section; do
			gcm_portable_add "$config_dir" ddns \
				name "$(gcm_uci_get "ddns.$section.name")" \
				service_name "$(gcm_uci_get "ddns.$section.service_name")" \
				domain "$(gcm_uci_get "ddns.$section.domain")" \
				username "$(gcm_uci_get "ddns.$section.username")" \
				password "$(gcm_uci_get "ddns.$section.password")" \
				ip_source "$(gcm_uci_get "ddns.$section.ip_source")" \
				interface "$(gcm_uci_get "ddns.$section.interface")" \
				enabled "$(gcm_uci_get "ddns.$section.enabled")" || exit 1
		done
	fi
}

gcm_vpn_packages() {
	for path in /etc/config/*; do
		[ -f "$path" ] || continue
		package=${path##*/}
		case "$(gcm_lower "$package")" in *wireguard*|wgclient*|wgserver*|*openvpn*|ovpn*|*vpnpolicy*|gl_vpn|*amnezia*|awg*) printf '%s\n' "$package" ;; esac
	done | sort -u
}

gcm_extract_network_vpn_blocks() {
	source=$1
	destination=$2
	awk 'BEGIN{RS=""; ORS="\n\n"} {lower=tolower($0); if(lower ~ /option[[:space:]]+proto[[:space:]]+[^a-z0-9]*(wireguard|amneziawg|awg)/ || lower ~ /^config[[:space:]]+(wireguard_|amneziawg_|awg_)/) print}' "$source" > "$destination"
}

gcm_capture_portable_network_vpn() {
	vpn_dir=$1
	export_file=$(mktemp /tmp/gcm-network-vpn.XXXXXX) || return 1
	uci -q export network > "$export_file" 2>/dev/null || { rm -f "$export_file"; return 0; }
	gcm_extract_network_vpn_blocks "$export_file" "$vpn_dir/network"
	rm -f "$export_file"
	if [ -s "$vpn_dir/network" ]; then
		gcm_sanitize_file "$vpn_dir/network"
		gcm_remove_uci_options "$vpn_dir/network" 'device ifname macaddr private_key privatekey preshared_key secret token authkey'
	else rm -f "$vpn_dir/network"; fi
}

gcm_sanitize_file() {
	file=$1
	[ -f "$file" ] || return 0
	temporary="$file.gcm-sanitize.$$"
	sed \
		-e '/^[[:space:]]*option[[:space:]][[:space:]]*macaddr[[:space:]]/d' \
		-e '/^[[:space:]]*option[[:space:]][[:space:]]*private_key[[:space:]]/d' \
		-e '/^[[:space:]]*option[[:space:]][[:space:]]*preshared_key[[:space:]]/d' \
		-e '/^[[:space:]]*option[[:space:]][[:space:]]*privatekey[[:space:]]/d' \
		-e '/^[[:space:]]*option[[:space:]][[:space:]]*secret[[:space:]]/d' \
		-e '/^[[:space:]]*option[[:space:]][[:space:]]*token[[:space:]]/d' \
		-e '/^[[:space:]]*option[[:space:]][[:space:]]*authkey[[:space:]]/d' \
		-e '/^[[:space:]]*option[[:space:]][[:space:]]*device_id[[:space:]]/d' \
		-e '/^[[:space:]]*option[[:space:]][[:space:]]*serial[[:space:]]/d' "$file" > "$temporary" || { rm -f "$temporary"; return 1; }
	cat "$temporary" > "$file"
	rm -f "$temporary"
}

gcm_remove_uci_options() {
	file=$1
	options=$2
	[ -f "$file" ] || return 0
	temporary="$file.gcm-options.$$"
	awk -v denied="$options" '
		BEGIN { count=split(denied, names, " "); for(i=1;i<=count;i++) block[names[i]]=1 }
		$1=="option" && block[$2] { next }
		{ print }
	' "$file" > "$temporary" || { rm -f "$temporary"; return 1; }
	cat "$temporary" > "$file"
	rm -f "$temporary"
}

gcm_capture_portable() {
	prefix_dir=$1
	categories=$2
	config_dir="$prefix_dir/portable"
	mkdir -p "$config_dir/vpn"
	: > "$config_dir/profile"
	if gcm_has_category "$categories" wifi; then gcm_capture_portable_wifi "$config_dir"; fi
	if gcm_has_category "$categories" lan || gcm_has_category "$categories" dhcp || gcm_has_category "$categories" dns; then gcm_capture_portable_lan_dhcp_dns "$config_dir"; fi
	if gcm_has_category "$categories" firewall; then gcm_capture_portable_firewall "$config_dir"; fi
	if gcm_has_category "$categories" timezone; then
		gcm_portable_add "$config_dir" timezone \
			zonename "$(gcm_uci_get system.@system[0].zonename)" timezone "$(gcm_uci_get system.@system[0].timezone)"
	fi
	if gcm_has_category "$categories" ddns; then gcm_capture_portable_ddns "$config_dir"; fi
	if gcm_has_category "$categories" vpn; then
		gcm_vpn_packages | while IFS= read -r package; do
			gcm_save_uci_export "$package" "$config_dir/vpn/$package"
			gcm_sanitize_file "$config_dir/vpn/$package"
			case "$(gcm_lower "$package")" in
				*wireguard*|wgclient*|wgserver*|*amnezia*|awg*) gcm_remove_uci_options "$config_dir/vpn/$package" 'private_key privatekey preshared_key secret token authkey' ;;
				*openvpn*|ovpn*) gcm_remove_uci_options "$config_dir/vpn/$package" 'username password auth_user_pass private_key key cert ca tls_auth tls_crypt secret token' ;;
			esac
		done
		gcm_capture_portable_network_vpn "$config_dir/vpn" || return 1
	fi
	uci -c "$config_dir" commit profile 2>/dev/null || true
	printf '%s\n' "$(gcm_platform_adapter)" > "$config_dir/source-adapter.txt"
}

gcm_raw_excluded_package() {
	strategy=$1
	package=$2
	case "$strategy:$package" in
		clone:gl-cloud|clone:tailscale|clone:zerotier) return 0 ;;
		remote-safe:gl-cloud|remote-safe:glconfig|remote-safe:tailscale|remote-safe:zerotier|remote-safe:rtty|remote-safe:dropbear|remote-safe:wan-access) return 0 ;;
	esac
	return 1
}

gcm_raw_package_selected() {
	package=$1
	categories=$2
	case "$(gcm_lower "$package")" in
		wireless) gcm_has_category "$categories" wifi ;;
		network) gcm_has_category "$categories" lan ;;
		dhcp) gcm_has_category "$categories" dhcp || gcm_has_category "$categories" dns ;;
		firewall) gcm_has_category "$categories" firewall ;;
		system) gcm_has_category "$categories" timezone ;;
		gl_ddns|ddns) gcm_has_category "$categories" ddns ;;
		*wireguard*|wgclient*|wgserver*|*openvpn*|ovpn*|*vpnpolicy*|gl_vpn|*amnezia*|awg*) gcm_has_category "$categories" vpn ;;
		*) gcm_has_category "$categories" persistent ;;
	esac
}

gcm_capture_raw_uci() {
	prefix_dir=$1
	strategy=$2
	categories=$3
	excluded=$4
	sanitized=$5
	destination="$prefix_dir/uci"
	mkdir -p "$destination"
	for source in /etc/config/*; do
		[ -f "$source" ] && [ ! -L "$source" ] || continue
		package=${source##*/}
		case "$package" in *[!A-Za-z0-9_.-]*) printf 'uci:%s:unsafe-name\n' "$package" >> "$excluded"; continue ;; esac
		if ! gcm_raw_package_selected "$package" "$categories"; then printf 'uci:%s:not-selected\n' "$package" >> "$excluded"; continue; fi
		if gcm_raw_excluded_package "$strategy" "$package"; then
			printf 'uci:%s:device-or-management-identity\n' "$package" >> "$excluded"
			continue
		fi
		cp -p "$source" "$destination/$package" || return 1
		case "$strategy" in
			clone|remote-safe)
				gcm_sanitize_file "$destination/$package"
				case "$(gcm_lower "$package")" in
					gl_ddns) gcm_remove_uci_options "$destination/$package" 'username domain param_enc lookup_host password device_id token' ;;
					glconfig) gcm_remove_uci_options "$destination/$package" 'ddns mac sn serial device_id token cloud_id' ;;
					*wireguard*|wgclient*|wgserver*|*amnezia*|awg*) gcm_remove_uci_options "$destination/$package" 'private_key privatekey preshared_key secret token' ;;
					*openvpn*|ovpn*) gcm_remove_uci_options "$destination/$package" 'username password auth_user_pass private_key key cert' ;;
				esac
				printf 'uci:%s:mac-crypto-cloud-identity-fields\n' "$package" >> "$sanitized"
				;;
		esac
	done
}

gcm_discover_keep_files() {
	discovered=$1
	: > "$discovered"
	for keep in /lib/upgrade/keep.d/*; do
		[ -f "$keep" ] || continue
		while IFS= read -r pattern || [ -n "$pattern" ]; do
			pattern=$(printf '%s' "$pattern" | sed 's/[[:space:]]*#.*$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
			[ -n "$pattern" ] || continue
			case "$pattern" in /*) ;; *) continue ;; esac
			case "$pattern" in *'..'*) continue ;; esac
			# keep.d entries are trusted firmware declarations. Expansion is
			# constrained to absolute paths and each result is revalidated.
			for candidate in $pattern; do
				gcm_safe_absolute_path "$candidate" >/dev/null 2>&1 || continue
				[ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
				printf '%s\n' "$candidate"
			done
		done < "$keep"
	done | sort -u > "$discovered"
}

gcm_persistent_denied() {
	strategy=$1
	path=$2
	case "$path" in
		/etc/passwd|/etc/shadow|/etc/group|/etc/gshadow) return 0 ;;
		/root/glinet-crossmodel/*|/root/.ssh/known_hosts) return 0 ;;
		/etc/dropbear/dropbear_*_host_key|/etc/ssh/ssh_host_*|/etc/uhttpd.*|/etc/nginx/*.key|/etc/nginx/*.cer) [ "$strategy" = snapshot ] && return 1; return 0 ;;
		*/tailscale/*|*/zerotier-one/*|*/goodcloud/*|*/gl-cloud/*) [ "$strategy" = snapshot ] && return 1; return 0 ;;
		/etc/openvpn/*|/etc/wireguard/*|/etc/amneziawg/*|/etc/awg/*|*/gl_ddns/*) [ "$strategy" = snapshot ] && return 1; return 0 ;;
		*/board.json|*/art.img|*/factory*|*/mtd*) return 0 ;;
	esac
	case "$strategy:$path" in
		remote-safe:/etc/dropbear/*|remote-safe:/root/.ssh/authorized_keys|remote-safe:*/tailscale/*|remote-safe:*/zerotier-one/*|remote-safe:*/goodcloud/*|remote-safe:*/gl-cloud/*|remote-safe:*/rtty/*) return 0 ;;
	esac
	return 1
}

gcm_copy_with_root() {
	source=$1
	destination_root=$2
	relative=${source#/}
	destination="$destination_root/$relative"
	mkdir -p "$(dirname "$destination")" || return 1
	cp -p "$source" "$destination"
}

gcm_capture_persistent() {
	prefix_dir=$1
	strategy=$2
	discovered=$3
	excluded=$4
	[ "$strategy" != portable ] || return 0
	while IFS= read -r path || [ -n "$path" ]; do
		[ -n "$path" ] || continue
		if gcm_persistent_denied "$strategy" "$path"; then
			printf 'persistent:%s:strategy-deny\n' "$path" >> "$excluded"
			continue
		fi
		gcm_copy_with_root "$path" "$prefix_dir/extra" || return 1
	done < "$discovered"
}

gcm_validate_custom_list() {
	input=$1
	output=$2
	binary_only=$3
	total_file=$4
	: > "$output"
	[ -f "$input" ] || return 0
	while IFS= read -r path || [ -n "$path" ]; do
		[ -n "$path" ] || continue
		gcm_safe_absolute_path "$path" >/dev/null || { gcm_die "Unsafe custom path: $path"; return 1; }
		[ -f "$path" ] && [ ! -L "$path" ] || { gcm_die "Custom path is not a regular file: $path"; return 1; }
		size=$(wc -c < "$path" | tr -d ' ')
		case "$size" in ''|*[!0-9]*) gcm_die "Could not size custom file: $path"; return 1 ;; esac
		[ "$size" -le "$GCM_MAX_FILE_BYTES" ] || { gcm_die "Custom file exceeds the per-file limit: $path"; return 1; }
		total=$(cat "$total_file")
		total=$((total + size))
		[ "$total" -le "$GCM_MAX_TOTAL_BYTES" ] || { gcm_die 'Custom files exceed the total size limit.'; return 1; }
		printf '%s\n' "$total" > "$total_file"
		if [ "$binary_only" = 1 ]; then
			magic=$(dd if="$path" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
			[ "$magic" = 7f454c46 ] || { gcm_die "Custom binary is not ELF: $path"; return 1; }
		fi
		printf '%s\n' "$path" >> "$output"
	done < "$input"
}

gcm_capture_custom() {
	prefix_dir=$1
	scripts_input=$2
	binaries_input=$3
	work=$4
	total="$work/custom-total"
	printf '0\n' > "$total"
	gcm_validate_custom_list "$scripts_input" "$work/scripts.list" 0 "$total" || return 1
	gcm_validate_custom_list "$binaries_input" "$work/binaries.list" 1 "$total" || return 1
	while IFS= read -r path || [ -n "$path" ]; do [ -n "$path" ] && gcm_copy_with_root "$path" "$prefix_dir/artifacts/files"; done < "$work/scripts.list"
	while IFS= read -r path || [ -n "$path" ]; do [ -n "$path" ] && gcm_copy_with_root "$path" "$prefix_dir/artifacts/binaries"; done < "$work/binaries.list"
}

gcm_write_manifest() {
	prefix_dir=$1
	strategy=$2
	profile_id=$3
	name=$4
	notes=$5
	categories=$6
	excluded=$7
	sanitized=$8
	discovered=$9
	hostname=$(gcm_uci_get system.@system[0].hostname)
	[ -n "$hostname" ] || hostname=$(hostname 2>/dev/null || printf router)
	fingerprint=''
	[ "$strategy" = snapshot ] && fingerprint=$(gcm_device_fingerprint)
	created=$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)
	printf '{' > "$prefix_dir/manifest.json"
	printf '"format":"%s","format_version":%s,"tool_version":"%s",' "$GCM_FORMAT_NAME" "$GCM_FORMAT_VERSION" "$GCM_TOOL_VERSION" >> "$prefix_dir/manifest.json"
	printf '"backup_strategy":"%s","profile_uuid":"%s","profile_name":"%s","notes":"%s","created_at":"%s",' \
		"$strategy" "$(gcm_json_escape "$profile_id")" "$(gcm_json_escape "$name")" "$(gcm_json_escape "$notes")" "$created" >> "$prefix_dir/manifest.json"
	printf '"source_hostname":"%s","source_model":"%s","source_name":"%s","source_id":"%s",' \
		"$(gcm_json_escape "$hostname")" "$(gcm_json_escape "$(gcm_source_model)")" "$(gcm_json_escape "$(gcm_source_model)")" "$(gcm_json_escape "$(gcm_board_name)")" >> "$prefix_dir/manifest.json"
	printf '"firmware_version":"%s","openwrt_version":"%s","architecture":"%s","kernel_version":"%s","device_fingerprint":"%s",' \
		"$(gcm_json_escape "$(gcm_firmware_version)")" "$(gcm_json_escape "$(gcm_openwrt_version)")" "$(gcm_json_escape "$(gcm_architecture)")" "$(gcm_json_escape "$(uname -r 2>/dev/null || printf unknown)")" "$fingerprint" >> "$prefix_dir/manifest.json"
	printf '"source_adapter":"%s","capabilities_detected":"%s","included_sections":' "$(gcm_platform_adapter)" "$(gcm_json_escape "$(gcm_capability_csv)")" >> "$prefix_dir/manifest.json"
	gcm_csv_json_array "$categories" >> "$prefix_dir/manifest.json"
	printf ',"excluded_sections":' >> "$prefix_dir/manifest.json"; gcm_json_array_file "$excluded" >> "$prefix_dir/manifest.json"
	printf ',"sanitizations_performed":' >> "$prefix_dir/manifest.json"; gcm_json_array_file "$sanitized" >> "$prefix_dir/manifest.json"
	printf ',"persistent_files_discovered":' >> "$prefix_dir/manifest.json"; gcm_json_array_file "$discovered" >> "$prefix_dir/manifest.json"
	printf '}\n' >> "$prefix_dir/manifest.json"
	{
		printf 'GL.iNet Cross-Model Backup archive v2\n'
		printf 'Profile: %s\nStrategy: %s\nUUID: %s\nCreated: %s\n' "$name" "$(gcm_strategy_label "$strategy")" "$profile_id" "$created"
		printf 'Source: %s (%s)\nFirmware: %s / OpenWrt %s\nArchitecture: %s / kernel %s\n' "$hostname" "$(gcm_source_model)" "$(gcm_firmware_version)" "$(gcm_openwrt_version)" "$(gcm_architecture)" "$(uname -r 2>/dev/null || printf unknown)"
		printf '\nThis archive is intentionally prefixed with %s/ and must not be restored with stock LuCI/sysupgrade tools.\n' "$GCM_PREFIX"
		case "$strategy" in
			portable) printf 'Portable data is semantic and target adapters map logical settings to target capabilities.\n' ;;
			clone) printf 'Restore is hard-blocked unless source and target models match. Device identity was sanitized.\n' ;;
			remote-safe) printf 'Restore is hard-blocked unless models match and management-path configuration is preserved.\n' ;;
			snapshot) printf 'Restore is hard-blocked unless the stable physical-device fingerprint matches.\n' ;;
		esac
	} > "$prefix_dir/backup-info.txt"
}

gcm_create() {
	output=$1
	strategy=$2
	profile_id=$3
	name=$4
	notes=$5
	categories=$6
	scripts_input=$7
	binaries_input=$8
	gcm_valid_strategy "$strategy" || { gcm_die 'Invalid backup strategy.'; return 1; }
	categories=$(gcm_valid_categories "$categories") || { gcm_die 'Invalid or empty category selection.'; return 1; }
	gcm_valid_uuid "$profile_id" || { gcm_die 'Invalid profile UUID.'; return 1; }
	gcm_have sha256sum || { gcm_die 'sha256sum is required for v2 archives.'; return 1; }
	if [ "$strategy" = snapshot ]; then
		fingerprint=$(gcm_device_fingerprint) || { gcm_die 'Could not generate the Device Snapshot fingerprint.'; return 1; }
		[ -n "$fingerprint" ] && [ "$fingerprint" != unavailable ] || {
			gcm_die 'Device Snapshot requires a stable factory serial number or factory MAC address; neither was detected.'
			return 1
		}
	fi
	work=$(mktemp -d /tmp/gcm-create.XXXXXX) || return 1
	prefix_dir="$work/$GCM_PREFIX"
	excluded="$work/excluded"
	sanitized="$work/sanitized"
	discovered="$work/discovered"
	: > "$excluded"; : > "$sanitized"
	mkdir -p "$prefix_dir/extra" "$prefix_dir/artifacts" "$prefix_dir/source"
	gcm_discover_keep_files "$discovered" || { rm -rf "$work"; return 1; }
	case "$strategy" in
		portable) gcm_capture_portable "$prefix_dir" "$categories" || { rm -rf "$work"; return 1; } ;;
		clone|remote-safe|snapshot) gcm_capture_raw_uci "$prefix_dir" "$strategy" "$categories" "$excluded" "$sanitized" || { rm -rf "$work"; return 1; } ;;
	esac
	gcm_capture_persistent "$prefix_dir" "$strategy" "$discovered" "$excluded" || { rm -rf "$work"; return 1; }
	if gcm_has_category "$categories" packages; then
		gcm_package_status_tsv /usr/lib/opkg/status > "$prefix_dir/source/packages.tsv"
		gcm_packages_json "$prefix_dir/packages.json" "$prefix_dir/source/packages.tsv"
	else
		printf '{"source_kernel":"%s","packages":[]}\n' "$(gcm_json_escape "$(uname -r 2>/dev/null || printf unknown)")" > "$prefix_dir/packages.json"
	fi
	gcm_capture_custom "$prefix_dir" "$scripts_input" "$binaries_input" "$work" || { rm -rf "$work"; return 1; }
	gcm_facts_json > "$prefix_dir/source/facts.json"
	gcm_write_manifest "$prefix_dir" "$strategy" "$profile_id" "$name" "$notes" "$categories" "$excluded" "$sanitized" "$discovered"
	gcm_generate_checksums "$work" || { rm -rf "$work"; return 1; }
	mkdir -p "$(dirname "$output")" || { rm -rf "$work"; return 1; }
	umask 077
	tar -C "$work" -czf "$output" "$GCM_PREFIX" || { rm -f "$output"; rm -rf "$work"; gcm_die 'Could not create archive.'; return 1; }
	rm -rf "$work"
	gcm_log "CREATED=$output"
	gcm_log "PROFILE_UUID=$profile_id"
	gcm_log "STRATEGY=$strategy"
}

gcm_legacy_metadata() {
	profile_dir=$1
	meta="$profile_dir/meta.json"
	[ -f "$meta" ] || { gcm_die 'Legacy archive is missing profile/meta.json.'; return 1; }
	model=$(gcm_manifest_field "$meta" model)
	arch=$(gcm_manifest_field "$meta" architecture)
	firmware=$(gcm_manifest_field "$meta" firmware)
	printf '{"archive_kind":"legacy-v1","format":"glinet-openwrt-portable-profile/v1","format_version":1,"backup_strategy":"legacy-portable","profile_uuid":"","profile_name":"Legacy v1 profile","notes":"Read-only compatibility path","source_model":"%s","firmware_version":"%s","architecture":"%s","legacy":true}\n' \
		"$(gcm_json_escape "$model")" "$(gcm_json_escape "$firmware")" "$(gcm_json_escape "$arch")"
}

gcm_inspect() {
	archive=$1
	format=${2:-json}
	work=$(mktemp -d /tmp/gcm-inspect.XXXXXX) || return 1
	kind=$(gcm_extract_archive "$archive" "$work") || { rm -rf "$work"; return 1; }
	case "$kind" in
		v2)
			prefix_dir="$work/$GCM_PREFIX"
			gcm_verify_checksums "$prefix_dir" || { rm -rf "$work"; return 1; }
			gcm_validate_v2_manifest "$prefix_dir/manifest.json" || { rm -rf "$work"; return 1; }
			if [ "$format" = json ]; then
				cat "$prefix_dir/manifest.json"
			else
				cat "$prefix_dir/backup-info.txt"
			fi
			;;
		legacy-v1)
			if [ "$format" = json ]; then gcm_legacy_metadata "$work/profile"; else printf 'Legacy v1 profile/ archive. Inspection is supported; restore requires explicit legacy approval.\n'; fi
			;;
	esac
	rm -rf "$work"
}

gcm_add_result() { printf '%s\n' "$2" >> "$1"; }

gcm_target_firewall_zones() {
	uci -q show firewall 2>/dev/null | sed -n 's/^firewall\.\([^=]*\)=zone$/\1/p' | while IFS= read -r section; do
		gcm_uci_get "firewall.$section.name"
	done | sort -u
}

gcm_portable_source_bands() {
	profile=$1
	sed -n "s/^[[:space:]]*option band '\([^']*\)'.*/\1/p" "$profile" | sort -u
}

gcm_file_count_type() {
	file=$1
	type=$2
	[ -f "$file" ] || { printf '0\n'; return; }
	grep -c "^[[:space:]]*config $type" "$file" 2>/dev/null || true
}

gcm_package_review_files() {
	source_tsv=$1
	work=$2
	source_kernel=${3:-unknown}
	for class in same different available unavailable kmod; do : > "$work/pkg-$class"; done
	target="$work/target-packages.tsv"
	gcm_package_status_tsv /usr/lib/opkg/status > "$target"
	feed="$work/feed-packages"
	supported_arches=$(gcm_supported_package_arches | tr '\n' ' ')
	feed_ok=1
	if gcm_opkg_run list > "$feed" 2>/dev/null; then :; else feed_ok=0; : > "$feed"; fi
	while IFS="$(printf '\t')" read -r name version arch section description depends size user kmod || [ -n "${name:-}" ]; do
		[ -n "$name" ] || continue
		[ "$user" = true ] || continue
		if [ "$kmod" = true ] || [ "$section" = kernel ]; then
			gcm_add_result "$work/pkg-kmod" "$name $version (source kernel $source_kernel)"
			continue
		fi
		target_line=$(awk -F '\t' -v p="$name" '$1==p{print;exit}' "$target")
		if [ -n "$target_line" ]; then
			target_version=$(printf '%s\n' "$target_line" | awk -F '\t' '{print $2}')
			if [ "$target_version" = "$version" ]; then
				gcm_add_result "$work/pkg-same" "$name $version"
			else
				gcm_add_result "$work/pkg-different" "$name source=$version target=$target_version"
			fi
		elif ! gcm_package_arch_compatible "$arch" "$supported_arches"; then
			gcm_add_result "$work/pkg-unavailable" "$name $version (source architecture $arch is unsupported by target)"
		elif awk -F ' - ' -v package="$name" '$1==package{found=1;exit} END{exit found?0:1}' "$feed" 2>/dev/null; then
			feed_version=$(awk -F ' - ' -v package="$name" '$1==package{print $2;exit}' "$feed")
			gcm_add_result "$work/pkg-available" "$name source=$version feed=$feed_version"
		else
			gcm_add_result "$work/pkg-unavailable" "$name $version"
		fi
	done < "$source_tsv"
	printf '%s\n' "$feed_ok" > "$work/feed-ok"
}

gcm_package_class() {
	source_version=$1
	is_kmod=$2
	target_version=$3
	feed_version=$4
	if [ "$is_kmod" = true ]; then printf 'kmod\n'
	elif [ -n "$target_version" ] && [ "$target_version" = "$source_version" ]; then printf 'same\n'
	elif [ -n "$target_version" ]; then printf 'different\n'
	elif [ -n "$feed_version" ]; then printf 'available\n'
	else printf 'unavailable\n'
	fi
}

gcm_packages_review() {
	archive=$1
	work=$(mktemp -d /tmp/gcm-packages.XXXXXX) || return 1
	kind=$(gcm_extract_archive "$archive" "$work/archive") || { rm -rf "$work"; return 1; }
	[ "$kind" = v2 ] || { rm -rf "$work"; gcm_die 'Package Review requires a v2 archive.'; return 1; }
	prefix_dir="$work/archive/$GCM_PREFIX"
	gcm_verify_checksums "$prefix_dir" || { rm -rf "$work"; return 1; }
	manifest="$prefix_dir/manifest.json"
	source_kernel=$(gcm_manifest_field "$manifest" kernel_version)
	source_tsv="$prefix_dir/source/packages.tsv"
	[ -f "$source_tsv" ] || : > "$source_tsv"
	gcm_package_review_files "$source_tsv" "$work" "$source_kernel"
	printf '{"feed_reachable":%s,"already_installed_same":' "$(cat "$work/feed-ok")"
	gcm_json_array_file "$work/pkg-same"
	printf ',"already_installed_different":'; gcm_json_array_file "$work/pkg-different"
	printf ',"missing_available":'; gcm_json_array_file "$work/pkg-available"
	printf ',"missing_unavailable":'; gcm_json_array_file "$work/pkg-unavailable"
	printf ',"kernel_packages":'; gcm_json_array_file "$work/pkg-kmod"
	printf '}\n'
	rm -rf "$work"
}

gcm_validate() {
	archive=$1
	categories=${2:-wifi,lan,dhcp,dns,firewall,timezone,ddns,vpn,packages,persistent,custom-files,custom-binaries}
	dangerous_override=${3:-0}
	categories=$(gcm_valid_categories "$categories") || { gcm_die 'Invalid validation categories.'; return 1; }
	work=$(mktemp -d /tmp/gcm-validate.XXXXXX) || return 1
	kind=$(gcm_extract_archive "$archive" "$work/archive") || { rm -rf "$work"; return 1; }
	will="$work/will"; adapt="$work/adapt"; preserve="$work/preserve"; skip="$work/skip"; warn="$work/warn"; incompatible="$work/incompatible"; dangerous="$work/dangerous"
	for file in "$will" "$adapt" "$preserve" "$skip" "$warn" "$incompatible" "$dangerous"; do : > "$file"; done
	compatible=true
	if [ "$kind" = v2 ]; then
		prefix_dir="$work/archive/$GCM_PREFIX"
		manifest="$prefix_dir/manifest.json"
		gcm_verify_checksums "$prefix_dir" || { rm -rf "$work"; return 1; }
		gcm_validate_v2_manifest "$manifest" || { rm -rf "$work"; return 1; }
		strategy=$(gcm_manifest_field "$manifest" backup_strategy)
		source_model=$(gcm_manifest_field "$manifest" source_model)
		source_id=$(gcm_manifest_field "$manifest" source_id)
		source_firmware=$(gcm_manifest_field "$manifest" firmware_version)
		source_openwrt=$(gcm_manifest_field "$manifest" openwrt_version)
		source_arch=$(gcm_manifest_field "$manifest" architecture)
		source_kernel=$(gcm_manifest_field "$manifest" kernel_version)
		source_fingerprint=$(gcm_manifest_field "$manifest" device_fingerprint)
		gcm_valid_strategy "$strategy" || { rm -rf "$work"; gcm_die 'Manifest backup strategy is invalid.'; return 1; }
	else
		prefix_dir="$work/archive/profile"
		manifest="$prefix_dir/meta.json"
		strategy=legacy-portable
		source_model=$(gcm_manifest_field "$manifest" model)
		source_id=''
		source_firmware=$(gcm_manifest_field "$manifest" firmware)
		source_openwrt=unknown
		source_arch=$(gcm_manifest_field "$manifest" architecture)
		source_kernel=unknown
		source_fingerprint=''
		gcm_add_result "$warn" 'Legacy v1 archive: inspection is supported, but its payload has no v2 SHA-256 manifest or strategy guarantees.'
		gcm_add_result "$dangerous" 'Legacy restore requires the explicit --allow-legacy flag and uses the stricter compatibility path.'
	fi
	target_model=$(gcm_source_model)
	target_id=$(gcm_board_name)
	target_firmware=$(gcm_firmware_version)
	target_openwrt=$(gcm_openwrt_version)
	target_arch=$(gcm_architecture)
	target_kernel=$(uname -r 2>/dev/null || printf unknown)
	target_fingerprint=$(gcm_device_fingerprint)
	case "$strategy" in
		clone|remote-safe)
			if [ -n "$source_id" ] && [ "$source_id" != unknown ] && [ -n "$target_id" ] && [ "$target_id" != unknown ]; then
				if [ "$(gcm_lower "$source_id")" != "$(gcm_lower "$target_id")" ]; then
					compatible=false; gcm_add_result "$incompatible" "Same-model board requirement failed: source=$source_id target=$target_id"
				else gcm_add_result "$will" "Same-model board requirement passed for $target_id."; fi
			elif ! gcm_model_known "$source_model" || ! gcm_model_known "$target_model"; then
				compatible=false; gcm_add_result "$incompatible" 'Same-model restore requires a stable board ID or a non-generic model name on both routers.'
			elif [ "$(gcm_lower "$source_model")" != "$(gcm_lower "$target_model")" ]; then
				compatible=false; gcm_add_result "$incompatible" "Same-model requirement failed: source=$source_model target=$target_model"
			else
				gcm_add_result "$will" "Same-model requirement passed for $target_model."
				gcm_add_result "$warn" 'A stable board ID was unavailable; clone compatibility fell back to the model name.'
			fi
			;;
		snapshot)
			if [ -z "$source_fingerprint" ] || [ "$source_fingerprint" = unavailable ] || [ "$source_fingerprint" != "$target_fingerprint" ]; then
				if [ "$dangerous_override" = 1 ]; then
					gcm_add_result "$dangerous" 'DANGEROUS OVERRIDE: device fingerprint mismatch will be ignored by explicit request.'
				else
					compatible=false; gcm_add_result "$incompatible" 'Device Snapshot fingerprint does not match this physical router.'
				fi
			else gcm_add_result "$will" 'Device Snapshot fingerprint matches this physical router.'; fi
			;;
	esac
	if [ "$source_arch" != "$target_arch" ]; then
		gcm_add_result "$warn" "Architecture differs: source=$source_arch target=$target_arch. Portable data may adapt; custom ELF binaries are blocked."
	fi
	if [ "$source_firmware" != "$target_firmware" ]; then gcm_add_result "$warn" "Firmware differs: source=$source_firmware target=$target_firmware."; fi
	if [ "$strategy" != portable ] && [ "$strategy" != legacy-portable ] && [ "$source_kernel" != "$target_kernel" ]; then
		gcm_add_result "$warn" "Kernel differs: source=$source_kernel target=$target_kernel. Kernel modules will never be installed automatically."
	fi
	if [ "$strategy" = portable ]; then
		portable="$prefix_dir/portable/profile"
		if gcm_has_category "$categories" wifi; then
			target_bands=$(gcm_detect_bands | tr '\n' ' ')
			for band in $(gcm_portable_source_bands "$portable"); do
				case " $target_bands " in *" $band "*) gcm_add_result "$adapt" "Wi-Fi $band GHz profiles will map to a target radio by band/capability." ;; *) gcm_add_result "$skip" "Wi-Fi $band GHz is absent on the target and will be skipped." ;; esac
			done
		fi
		if gcm_has_category "$categories" firewall; then
			target_zones=$(gcm_target_firewall_zones | tr '\n' ' ')
			missing=''
			for zone in $(sed -n "s/^[[:space:]]*option \(src\|dest\) '\([^']*\)'.*/\2/p" "$portable" | sort -u); do
				if gcm_firewall_zone_exists "$zone" "$target_zones"; then :; else missing="${missing:+$missing, }$zone"; fi
			done
			if [ -n "$missing" ]; then compatible=false; gcm_add_result "$incompatible" "Portable firewall objects reference target-missing zones: $missing"; else gcm_add_result "$will" 'Portable firewall rules and port forwards reference known target zones.'; fi
		fi
		gcm_add_result "$preserve" 'Physical Ethernet assignments, switch/DSA topology, board interface names, and factory identity are never imported.'
		[ -d "$prefix_dir/portable/vpn" ] && gcm_add_result "$adapt" 'VPN structural configuration will be mapped only to matching target packages; private keys and device identity remain target-local.'
		if gcm_has_category "$categories" lan && [ "$(gcm_file_count_type "$portable" lan)" -gt 0 ]; then gcm_add_result "$will" 'Logical LAN protocol, address, netmask, gateway, and DNS values will apply without physical topology.'; fi
		if gcm_has_category "$categories" dhcp; then gcm_add_result "$will" "DHCP settings and $(gcm_file_count_type "$portable" reservation) static reservation(s) will apply semantically."; fi
		if gcm_has_category "$categories" dns && [ "$(gcm_file_count_type "$portable" dns)" -gt 0 ]; then gcm_add_result "$will" 'Portable dnsmasq DNS settings will apply to the target DNS section.'; fi
		if gcm_has_category "$categories" timezone && [ "$(gcm_file_count_type "$portable" timezone)" -gt 0 ]; then gcm_add_result "$will" 'Timezone and zone name will apply.'; fi
		if gcm_has_category "$categories" ddns && { [ "$(gcm_file_count_type "$portable" gl_ddns)" -gt 0 ] || [ "$(gcm_file_count_type "$portable" ddns)" -gt 0 ]; }; then gcm_add_result "$adapt" 'DDNS preferences will apply while GL device-bound registration identity remains target-local.'; fi
	elif [ "$strategy" = remote-safe ]; then
		peer=${SSH_CONNECTION%% *}
		route=''
		[ -n "$peer" ] && route=$(ip route get "$peer" 2>/dev/null | sed -n '1p' || true)
		gcm_add_result "$preserve" 'Dropbear, authorized_keys, ZeroTier, Tailscale, GoodCloud, rtty, and WAN-access state remain target-local.'
		if [ -n "$route" ]; then gcm_add_result "$preserve" "Current management route detected and protected: $route"; else gcm_add_result "$warn" 'The active SSH management route could not be resolved; connectivity-affecting reloads remain deferred.'; fi
		gcm_add_result "$dangerous" 'Network, firewall, and Wi-Fi files are staged last; service reload/reboot is deferred until after controller success.'
	fi
	if [ "$strategy" = clone ] || [ "$strategy" = remote-safe ] || [ "$strategy" = snapshot ]; then
		raw_count=$(find "$prefix_dir/uci" -type f 2>/dev/null | wc -l | tr -d ' ')
		gcm_add_result "$will" "$raw_count selected UCI package file(s) will apply, with network/firewall/Wi-Fi ordered last."
	fi
	if [ "$strategy" = clone ]; then gcm_add_result "$dangerous" 'Same-model Clone replaces selected persistent configuration after reinjecting dynamically discovered target identity values.'; fi
	if [ "$strategy" = snapshot ]; then gcm_add_result "$dangerous" 'Device Snapshot may restore device-specific credentials and identity because it is restricted to this exact fingerprint.'; fi
	if [ -d "$prefix_dir/extra" ]; then
		extra_count=$(find "$prefix_dir/extra" -type f 2>/dev/null | wc -l | tr -d ' ')
		[ "$extra_count" -gt 0 ] && gcm_add_result "$will" "$extra_count strategy-approved persistent non-UCI file(s) will apply."
	fi
	if [ -d "$prefix_dir/artifacts/files" ]; then
		custom_count=$(find "$prefix_dir/artifacts/files" -type f 2>/dev/null | wc -l | tr -d ' ')
		[ "$custom_count" -gt 0 ] && gcm_add_result "$will" "$custom_count explicitly selected custom file/script(s) will remain staged unless direct placement is deliberately requested."
	fi
	if [ -d "$prefix_dir/artifacts/binaries" ]; then
		if [ "$source_arch" != "$target_arch" ]; then
			gcm_add_result "$skip" "Custom ELF binaries blocked: source=$source_arch target=$target_arch."
		else
			binary_count=0; binary_skipped=0
			binary_list="$work/custom-binaries.list"
			find "$prefix_dir/artifacts/binaries" -type f 2>/dev/null > "$binary_list"
			while IFS= read -r binary || [ -n "$binary" ]; do
				binary_count=$((binary_count + 1))
				if ! gcm_binary_compatible "$binary" "$target_arch"; then binary_skipped=$((binary_skipped + 1)); gcm_add_result "$skip" "Custom ELF binary has an incompatible or malformed ELF class/machine: ${binary#"$prefix_dir/artifacts/binaries"/}"; fi
			done < "$binary_list"
			[ "$binary_count" -gt "$binary_skipped" ] && gcm_add_result "$will" "$((binary_count - binary_skipped)) custom ELF binary/binaries match target architecture and remain staged by default."
		fi
	fi
	if [ -f "$prefix_dir/source/packages.tsv" ] && gcm_has_category "$categories" packages; then
		gcm_package_review_files "$prefix_dir/source/packages.tsv" "$work" "$source_kernel"
		count_available=$(wc -l < "$work/pkg-available" | tr -d ' ')
		count_kmod=$(wc -l < "$work/pkg-kmod" | tr -d ' ')
		gcm_add_result "$will" "Package Review completed: $count_available compatible missing package(s) available for optional selection."
		[ "$count_kmod" -gt 0 ] && gcm_add_result "$skip" "$count_kmod kernel/kmod package(s) are review-only and never automatically installed."
		[ "$(cat "$work/feed-ok")" = 1 ] || gcm_add_result "$warn" 'Package feeds are unreachable or have no cached list; restore can continue without package installation.'
	fi
	if [ "$strategy" = clone ] || [ "$strategy" = remote-safe ] || [ "$strategy" = snapshot ]; then
		gcm_add_result "$will" 'A target-side pre-restore snapshot will be created before any file is changed.'
	fi
	printf '{"archive_kind":"%s","backup_strategy":"%s","compatible":%s,' "$kind" "$strategy" "$compatible"
	printf '"source":{"model":"%s","id":"%s","firmware":"%s","openwrt":"%s","architecture":"%s","kernel":"%s"},' "$(gcm_json_escape "$source_model")" "$(gcm_json_escape "$source_id")" "$(gcm_json_escape "$source_firmware")" "$(gcm_json_escape "$source_openwrt")" "$(gcm_json_escape "$source_arch")" "$(gcm_json_escape "$source_kernel")"
	printf '"target":{"model":"%s","id":"%s","firmware":"%s","openwrt":"%s","architecture":"%s","kernel":"%s"},' "$(gcm_json_escape "$target_model")" "$(gcm_json_escape "$target_id")" "$(gcm_json_escape "$target_firmware")" "$(gcm_json_escape "$target_openwrt")" "$(gcm_json_escape "$target_arch")" "$(gcm_json_escape "$target_kernel")"
	printf '"incompatible":'; gcm_json_array_file "$incompatible"
	printf ',"will_apply":'; gcm_json_array_file "$will"
	printf ',"will_adapt":'; gcm_json_array_file "$adapt"
	printf ',"will_preserve":'; gcm_json_array_file "$preserve"
	printf ',"will_skip":'; gcm_json_array_file "$skip"
	printf ',"warnings":'; gcm_json_array_file "$warn"
	printf ',"dangerous_actions":'; gcm_json_array_file "$dangerous"
	printf '}\n'
	rm -rf "$work"
}

gcm_profile_sections() {
	config_dir=$1
	type=$2
	uci -c "$config_dir" -q show profile 2>/dev/null | sed -n "s/^profile\.\([^=]*\)=$type$/\1/p"
}

gcm_profile_get() { uci -c "$1" -q get "profile.$2.$3" 2>/dev/null || true; }

gcm_set_if_value() {
	set_package=$1; set_section=$2; set_option=$3; set_value=$4
	[ -n "$set_value" ] || return 0
	gcm_adapter_set "$set_package" "$set_section" "$set_option" "$set_value"
}

gcm_target_radio_for_band() {
	wanted=$1
	uci -q show wireless 2>/dev/null | sed -n 's/^wireless\.\([^=]*\)=wifi-device$/\1/p' | while IFS= read -r radio; do
		[ "$(gcm_radio_band "$radio")" = "$wanted" ] && { printf '%s\n' "$radio"; break; }
	done
}

gcm_target_wifi_iface() {
	radio=$1
	role=$2
	uci -q show wireless 2>/dev/null | sed -n 's/^wireless\.\([^=]*\)=wifi-iface$/\1/p' | while IFS= read -r iface; do
		[ "$(gcm_uci_get "wireless.$iface.device")" = "$radio" ] || continue
		network=$(gcm_uci_get "wireless.$iface.network")
		ssid=$(gcm_uci_get "wireless.$iface.ssid")
		case "$(gcm_lower "$network $iface $ssid")" in *guest*) detected=guest ;; *lan*) detected=main ;; *) detected=other ;; esac
		[ "$detected" = "$role" ] && { printf '%s\n' "$iface"; break; }
	done
}

gcm_apply_portable_wifi() {
	config_dir=$1
	for source in $(gcm_profile_sections "$config_dir" wifi); do
		band=$(gcm_profile_get "$config_dir" "$source" band)
		role=$(gcm_profile_get "$config_dir" "$source" role)
		radio=$(gcm_target_radio_for_band "$band" | sed -n '1p')
		if [ -z "$radio" ]; then gcm_log "SKIPPED=wifi:$band:no-target-radio"; continue; fi
		iface=$(gcm_target_wifi_iface "$radio" "$role" | sed -n '1p')
		if [ -z "$iface" ]; then
			iface=$(uci add wireless wifi-iface)
			uci set "wireless.$iface.device=$radio"
			case "$role" in guest) target_network=guest ;; *) target_network=lan ;; esac
			# Do not invent a missing target network. A guest SSID can be added
			# only when a logical guest interface already exists.
			if ! uci -q get "network.$target_network" >/dev/null 2>&1; then
				uci delete "wireless.$iface"; gcm_log "SKIPPED=wifi:$band:$role:missing-$target_network-network"; continue
			fi
			uci set "wireless.$iface.network=$target_network"
		fi
		gcm_set_if_value wireless "$iface" ssid "$(gcm_profile_get "$config_dir" "$source" ssid)"
		gcm_set_if_value wireless "$iface" encryption "$(gcm_profile_get "$config_dir" "$source" encryption)"
		gcm_set_if_value wireless "$iface" key "$(gcm_profile_get "$config_dir" "$source" key)"
		gcm_set_if_value wireless "$iface" hidden "$(gcm_profile_get "$config_dir" "$source" hidden)"
		gcm_set_if_value wireless "$iface" isolate "$(gcm_profile_get "$config_dir" "$source" isolation)"
		gcm_set_if_value wireless "$iface" ieee80211r "$(gcm_profile_get "$config_dir" "$source" ieee80211r)"
		gcm_set_if_value wireless "$iface" mobility_domain "$(gcm_profile_get "$config_dir" "$source" mobility_domain)"
		enabled=$(gcm_profile_get "$config_dir" "$source" enabled)
		case "$enabled" in 1|true) uci -q delete "wireless.$iface.disabled" ;; 0|false) uci set "wireless.$iface.disabled=1" ;; esac
		gcm_log "ADAPTED=wifi:$band:$role:target-$radio"
	done
	gcm_adapter_commit wireless
}

gcm_apply_portable_lan_dhcp_dns() {
	config_dir=$1
	categories=$2
	if gcm_has_category "$categories" lan; then
		section=$(gcm_profile_sections "$config_dir" lan | sed -n '1p')
		if [ -n "$section" ] && uci -q get network.lan >/dev/null 2>&1; then
			proto=$(gcm_profile_get "$config_dir" "$section" protocol)
			# Only logical L3 values are portable. Device/ifname/type/bridge and
			# switch topology are intentionally untouched.
			gcm_set_if_value network lan proto "$proto"
			gcm_set_if_value network lan ipaddr "$(gcm_profile_get "$config_dir" "$section" address)"
			gcm_set_if_value network lan netmask "$(gcm_profile_get "$config_dir" "$section" netmask)"
			gcm_set_if_value network lan gateway "$(gcm_profile_get "$config_dir" "$section" gateway)"
			gcm_set_if_value network lan dns "$(gcm_profile_get "$config_dir" "$section" dns)"
			gcm_adapter_commit network
			gcm_log 'APPLIED=portable:lan-logical-settings'
		else gcm_log 'SKIPPED=portable:lan:no-target-lan-interface'; fi
	fi
	if gcm_has_category "$categories" dhcp; then
		section=$(gcm_profile_sections "$config_dir" dhcp | sed -n '1p')
		if [ -n "$section" ] && uci -q get dhcp.lan >/dev/null 2>&1; then
			for option in start limit leasetime ignore dhcpv6 ra; do gcm_set_if_value dhcp lan "$option" "$(gcm_profile_get "$config_dir" "$section" "$option")"; done
		fi
		for source in $(gcm_profile_sections "$config_dir" reservation); do
			mac=$(gcm_profile_get "$config_dir" "$source" mac)
			ip=$(gcm_profile_get "$config_dir" "$source" ip)
			[ -n "$mac$ip" ] || continue
			target=''
			for candidate in $(uci -q show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^=]*\)=host$/\1/p'); do
				[ "$(gcm_uci_get "dhcp.$candidate.mac")" = "$mac" ] && { target=$candidate; break; }
			done
			[ -n "$target" ] || target=$(uci add dhcp host)
			for option in name mac ip hostid; do gcm_set_if_value dhcp "$target" "$option" "$(gcm_profile_get "$config_dir" "$source" "$option")"; done
		done
		gcm_adapter_commit dhcp
		gcm_log 'APPLIED=portable:dhcp-and-reservations'
	fi
	if gcm_has_category "$categories" dns; then
		section=$(gcm_profile_sections "$config_dir" dns | sed -n '1p')
		if [ -n "$section" ]; then
			dnsmasq=$(uci -q show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^=]*\)=dnsmasq$/\1/p' | sed -n '1p')
			if [ -n "$dnsmasq" ]; then
				for option in local domain rebind_protection localservice; do gcm_set_if_value dhcp "$dnsmasq" "$option" "$(gcm_profile_get "$config_dir" "$section" "$option")"; done
				servers=$(gcm_profile_get "$config_dir" "$section" servers)
				if [ -n "$servers" ]; then
					uci -q delete "dhcp.$dnsmasq.server"
					for server in $servers; do uci add_list "dhcp.$dnsmasq.server=$server"; done
				fi
				gcm_adapter_commit dhcp; gcm_log 'APPLIED=portable:dns'
			fi
		fi
	fi
}

gcm_find_firewall_named() {
	type=$1
	name=$2
	uci -q show firewall 2>/dev/null | sed -n "s/^firewall\.\([^=]*\)=$type$/\1/p" | while IFS= read -r section; do
		[ "$(gcm_uci_get "firewall.$section.name")" = "$name" ] && { printf '%s\n' "$section"; break; }
	done
}

gcm_apply_portable_firewall() {
	config_dir=$1
	for type in firewall_rule port_forward; do
		case "$type" in firewall_rule) target_type=rule ;; port_forward) target_type=redirect ;; esac
		for source in $(gcm_profile_sections "$config_dir" "$type"); do
			name=$(gcm_profile_get "$config_dir" "$source" name)
			target=$(gcm_find_firewall_named "$target_type" "$name" | sed -n '1p')
			[ -n "$target" ] || target=$(uci add firewall "$target_type")
			case "$type" in
				firewall_rule) options='name src dest proto src_ip dest_ip src_port dest_port target family enabled' ;;
				port_forward) options='name src dest proto src_dport dest_ip dest_port target enabled' ;;
			esac
			for option in $options; do gcm_set_if_value firewall "$target" "$option" "$(gcm_profile_get "$config_dir" "$source" "$option")"; done
			gcm_log "APPLIED=portable:$type:${name:-unnamed}"
		done
	done
	gcm_adapter_commit firewall
}

gcm_apply_portable_ddns() {
	config_dir=$1
	sections=$(gcm_profile_sections "$config_dir" gl_ddns)
	if [ -n "$sections" ] && uci -q show gl_ddns >/dev/null 2>&1; then
		target_sections=$(uci -q show gl_ddns 2>/dev/null | sed -n 's/^gl_ddns\.\([^.=]*\)=.*/\1/p' | sort -u)
		for section in $sections; do
			family=$(gcm_profile_get "$config_dir" "$section" family)
			target=''
			for candidate in $target_sections; do
				case "$(gcm_lower "$candidate"):$family" in *v6*:ipv6) target=$candidate; break ;; *v6*:ipv4) ;; *:ipv4) target=$candidate; break ;; esac
			done
			[ -n "$target" ] || { gcm_log "SKIPPED=gl-ddns:$family:no-target-section"; continue; }
			for option in enabled enabled_ssh http_port https_port; do
				value=$(gcm_profile_get "$config_dir" "$section" "$option")
				[ -n "$value" ] && gcm_adapter_set gl_ddns "$target" "$option" "$value"
			done
		done
		gcm_adapter_commit gl_ddns
		gcm_log 'ADAPTED=gl-ddns:portable-preferences-only;device-identity-preserved'
		if [ "${GCM_DEFER_RELOAD:-0}" = 1 ]; then
			gcm_log 'DEFERRED=gl-ddns-restart'
		elif [ -x /etc/init.d/gl_ddns ]; then
			/etc/init.d/gl_ddns restart >/dev/null 2>&1 || gcm_log 'WARNING=gl-ddns-restart-failed'
		fi
		return
	fi
	for source in $(gcm_profile_sections "$config_dir" ddns); do
		name=$(gcm_profile_get "$config_dir" "$source" name)
		target=$(uci -q show ddns 2>/dev/null | sed -n 's/^ddns\.\([^=]*\)=service$/\1/p' | while IFS= read -r candidate; do [ "$(gcm_uci_get "ddns.$candidate.name")" = "$name" ] && { printf '%s\n' "$candidate"; break; }; done | sed -n '1p')
		[ -n "$target" ] || target=$(uci add ddns service)
		for option in name service_name domain username password ip_source interface enabled; do gcm_set_if_value ddns "$target" "$option" "$(gcm_profile_get "$config_dir" "$source" "$option")"; done
	done
	gcm_adapter_commit ddns
}

gcm_target_identity_assignments() {
	package=$1
	destination=$2
	: > "$destination"
	uci -q show "$package" 2>/dev/null | while IFS= read -r assignment; do
		left=${assignment%%=*}
		option=${left##*.}
		case "$option" in macaddr|private_key|privatekey|preshared_key|secret|token|authkey|device_id|serial) printf '%s\n' "$assignment" ;; esac
		case "$(gcm_lower "$package"):$option" in
			gl_ddns:username|gl_ddns:password|gl_ddns:domain|gl_ddns:param_enc|gl_ddns:lookup_host) printf '%s\n' "$assignment" ;;
			*openvpn*:username|*openvpn*:password|ovpn*:username|ovpn*:password) printf '%s\n' "$assignment" ;;
		esac
	done > "$destination"
}

gcm_reapply_target_identity() {
	assignments=$1
	[ -s "$assignments" ] || return 0
	while IFS= read -r assignment || [ -n "$assignment" ]; do [ -n "$assignment" ] && uci set "$assignment" || return 1; done < "$assignments"
}

gcm_merge_sanitized_uci() {
	config_dir=$1
	package=$2
	uci -c "$config_dir" -q show "$package" 2>/dev/null | while IFS= read -r assignment; do
		left=${assignment%%=*}
		rest=${left#"$package".}
		section=${rest%%.*}
		case "$section" in ''|@*) gcm_log "SKIPPED=vpn:$package:anonymous-section-requires-manual-adaptation"; continue ;; esac
		option=${left##*.}
		case "$option" in macaddr|private_key|privatekey|preshared_key|secret|token|authkey|device_id|serial|username|password|auth_user_pass|key|cert|ca|tls_auth|tls_crypt) continue ;; esac
		uci set "$assignment" || exit 1
	done || return 1
	uci commit "$package"
}

gcm_apply_portable_vpn() {
	vpn_dir=$1
	[ -d "$vpn_dir" ] || return 0
	for file in "$vpn_dir"/*; do
		[ -f "$file" ] || continue
		package=${file##*/}
		if uci -q show "$package" >/dev/null 2>&1; then
			gcm_merge_sanitized_uci "$vpn_dir" "$package" || return 1
			gcm_log "ADAPTED=vpn:$package:structural-config-without-private-identity"
		else
			gcm_log "SKIPPED=vpn:$package:target-package-missing"
		fi
	done
}

gcm_prune_rollbacks() {
	rollback_root='/root/glinet-crossmodel/rollback'
	keep=$(gcm_uci_get glinet_crossmodel.storage.max_rollbacks)
	case "$keep" in ''|*[!0-9]*) keep=5 ;; esac
	[ "$keep" -ge 1 ] 2>/dev/null || keep=1
	mkdir -p "$rollback_root" || return 1
	# Keep room for the snapshot about to be created. All candidates are
	# application-owned UUID directories beneath the fixed rollback root.
	ls -1dt "$rollback_root"/* 2>/dev/null | awk -v keep="$keep" 'NR>=keep' | while IFS= read -r old; do
		case "$old" in "$rollback_root"/[A-Fa-f0-9-]*) rm -rf "$old" ;; esac
	done
}

gcm_pre_restore_snapshot() {
	profile_id=$1
	prefix_dir=${2:-}
	direct_custom=${3:-0}
	gcm_prune_rollbacks || return 1
	root="/root/glinet-crossmodel/rollback/$profile_id"
	data="$root/glinet-crossmodel-rollback"
	rm -rf "$root"
	mkdir -p "$data/etc/config" || return 1
	: > "$data/created-paths.txt"
	for source in /etc/config/*; do [ -f "$source" ] && [ ! -L "$source" ] && cp -p "$source" "$data/etc/config/"; done
	tree="$prefix_dir/extra"
	if [ -d "$tree" ]; then
		find "$tree" -type f | while IFS= read -r source; do
			relative=${source#"$tree"/}; gcm_safe_member "$relative" || exit 1
			target="/$relative"
			if [ -f "$target" ] && [ ! -L "$target" ]; then gcm_copy_with_root "$target" "$data/root" || exit 1; else printf '%s\n' "$target" >> "$data/created-paths.txt"; fi
		done || return 1
	fi
	if [ "$direct_custom" = 1 ]; then
		for tree in "$prefix_dir/artifacts/files" "$prefix_dir/artifacts/binaries"; do
			[ -d "$tree" ] || continue
			find "$tree" -type f | while IFS= read -r source; do
				relative=${source#"$tree"/}; gcm_safe_member "$relative" || exit 1
				target="/$relative"
				if [ -f "$target" ] && [ ! -L "$target" ]; then gcm_copy_with_root "$target" "$data/root" || exit 1; else printf '%s\n' "$target" >> "$data/created-paths.txt"; fi
			done || return 1
		done
	fi
	printf 'created_at=%s\nmodel=%s\nfingerprint=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$(gcm_source_model)" "$(gcm_device_fingerprint)" > "$data/rollback-info.txt"
	(cd "$root" && find glinet-crossmodel-rollback -type f ! -name checksums.sha256 | sort | while IFS= read -r path; do sha256sum "$path"; done > glinet-crossmodel-rollback/checksums.sha256) || return 1
	tar -C "$root" -czf "$root/pre-restore.tar.gz" glinet-crossmodel-rollback || return 1
	printf '%s\n' "$root"
}

gcm_rollback_snapshot() {
	root=$1
	data="$root/glinet-crossmodel-rollback/etc/config"
	[ -d "$data" ] || { gcm_log 'ROLLBACK=failed:snapshot-missing'; return 1; }
	checksums="$root/glinet-crossmodel-rollback/checksums.sha256"
	[ -s "$checksums" ] && (cd "$root" && sha256sum -c glinet-crossmodel-rollback/checksums.sha256 >/dev/null 2>&1) || { gcm_log 'ROLLBACK=failed:snapshot-integrity'; return 1; }
	result=0
	for source in "$data"/*; do
		[ -f "$source" ] || continue
		cp -p "$source" "/etc/config/${source##*/}" || result=1
	done
	if [ -d "$root/glinet-crossmodel-rollback/root" ]; then
		find "$root/glinet-crossmodel-rollback/root" -type f | while IFS= read -r source; do
			relative=${source#"$root/glinet-crossmodel-rollback/root"/}
			gcm_safe_member "$relative" || exit 1
			target="/$relative"; mkdir -p "$(dirname "$target")" || exit 1; cp -p "$source" "$target" || exit 1
		done || result=1
	fi
	if [ -f "$root/glinet-crossmodel-rollback/created-paths.txt" ]; then
		while IFS= read -r target || [ -n "$target" ]; do [ -n "$target" ] && gcm_safe_absolute_path "$target" >/dev/null && rm -f "$target"; done < "$root/glinet-crossmodel-rollback/created-paths.txt"
	fi
	for source in "$data"/*; do
		[ -f "$source" ] || continue
		cmp -s "$source" "/etc/config/${source##*/}" || result=1
	done
	if [ -d "$root/glinet-crossmodel-rollback/root" ]; then
		find "$root/glinet-crossmodel-rollback/root" -type f | while IFS= read -r source; do
			relative=${source#"$root/glinet-crossmodel-rollback/root"/}
			cmp -s "$source" "/$relative" || exit 1
		done || result=1
	fi
	if [ -f "$root/glinet-crossmodel-rollback/created-paths.txt" ]; then
		while IFS= read -r target || [ -n "$target" ]; do [ -n "$target" ] && [ ! -e "$target" ] || result=1; done < "$root/glinet-crossmodel-rollback/created-paths.txt"
	fi
	if [ "$result" -eq 0 ]; then gcm_log 'ROLLBACK=verified:all-snapshot-files-restored'; return 0; fi
	gcm_log 'ROLLBACK=failed:verification-mismatch'; return 1
}

gcm_apply_raw_uci() {
	source_dir=$1
	strategy=$2
	categories=$3
	for source in "$source_dir"/*; do
		[ -f "$source" ] || continue
		package=${source##*/}
		gcm_raw_package_selected "$package" "$categories" || { gcm_log "SKIPPED=uci:$package:not-selected"; continue; }
		case "$package" in network|firewall|wireless) continue ;; esac
		if [ "$strategy" = snapshot ]; then
			cp -p "$source" "/etc/config/$package" || return 1
		else
			identity=$(mktemp /tmp/gcm-raw-identity.XXXXXX) || return 1
			gcm_target_identity_assignments "$package" "$identity"
			cp -p "$source" "/etc/config/$package" || { rm -f "$identity"; return 1; }
			gcm_reapply_target_identity "$identity" || { rm -f "$identity"; return 1; }
			uci commit "$package" || { rm -f "$identity"; return 1; }
			rm -f "$identity"
		fi
		gcm_log "APPLIED=uci:$package"
	done
	for package in network firewall wireless; do
		source="$source_dir/$package"
		[ -f "$source" ] || continue
		gcm_raw_package_selected "$package" "$categories" || { gcm_log "SKIPPED=uci:$package:not-selected"; continue; }
		if [ "$strategy" = remote-safe ] && [ -n "${SSH_CONNECTION:-}" ]; then
			pending="/root/glinet-crossmodel/pending-remote-safe"
			mkdir -p "$pending" || return 1
			cp -p "$source" "$pending/$package" || return 1
			gcm_log "PRESERVED=uci:$package:active-ssh-management-path;source-staged-$pending/$package"
			continue
		fi
		if [ "$strategy" = snapshot ]; then
			cp -p "$source" "/etc/config/$package" || return 1
		else
			identity=$(mktemp /tmp/gcm-raw-identity.XXXXXX) || return 1
			gcm_target_identity_assignments "$package" "$identity"
			cp -p "$source" "/etc/config/$package" || { rm -f "$identity"; return 1; }
			gcm_reapply_target_identity "$identity" || { rm -f "$identity"; return 1; }
			uci commit "$package" || { rm -f "$identity"; return 1; }
			rm -f "$identity"
		fi
		gcm_log "APPLIED_LAST=uci:$package"
	done
	case "$strategy" in clone|remote-safe) gcm_log 'PRESERVED=target-factory-identity:source-overrides-sanitized-and-hardware-defaults-retained' ;; esac
}

gcm_apply_extra_tree() {
	tree=$1
	[ -d "$tree" ] || return 0
	find "$tree" -type f | while IFS= read -r source; do
		relative=${source#"$tree"/}
		gcm_safe_member "$relative" || exit 1
		destination="/$relative"
		mkdir -p "$(dirname "$destination")" || exit 1
		cp -p "$source" "$destination" || exit 1
		gcm_log "APPLIED=persistent:$destination"
	done
}

gcm_apply_custom_tree() {
	tree=$1
	destination_root=$2
	label=$3
	[ -d "$tree" ] || return 0
	find "$tree" -type f | while IFS= read -r source; do
		relative=${source#"$tree"/}
		gcm_safe_member "$relative" || exit 1
		destination="$destination_root/$relative"
		mkdir -p "$(dirname "$destination")" || exit 1
		cp -p "$source" "$destination" || exit 1
		gcm_log "APPLIED=$label:$destination"
	done
}

gcm_apply_custom_binaries() {
	tree=$1
	destination_root=$2
	target_arch=$3
	[ -d "$tree" ] || return 0
	find "$tree" -type f | while IFS= read -r source; do
		relative=${source#"$tree"/}
		gcm_safe_member "$relative" || exit 1
		if ! gcm_binary_compatible "$source" "$target_arch"; then gcm_log "SKIPPED=custom-binary:$relative:elf-class-or-machine-mismatch"; continue; fi
		destination="$destination_root/$relative"
		mkdir -p "$(dirname "$destination")" || exit 1
		cp -p "$source" "$destination" || exit 1
		gcm_log "APPLIED=custom-binary:$destination"
	done
}

gcm_install_selected_packages() {
	source_tsv=$1
	selected=$2
	[ -n "$selected" ] || return 0
	if ! gcm_opkg_run update; then gcm_log 'WARNING=package-feeds-unreachable;restore-continues'; return 0; fi
	supported_arches=$(gcm_supported_package_arches | tr '\n' ' ')
	while [ -n "$selected" ]; do
		package=${selected%%,*}
		if [ "$selected" = "$package" ]; then selected=''; else selected=${selected#*,}; fi
		case "$package" in ''|*[!A-Za-z0-9+._-]*) gcm_log "SKIPPED=package:$package:invalid-name"; continue ;; kmod-*) gcm_log "SKIPPED=package:$package:kernel-module"; continue ;; esac
		line=$(awk -F '\t' -v p="$package" '$1==p{print;exit}' "$source_tsv")
		[ -n "$line" ] || { gcm_log "SKIPPED=package:$package:not-in-archive"; continue; }
		is_kmod=$(printf '%s\n' "$line" | awk -F '\t' '{print $9}')
		is_user=$(printf '%s\n' "$line" | awk -F '\t' '{print $8}')
		package_arch=$(printf '%s\n' "$line" | awk -F '\t' '{print $3}')
		[ "$is_user" = true ] || { gcm_log "SKIPPED=package:$package:not-user-installed"; continue; }
		[ "$is_kmod" != true ] || { gcm_log "SKIPPED=package:$package:kernel-module"; continue; }
		gcm_package_arch_compatible "$package_arch" "$supported_arches" || { gcm_log "SKIPPED=package:$package:unsupported-architecture-$package_arch"; continue; }
		if opkg status "$package" 2>/dev/null | grep -q 'Status:.*installed'; then gcm_log "SKIPPED=package:$package:already-installed"; continue; fi
		if gcm_opkg_run install "$package"; then gcm_log "APPLIED=package:$package"; else gcm_log "SKIPPED=package:$package:unavailable-or-incompatible"; fi
	done
}

gcm_restore() {
	archive=$1
	categories=$2
	package_selection=${3:-}
	direct_custom=${4:-0}
	dangerous_override=${5:-0}
	allow_legacy=${6:-0}
	categories=$(gcm_valid_categories "$categories") || { gcm_die 'Invalid restore categories.'; return 1; }
	plan=$(gcm_validate "$archive" "$categories" "$dangerous_override") || return 1
	if ! printf '%s' "$plan" | grep -q '"compatible":true'; then gcm_die 'Restore blocked by validation incompatibility.'; return 1; fi
	kind=$(printf '%s' "$plan" | sed -n 's/.*"archive_kind":"\([^"]*\)".*/\1/p')
	if [ "$kind" = legacy-v1 ] && [ "$allow_legacy" != 1 ]; then gcm_die 'Legacy restore requires explicit --allow-legacy approval.'; return 1; fi
	work=$(mktemp -d /tmp/gcm-restore.XXXXXX) || return 1
	kind=$(gcm_extract_archive "$archive" "$work/archive") || { rm -rf "$work"; return 1; }
	if [ "$kind" = v2 ]; then
		prefix_dir="$work/archive/$GCM_PREFIX"
		manifest="$prefix_dir/manifest.json"
		gcm_verify_checksums "$prefix_dir" || { rm -rf "$work"; return 1; }
		strategy=$(gcm_manifest_field "$manifest" backup_strategy)
		profile_id=$(gcm_manifest_field "$manifest" profile_uuid)
	else
		prefix_dir="$work/archive/profile"
		strategy=legacy-portable
		profile_id="legacy-$(date +%s)-$$"
	fi
	snapshot=$(gcm_pre_restore_snapshot "$profile_id" "$prefix_dir" "$direct_custom") || { rm -rf "$work"; gcm_die 'Could not create the mandatory pre-restore snapshot.'; return 1; }
	gcm_log "PRE_RESTORE_SNAPSHOT=$snapshot/pre-restore.tar.gz"
	apply_ok=1
	case "$strategy" in
		portable)
			config_dir="$prefix_dir/portable"
			if gcm_has_category "$categories" wifi; then gcm_apply_portable_wifi "$config_dir" || apply_ok=0; fi
			gcm_apply_portable_lan_dhcp_dns "$config_dir" "$categories" || apply_ok=0
			if gcm_has_category "$categories" firewall; then gcm_apply_portable_firewall "$config_dir" || apply_ok=0; fi
			if gcm_has_category "$categories" timezone; then
				section=$(gcm_profile_sections "$config_dir" timezone | sed -n '1p')
				[ -n "$section" ] && { gcm_set_if_value system '@system[0]' zonename "$(gcm_profile_get "$config_dir" "$section" zonename)"; gcm_set_if_value system '@system[0]' timezone "$(gcm_profile_get "$config_dir" "$section" timezone)"; gcm_adapter_commit system; }
			fi
			if gcm_has_category "$categories" ddns; then gcm_apply_portable_ddns "$config_dir" || apply_ok=0; fi
			if gcm_has_category "$categories" vpn; then gcm_apply_portable_vpn "$config_dir/vpn" || apply_ok=0; fi
			;;
		clone|remote-safe|snapshot)
			gcm_apply_raw_uci "$prefix_dir/uci" "$strategy" "$categories" || apply_ok=0
			gcm_apply_extra_tree "$prefix_dir/extra" || apply_ok=0
			;;
		legacy-portable)
			# Legacy raw packages are deliberately narrower than the old backend:
			# physical network and wireless packages are never imported wholesale.
			for package in dhcp firewall wireguard openvpn adguardhome ddns; do
				[ -f "$prefix_dir/uci/$package" ] || continue
				case "$package" in dhcp) gcm_has_category "$categories" dhcp || continue ;; firewall) gcm_has_category "$categories" firewall || continue ;; wireguard|openvpn) gcm_has_category "$categories" vpn || continue ;; ddns) gcm_has_category "$categories" ddns || continue ;; esac
				uci import "$package" < "$prefix_dir/uci/$package" && uci commit "$package" || apply_ok=0
				gcm_log "APPLIED=legacy-uci:$package"
			done
			gcm_log 'SKIPPED=legacy:network-and-wireless-whole-package-import-blocked'
			;;
	esac
	stage="/root/glinet-crossmodel/restore/$profile_id"
	if [ "$direct_custom" = 1 ]; then custom_root=''; else custom_root="$stage"; fi
	if gcm_has_category "$categories" custom-files; then gcm_apply_custom_tree "$prefix_dir/artifacts/files" "$custom_root" custom-file || apply_ok=0; fi
	if gcm_has_category "$categories" custom-binaries; then
		source_arch=''
		[ -f "$prefix_dir/manifest.json" ] && source_arch=$(gcm_manifest_field "$prefix_dir/manifest.json" architecture)
		target_arch=$(gcm_architecture)
		if [ "$source_arch" = "$target_arch" ]; then gcm_apply_custom_binaries "$prefix_dir/artifacts/binaries" "$custom_root" "$target_arch" || apply_ok=0; else gcm_log "SKIPPED=custom-binaries:source-$source_arch-target-$target_arch"; fi
	fi
	if [ "$apply_ok" -eq 1 ] && gcm_has_category "$categories" packages && [ -f "$prefix_dir/source/packages.tsv" ]; then gcm_install_selected_packages "$prefix_dir/source/packages.tsv" "$package_selection"; fi
	if [ "$apply_ok" -ne 1 ]; then
		gcm_log 'RESTORE=failed;attempting-rollback'
		gcm_rollback_snapshot "$snapshot" || true
		rm -rf "$work"
		return 1
	fi
	if [ "${GCM_DEFER_RELOAD:-0}" = 1 ]; then
		gcm_log 'DEFERRED=network-firewall-wireless-reload;controller-success-received-first'
	else
		gcm_log 'PENDING_ACTIVATION=network-firewall-wireless;reboot-or-explicit-activate-required'
	fi
	gcm_log 'RESTORE=success'
	gcm_log "ROLLBACK_SNAPSHOT=$snapshot/pre-restore.tar.gz"
	rm -rf "$work"
}
