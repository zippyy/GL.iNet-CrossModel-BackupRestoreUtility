local root = assert(arg[1], "repository root is required")
local controller_path = root .. "/openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/lua/luci/controller/glinet_crossmodel.lua"

if not package.seeall then
	function package.seeall(target)
		local meta = getmetatable(target) or {}
		meta.__index = _G
		setmetatable(target, meta)
	end
end

if not module then
	function module(name, ...)
		local target = package.loaded[name] or {}
		package.loaded[name] = target
		target._M, target._NAME, target._PACKAGE = target, name, name:match("^(.*%.)") or ""
		for index = 1, select("#", ...) do
			local option = select(index, ...)
			if type(option) == "function" then option(target) end
		end
		local caller = debug.getinfo(2, "f").func
		local index = 1
		while true do
			local upvalue = debug.getupvalue(caller, index)
			if not upvalue then break end
			if upvalue == "_ENV" then debug.setupvalue(caller, index, target); break end
			index = index + 1
		end
	end
end

local request_method, request_json, response_status, committed
local http = {
	getenv = function(name) if name == "REQUEST_METHOD" then return request_method end end,
	content = function() return "mock-json" end,
	status = function(status) response_status = status end,
	prepare_content = function() end,
	write = function() end
}
local jsonc = {
	parse = function() return request_json end,
	stringify = function() return "{}" end
}
local fs = {
	readfile = function(path)
		if path == "/proc/sys/kernel/random/uuid" then return "11111111-1111-1111-1111-111111111111\n" end
	end,
	stat = function() return nil end,
	unlink = function() return true end,
	rename = function() return true end,
	access = function() return false end,
	writefile = function() return true end,
	chmod = function() return true end,
	glob = function() return function() return nil end end
}
local uci = {
	get = function(_, config, section, option)
		if config == "glinet_crossmodel" and section == "logging" and option == "level" then return "info" end
		if config == "glinet_crossmodel" and section == "logging" and option == "file_log" then return "0" end
		if config == "glinet_crossmodel" and section == "logging" and option == "syslog" then return "0" end
		if config == "glinet_crossmodel" and section == "logging" and option == nil then return "logging" end
	end,
	set = function() end,
	section = function() end,
	commit = function() committed = committed + 1; return true end
}

package.preload["luci.http"] = function() return http end
package.preload["luci.jsonc"] = function() return jsonc end
package.preload["nixio.fs"] = function() return fs end
package.preload["luci.dispatcher"] = function() return { context = { authtoken = "csrf-test-token" } } end
package.preload["luci.model.uci"] = function() return { cursor = function() return uci end } end

assert(loadfile(controller_path))()
local controller = assert(package.loaded["luci.controller.glinet_crossmodel"])

local function run(method, token)
	request_method = method
	request_json = { level = "debug", token = token }
	response_status = nil
	committed = 0
	controller.action_logging_save()
	return response_status, committed
end

local status, commits = run("POST", "csrf-test-token")
assert(status == 200 and commits == 1, "matching request-body token must permit the POST")

status, commits = run("POST", nil)
assert(status == 403 and commits == 0, "missing request-body token must reject the POST")

status, commits = run("POST", "login-session-id")
assert(status == 403 and commits == 0, "login session ID must not be accepted as a CSRF token")

status, commits = run("GET", "csrf-test-token")
assert(status == 405 and commits == 0, "state-changing endpoint must remain POST-only")

print("controller CSRF runtime checks passed")
