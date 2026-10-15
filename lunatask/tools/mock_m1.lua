-- tools/mock_m1.lua — M1 tests: registry roundtrip + cmd/evt protocol.
-- Usage: lua tools/mock_m1.lua   (run from lunatask/ dir)
local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("@(.*/)") or "./"):gsub("tools/$", "")

local files = {} -- in-memory filesystem: path -> content
local state_store = {}
local watchers = {}
local fake_env = {}
local fake_config = { token = "valid-token", token_file = "" }
local http_calls = 0
local in_flight = 0
local max_in_flight = 0

-- Minimal JSON-ish codec: Lua-literal roundtrip for plain data.
local function enc(v)
	local t = type(v)
	if t == "string" then
		return string.format("%q", v)
	elseif t == "number" or t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		local is_arr = true
		local n = 0
		for k, _ in pairs(v) do
			if type(k) ~= "number" then
				is_arr = false
				break
			end
			n = n + 1
		end
		local parts = {}
		if is_arr then
			for i = 1, n do
				parts[#parts + 1] = enc(v[i])
			end
			return "{" .. table.concat(parts, ",") .. "}"
		end
		for k, val in pairs(v) do
			parts[#parts + 1] = "[" .. enc(k) .. "]=" .. enc(val)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "nil"
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
		decode = function(s)
			if s == nil or s == "" then return nil end
			if s:find("pong") and not s:find("return") then return { message = "pong" } end
			local f = loadstring and loadstring(s) or load(s)
			if not f then return nil end
			local ok, v = pcall(f)
			if not ok then return nil end
			return v
		end,
	},
	http = function(req, cb)
		http_calls = http_calls + 1
		in_flight = in_flight + 1
		max_in_flight = math.max(max_in_flight, in_flight)
		cb({ ok = true, status = 200, body = '{"message":"pong"}' })
		in_flight = in_flight - 1
		return true
	end,
	log = function(_) end,
	notify = function(_, _) end,
	notifyError = function(_, _) end,
	tr = function(k, _) return k end,
	setUpdateInterval = function(_) end,
	nowMs = function() return 1000 end,
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
	-- Emulate the current panel: stamp the generation it sees.
	if (key == "cmd.panel" or key == "cmd.launcher") and type(msg) == "table" and msg.gen == nil then
		msg.gen = state_store["svc_boot"]
	end
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

-- ── registry unit tests ──────────────────────────────────────────
local registry = require("./lib/registry.luau")
local reg = registry.load()
check("empty fs -> blank schema 1", reg.schema == 1 and #reg.items == 0)
check("save blank", registry.save(reg) == true)
check("atomic: tmp gone, real present", files["/mockdata/registry.json"] ~= nil and files["/mockdata/registry.json.tmp"] == nil)
local reg2 = registry.load()
check("reload roundtrip", reg2.schema == 1 and #reg2.items == 0)

registry.add(reg, { kind = "task", id = "id-1", title = 'Quoted "title" ✓', state = "synced" })
check("save with item", registry.save(reg) == true)
local reg3 = registry.load()
check("item survives roundtrip", #reg3.items == 1 and reg3.items[1].title == 'Quoted "title" ✓')
check("findById", registry.findById(reg3, "id-1") ~= nil)
check("findById miss", registry.findById(reg3, "nope") == nil)
check("removeById", registry.removeById(reg3, "id-1") == true and #reg3.items == 0)
check("removeById miss", registry.removeById(reg3, "id-1") == false)
files["/mockdata/registry.json"] = "not json{{{"
local reg4 = registry.load()
check("corrupt file -> blank, no crash", reg4.schema == 1 and #reg4.items == 0)

-- ── service protocol tests ───────────────────────────────────────
files = {} -- reset fs so service starts blank
local svc = assert(loadfile(PLUGIN_DIR .. "service.luau"))()
check("service publishes registry state", state_store["registry"] ~= nil and state_store["registry"].schema == 1)
check("service watches both senders", watchers["cmd.panel"] ~= nil and watchers["cmd.launcher"] ~= nil)

fire("cmd.panel", { seq = 1, op = "ping" })
local e1 = state_store["evt.panel"]
check("ping roundtrip ok", e1 ~= nil and e1.seq == 1 and e1.ok == true and e1.op == "ping")
check("http called once", http_calls == 1)
check("never more than 1 in flight", max_in_flight <= 1)

fire("cmd.panel", { seq = 1, op = "ping" }) -- stale: same seq
check("stale seq ignored", http_calls == 1)
fire("cmd.panel", { seq = 0, op = "ping" }) -- stale: lower seq
check("lower seq ignored", http_calls == 1)

-- generation resync: sender restarted, counter back at 0, unseen generation
fire("cmd.panel", { seq = 1, op = "ping", gen = -1 })
check("stale gen resyncs + accepts", http_calls == 2)
fire("cmd.panel", { seq = 1, op = "ping" }) -- same gen, old seq: rejected
check("same-gen stale still rejected", http_calls == 2)

fire("cmd.panel", { seq = 2, op = "bogus-op" })
local e2 = state_store["evt.panel"]
check("unknown op -> validation err", e2 ~= nil and e2.seq == 2 and e2.ok == false)

fire("cmd.panel", { seq = 3, op = "registry.forget", args = { id = "ghost" } })
local e3 = state_store["evt.panel"]
check("forget unknown -> not_found", e3 ~= nil and e3.ok == false and e3.err.kind == "not_found")

-- forget a real item
table.insert(svc._registry.items, { kind = "task", id = "id-9", title = "x", state = "synced" })
fire("cmd.panel", { seq = 4, op = "registry.forget", args = { id = "id-9" } })
local e4 = state_store["evt.panel"]
check("forget existing -> ok", e4 ~= nil and e4.ok == true)
check("forget removed + republished", #state_store["registry"].items == 0 and #svc._registry.items == 0)

fire("cmd.panel", { seq = 5, op = "registry.refresh" })
local e5 = state_store["evt.panel"]
check("refresh -> ok", e5 ~= nil and e5.seq == 5 and e5.ok == true)

fire("cmd.launcher", { seq = 1, op = "ping" })
local e6 = state_store["evt.launcher"]
check("launcher sender roundtrip", e6 ~= nil and e6.seq == 1 and e6.ok == true)

-- FIFO: two rapid commands both answered in order
fire("cmd.panel", { seq = 6, op = "registry.refresh" })
fire("cmd.panel", { seq = 7, op = "registry.refresh" })
local e7 = state_store["evt.panel"]
check("rapid commands both answered, latest wins", e7 ~= nil and e7.seq == 7 and e7.ok == true)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
