-- tests/fixtures/luci/util-copcall.lua
--
-- Coroutine-safe protected call, faithful to luci.util.copcall / coxpcall on
-- LuCI 22.03 (libs/luci-lib-base/luasrc/util.lua lines ~724-778, the Kepler
-- coxpcall algorithm). Raw pcall() cannot yield across the C-call boundary on
-- Lua 5.1, so the wrapped function runs in a child coroutine and every yield
-- is forwarded to the caller. This is the exact primitive LuCI itself uses
-- for coroutine-safe protected calls (e.g. template rendering).

local function id(trace)
	return trace
end

local function handleReturnValue(co, status, ...)
	if not status then
		return false, ...
	end
	if coroutine.status(co) == "suspended" then
		return handleReturnValue(co, coroutine.resume(co, coroutine.yield(...)))
	end
	return true, ...
end

local copcall

function copcall(f, ...)
	local current = coroutine.running()
	if not current then
		-- Main coroutine: no yield forwarding required (CGI mode).
		return pcall(f, ...)
	end
	local co = coroutine.create(f)
	return handleReturnValue(co, coroutine.resume(co, ...))
end

return { copcall = copcall }
