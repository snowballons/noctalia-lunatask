-- tools/mock_m4.lua — M4 tests: note.create/update/delete/retry + reconcile.
-- Usage: lua tools/mock_m4.lua   (run from lunatask/ dir)
local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("@(.*/)") or "./"):gsub("tools/$", "")

local files = {}
local state_store = {}
local watchers = {}
local fake_env = {}
local fake_config = {
	token = "valid-token",
	token_file = "",
	notebooks = { Work = "22222222-3333-4444-5555-666666666666", Later = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff" },
	default_notebook = "",
	areas = { Work = "11111111-2222-3333-4444-555555555555" },
	default_task_status = "later",
	cache_bodies = false,
	source_tag = "noctalia",
}
local ms = 1000
local last_put_body = nil
local server = { notes = {}, nextId = 1 }

local function enc(v)
	local t = type(v)
	if t == "string" then
		return string.format("%q", v)
	elseif t == "number" or t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		local is_arr, n = true, 0
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
		if req.method == "POST" and path == "/notes" then
			local body = dec(req.body) or {}
			if body.notebook_id == "error-uuid" then
				cb({ ok = false, status = 422, body = "bad" })
				return true
			end
			local id = "note-" .. tostring(server.nextId)
			server.nextId = server.nextId + 1
			local rec = { id = id, notebook_id = body.notebook_id, date_on = body.date_on,
				source = body.source, source_id = body.source_id }
			server.notes[#server.notes + 1] = rec
			cb({ ok = true, status = 201, body = "return {note=" .. enc(rec) .. "}" })
			return true
		end
		local put_id = req.method == "PUT" and path and path:match("^/notes/(.+)$")
		if put_id then
			for _, n in ipairs(server.notes) do
				if n.id == put_id then
					local body = dec(req.body) or {}
					last_put_body = body
					for k, v in pairs(body) do
						n[k] = v
					end
					cb({ ok = true, status = 200, body = "return {note=" .. enc(n) .. "}" })
					return true
				end
			end
			cb({ ok = false, status = 404, body = "nope" })
			return true
		end
		local del_id = req.method == "DELETE" and path and path:match("^/notes/(.+)$")
		if del_id then
			for i, n in ipairs(server.notes) do
				if n.id == del_id then
					table.remove(server.notes, i)
					cb({ ok = true, status = 200, body = "return {note=" .. enc(n) .. "}" })
					return true
				end
			end
			cb({ ok = false, status = 404, body = "nope" })
			return true
		end
		if req.method == "GET" and path and path:find("^/notes") then
			local sid = path:match("source_id=(.*)")
			local out = {}
			for _, n in ipairs(server.notes) do
				if sid == nil or n.source_id == sid then
					out[#out + 1] = { id = n.id, notebook_id = n.notebook_id, date_on = n.date_on }
				end
			end
			cb({ ok = true, status = 200, body = "return {notes=" .. enc(out) .. "}" })
			return true
		end
		if req.method == "GET" and path and path:find("^/tasks") then
			cb({ ok = true, status = 200, body = "return {tasks={}}" })
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

-- ── create ───────────────────────────────────────────────────────
local e = cmd("note.create", { title = "Meeting", notebook = "Work", content = "hello", date_on = "2026-10-20" })
check("create ok", e.ok == true)
local item = svc._registry.items[1]
check("synced with id", item.state == "synced" and item.id == "note-1")
check("notebook resolved", item.notebook_id == "22222222-3333-4444-5555-666666666666")
check("no body cached by default", item.body == nil)

local e2 = cmd("note.create", { title = "Unfiled" })
local item2 = svc._registry.items[2]
check("no notebook -> omitted", e2.ok == true and item2.notebook_id == nil)

check("empty title rejected", cmd("note.create", { title = " " }).ok == false)
check("unknown notebook rejected", cmd("note.create", { title = "x", notebook = "Nope" }).ok == false)
check("bad date rejected", cmd("note.create", { title = "x", date_on = "soon" }).ok == false)

-- ── update: rename must not send content ──────────────────────────
local eu = cmd("note.update", { id = item.id, changes = { name = "Renamed" } })
check("rename ok", eu.ok == true and item.title == "Renamed")
check("rename sends no content", last_put_body.name == "Renamed" and last_put_body.content == nil)

local ec = cmd("note.update", { id = item.id, changes = { content = "replaced" } })
check("content replace ok", ec.ok == true and last_put_body.content == "replaced")

local em = cmd("note.update", { id = item.id, changes = { date_on = "2026-11-01" } })
check("re-date ok", em.ok == true and item.date_on == "2026-11-01")

item.id = "note-gone"
local e404 = cmd("note.update", { id = "note-gone", changes = { name = "x" } })
check("server 404 -> orphaned", e404.ok == false and item.state == "orphaned")
item.id = "note-1"
item.state = "synced"

-- ── delete ───────────────────────────────────────────────────────
local n_before = #svc._registry.items
local ed = cmd("note.delete", { id = item2.id })
check("delete ok removes locally", ed.ok == true and #svc._registry.items == n_before - 1)
check("delete unknown -> ok", cmd("note.delete", { id = "ghost" }).ok == true)

-- ── reconcile notes ──────────────────────────────────────────────
-- app-side move + re-date reflected (names/bodies never come back, C1)
for _, n in ipairs(server.notes) do
	if n.id == "note-1" then
		n.notebook_id = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
		n.date_on = "2026-12-01"
	end
end
local erm = cmd("registry.refresh", nil)
check("app-side move+redate reflected",
	erm.ok == true and item.notebook_id == "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
		and item.notebook_name == "Later" and item.date_on == "2026-12-01")

for i, n in ipairs(server.notes) do
	if n.id == "note-1" then
		table.remove(server.notes, i)
		break
	end
end
local er = cmd("registry.refresh", nil)
check("vanished note orphaned", er.ok == true and item.state == "orphaned")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
