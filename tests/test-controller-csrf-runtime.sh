#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

if command -v lua5.1 >/dev/null 2>&1; then
	LUA=lua5.1
elif command -v lua >/dev/null 2>&1; then
	LUA=lua
else
	echo 'Lua interpreter is required for controller CSRF runtime checks.' >&2
	exit 1
fi

"$LUA" "$ROOT/tests/test-controller-csrf-runtime.lua" "$ROOT"
