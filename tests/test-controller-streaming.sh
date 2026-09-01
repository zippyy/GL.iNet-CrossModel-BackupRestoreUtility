#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

# Prefer real Lua 5.1 (the OpenWrt 22 runtime) so the legacy coroutine-yield
# boundary is exercised faithfully. Fall back to any Lua for the
# modern-side assertions.
if command -v lua5.1 >/dev/null 2>&1; then
	LUA=lua5.1
elif command -v lua >/dev/null 2>&1; then
	LUA=lua
else
	echo 'Lua interpreter is required for controller streaming checks.' >&2
	exit 1
fi

"$LUA" "$ROOT/tests/test-controller-streaming.lua" "$ROOT"
