-- tools/mock_m5.lua — M5 tests: journal.create (no lookup recovery by design).
-- Usage: lua tools/mock_m5.lua   (run from lunatask/ dir)
local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("@(.*/)") or "./"):gsub("tools/$", "")

local files = {}
local state_store = {}
local watchers = {}
local fake_env = {}
local fake_config = { token = "valid-token", token_file = "", cache_bodies = false, source_tag = "noctalia" }
local ms = 1000
local posts = {}
local mode = "ok"

local function enc(v)
	local t = type(v)
	if t == "string" then
		return string.format("%q", v)
	elseif t == "number" or t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		local parts = {}
		for k, val in pairs(v) do
			parts[#parts + 1] = "[" .. enc(k) .. "]=" .. enc(val)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "nil"
end

local function dec(s)
	if s == nil or s == "" then
		return nil
	end
	local f = loadstring and loadstring(s) or load(s)
	if not f then
		return nil
	end
	local ok, v = pcall(f)
	if not ok then
		return nil
	end
	return v
end

noctalia = {
	getenv = function(name) return fake_env[name] end,
	getConfig = function(key) return fake_config[key] end,
	readFile = function(p) return files[p] end,
	writeFile = function(p, c) files[p] = c return true end,
	renameFile = function(a, b) files[b] = files[a] files[a] = nil return true end,
	expandPath = function(p) return p end,
	pluginDataDir = function() return "/mockdata" end,
	string = {
		trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
		urlEncode = function(s) return s end,
	},
	json = {
		encode = function(v) return "return " .. enc(v) end,
		decode = dec,
	},
	http = function(req, cb)
		local path = req.url:match("^https://api%.lunatask%.app/v1(.*)$")
		if req.method == "POST" and path == "/journal_entries" then
			local body = dec(req.body) or {}
			posts[#posts + 1] = body
			if mode == "ok" then
				cb({ ok = true, status = 201,
					body = "return {journal_entry={id=\"j-1\",date_on=" .. string.format("%q", body.date_on) .. "}}" })
			else
				cb({ ok = false, status = 500, body = "oops" })
			end
			return true
		end
		if req.method == "GET" then
			-- journal has no list endpoint; any GET here would be a lookup attempt
			cb({ ok = false, status = 404, body = "?" })
			return true
		end
		cb({ ok = false, status = 404, body = "?" })
		return true
	end,
	log = function(_) end,
	notify = function(_, _) end,
	notifyError = function(_, _) end,
	tr = function(k, _) return k end,
	setUpdateInterval = function(_) end,
	runAsync = function(_) return true end,
	nowMs = function() ms = ms + 1 return ms end,
	state = {
		set = function(k, v) state_store[k] = v end,
		get = function(k) return state_store[k] end,
		watch = function(k, fn)
			watchers[k] = watchers[k] or {}
			table.insert(watchers[k], fn)
		end,
	},
}

local function fire(key, msg)
	for _, fn in ipairs(watchers[key] or {}) do
		fn(msg)
	end
end

local orig_require = require
require = function(path)
	local rel = path:match("^%./(.+)%.luau$")
	if rel then
		return assert(loadfile(PLUGIN_DIR .. rel .. ".luau"))()
	end
	return orig_require(path)
end

local pass, fail = 0, 0
local function check(name, cond, extra)
	if cond then pass = pass + 1 print("PASS " .. name)
	else fail = fail + 1 print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or "")) end
end

local svc = assert(loadfile(PLUGIN_DIR .. "service.luau"))()
local seq = 0
local function cmd(op, args)
	seq = seq + 1
	fire("cmd.panel", { seq = seq, op = op, args = args, gen = state_store["svc_boot"] })
	return state_store["evt.panel"]
end

local e = cmd("journal.create", { date_on = "2026-10-15", content = "today entry" })
check("create ok", e.ok == true)
local item = svc._registry.items[1]
check("synced with id + date", item.state == "synced" and item.id == "j-1" and item.date_on == "2026-10-15")
check("no excerpt unless caching", item.excerpt == nil)
check("post path + fields", posts[1].date_on == "2026-10-15")

fake_config.cache_bodies = true
cmd("journal.create", { date_on = "2026-10-01", content = "past entry here" })
local item2 = svc._registry.items[2]
check("past date stored", item2.date_on == "2026-10-01" and item2.state == "synced")
check("excerpt cached when on", item2.excerpt == "past entry here")
fake_config.cache_bodies = false

check("bad date rejected", cmd("journal.create", { date_on = "yesterday", content = "x" }).ok == false)
check("missing date rejected", cmd("journal.create", { content = "x" }).ok == false)
check("empty content rejected", cmd("journal.create", { date_on = "2026-10-15", content = "  " }).ok == false)

mode = "err"
local posts_before = #posts
local ef = cmd("journal.create", { date_on = "2026-10-15", content = "doomed" })
local itemf = svc._registry.items[#svc._registry.items]
check("server error -> failed item kept", ef.ok == false and itemf.state == "failed")
check("no silent duplicate posted", #posts == posts_before + 1)
mode = "ok"

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
