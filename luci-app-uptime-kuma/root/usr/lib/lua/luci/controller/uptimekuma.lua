-- LuCI controller for the Lua (pre-JS) LuCI builds.
--
-- Vendor firmwares built from the 21.02 tree sometimes still ship the old Lua
-- LuCI: no /www/luci-static/resources/luci.js, theme = bootstrap, every page
-- registered from /usr/lib/lua/luci/controller/*.lua.  On those, menu.d and the
-- JS view are ignored, so the page has to exist in this form too.  Modern LuCI
-- ignores this file and uses menu.d + resources/view instead; both forms ship
-- in the package and each runtime picks the one it understands.

module("luci.controller.uptimekuma", package.seeall)

local dispatcher = require "luci.dispatcher"
local http = require "luci.http"
local sys = require "luci.sys"
local util = require "luci.util"
local fs = require "nixio.fs"

local INIT = "/etc/init.d/uptime-kuma"
local BACKUP = "/usr/libexec/luci-app-uptime-kuma/backup"

local function cfg(opt, default)
	local cursor = require("luci.model.uci").cursor()
	local value = cursor:get("uptime-kuma", "main", opt)
	return (value == nil or value == "") and default or value
end

local function cfg_set(opt, value)
	require("luci.model.uci").cursor():set("uptime-kuma", "main", opt, value)
end

function index()
	local page = entry({"admin", "services", "uptime-kuma"},
		template("uptime-kuma/overview"), _("Uptime Kuma"), 60)
	page.acl_depends = { "luci-app-uptime-kuma" }

	entry({"admin", "services", "uptime-kuma", "control"}, call("action_control"), nil).leaf = true
	entry({"admin", "services", "uptime-kuma", "save"}, call("action_save"), nil).leaf = true
	entry({"admin", "services", "uptime-kuma", "backup"}, call("action_backup"), nil).leaf = true
end

-- State used by the view.
function status()
	local running, pid = false, nil
	local ok, res = pcall(util.ubus, "service", "list", { name = "uptime-kuma" })

	if ok and type(res) == "table" and type(res["uptime-kuma"]) == "table" then
		for _, instance in pairs(res["uptime-kuma"].instances or {}) do
			if instance.running then
				running = true
				pid = instance.pid
			end
		end
	end

	return {
		installed = fs.access(INIT),
		running = running,
		pid = pid,
		listen = cfg("listen", "0.0.0.0"),
		port = cfg("port", "3001"),
		data_dir = cfg("data_dir", "/opt/uptime-kuma/data"),
	}
end

function logtail()
	return sys.exec("logread -e uptime-kuma 2>/dev/null | tail -n 40")
end

local function back(query)
	http.redirect(dispatcher.build_url("admin/services/uptime-kuma") .. (query or ""))
end

function action_control()
	local what = http.formvalue("do")
	local target = (what == "stop" or what == "restart") and what or "start"
	sys.call(INIT .. " " .. target .. " >/dev/null 2>&1")
	back("?msg=" .. http.urlencode(target))
end

function action_save()
	local port = http.formvalue("port")
	local listen = http.formvalue("listen")
	local data_dir = http.formvalue("data_dir")
	local err

	if port and port ~= "" then
		local n = tonumber(port)
		if n and n > 0 and n < 65536 and port:match("^%d+$") then
			cfg_set("port", port)
		else
			err = "port"
		end
	end

	if not err and listen and listen ~= "" then
		cfg_set("listen", listen)
	end

	if not err and data_dir and data_dir ~= "" then
		if not data_dir:match("^/") then
			err = "data_dir"
		elseif data_dir:match("^/tmp") then
			err = "tmpfs"
		else
			cfg_set("data_dir", data_dir)
		end
	end

	if not err then
		require("luci.model.uci").cursor():commit("uptime-kuma")
		sys.call(INIT .. " restart >/dev/null 2>&1")
		back("?msg=saved")
	else
		back("?err=" .. http.urlencode(err))
	end
end

function action_backup()
	local out = sys.exec(BACKUP .. " 2>&1")
	back("?backup=" .. http.urlencode((out or ""):gsub("%s+$", "")))
end
