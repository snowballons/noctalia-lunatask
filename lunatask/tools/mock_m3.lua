-- tools/mock_m3.lua — M3 tests: task.update/delete + reconcile.
-- Usage: lua tools/mock_m3.lua   (run from lunatask/ dir)
local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("@(.*/)") or "./"):gsub("tools/$", "")

local files = {}
local state_store = {}
local watchers = {}
local fake_env = {}
local fake_config = {
	token = "valid-token",
	token_file = "",
	areas = { Work = "11111111-2222-3333-4444-555555555555", Other = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" },
	default_task_status = "later",
	cache_bodies = false,
	source_tag = "noctalia",
}
local ms = 1000
local last_put_body = nil

-- Fake server: tasks + notes keyed by id.
local server = { tasks = {}, notes = {}, failNext = nil }

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
		if server.failNext then
			local code = server.failNext
			server.failNext = nil
			cb({ ok = false, status = code, body = "x" })
			return true
		end
		if req.method == "GET" and path == "/ping" then
			cb({ ok = true, status = 200, body = "return {message=\"pong\"}" })
			return true
		end
		if req.method == "POST" and path == "/tasks" then
			local body = dec(req.body) or {}
			local id = "task-" .. tostring(#server.tasks + 1)
			local rec = { id = id, status = body.status or "later", priority = body.priority or 0,
				scheduled_on = body.scheduled_on, source = body.source, source_id = body.source_id }
			server.tasks[#server.tasks + 1] = rec
			cb({ ok = true, status = 201, body = "return {task=" .. enc(rec) .. "}" })
			return true
		end
		local put_id = req.method == "PUT" and path and path:match("^/tasks/(.+)$")
		if put_id then
			for _, t in ipairs(server.tasks) do
				if t.id == put_id then
					local body = dec(req.body) or {}
					last_put_body = body
					for k, v in pairs(body) do
						t[k] = v
					end
					cb({ ok = true, status = 200, body = "return {task=" .. enc(t) .. "}" })
					return true
				end
			end
			cb({ ok = false, status = 404, body = "nope" })
			return true
		end
		local del_id = req.method == "DELETE" and path and path:match("^/tasks/(.+)$")
		if del_id then
			for i, t in ipairs(server.tasks) do
				if t.id == del_id then
					table.remove(server.tasks, i)
					cb({ ok = true, status = 200, body = "return {task=" .. enc(t) .. "}" })
					return true
				end
			end
			cb({ ok = false, status = 404, body = "nope" })
			return true
		end
		if req.method == "GET" and path and path:find("^/tasks%?") then
			cb({ ok = true, status = 200, body = "return {tasks=" .. enc(server.tasks) .. "}" })
			return true
		end
		if req.method == "GET" and path and path:find("^/notes%?") then
			cb({ ok = true, status = 200, body = "return {notes=" .. enc(server.notes) .. "}" })
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
	fire("cmd.panel", { seq = seq, op = op, args = args })
	return state_store["evt.panel"]
end

local function create(title)
	local e = cmd("task.create", { title = title, area = "Work", priority = 0 })
	assert(e.ok, "setup create failed")
	return svc._registry.items[#svc._registry.items]
end

-- ── update ───────────────────────────────────────────────────────
local item = create("Original")
local e1 = cmd("task.update", { id = item.id, changes = { status = "next" } })
check("update ok", e1.ok == true)
local nkeys = 0
for _ in pairs(last_put_body) do
	nkeys = nkeys + 1
end
check("partial PUT sends only status", nkeys == 1 and last_put_body.status == "next")
check("registry status updated", item.status == "next" and item.state == "synced")

local e2 = cmd("task.update", { id = item.id, changes = { name = "Renamed", priority = 1 } })
check("rename+priority ok", e2.ok == true and item.title == "Renamed" and item.priority == 1)
check("bad status rejected", cmd("task.update", { id = item.id, changes = { status = "zzz" } }).ok == false)
check("bad date rejected", cmd("task.update", { id = item.id, changes = { scheduled_on = "x" } }).ok == false)
check("update unknown registry id", cmd("task.update", { id = "ghost", changes = { status = "next" } }).ok == false)

-- 404 from server -> orphaned
item.id = "task-gone"
local e3 = cmd("task.update", { id = "task-gone", changes = { status = "next" } })
check("server 404 -> orphaned + not_found", e3.ok == false and item.state == "orphaned")
item.id = "task-1" -- restore (server task-1 exists)
item.state = "synced"

-- ── delete ───────────────────────────────────────────────────────
local victim = create("Doomed")
local n_before = #svc._registry.items
local ed = cmd("task.delete", { id = victim.id })
check("delete ok removes locally", ed.ok == true and #svc._registry.items == n_before - 1)
check("server record gone", #server.tasks == 1)
check("delete unknown id -> ok (idempotent)", cmd("task.delete", { id = "ghost" }).ok == true)

-- delete 404 (removed elsewhere) -> removed locally, ok
local ghost = create("Ghost")
for i, t in ipairs(server.tasks) do
	if t.id == ghost.id then
		table.remove(server.tasks, i)
		break
	end
end
local ed2 = cmd("task.delete", { id = ghost.id })
check("delete 404 -> ok + removed", ed2.ok == true and #svc._registry.items == n_before - 1)

-- delete unsynced (no remote id) -> local drop, ok
table.insert(svc._registry.items, { kind = "task", id = nil, source_id = "nct-x", state = "failed", title = "t" })
local ed3 = cmd("task.delete", { id = "nct-x" })
check("delete unsynced -> local drop", ed3.ok == true)

-- ── reconcile ────────────────────────────────────────────────────
-- app-side completion: flip server record directly
for _, t in ipairs(server.tasks) do
	if t.id == "task-1" then
		t.status = "completed"
	end
end
local er = cmd("registry.refresh", nil)
check("refresh ok", er.ok == true)
check("app-side status reflected", item.status == "completed")

-- app-side area move (+ unknown area)
for _, t in ipairs(server.tasks) do
	if t.id == "task-1" then
		t.area_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	end
end
cmd("registry.refresh", nil)
check("app-side area reflected", item.area_id == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" and item.area_name == "Other")
for _, t in ipairs(server.tasks) do
	if t.id == "task-1" then
		t.area_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
	end
end
cmd("registry.refresh", nil)
check("unknown area keeps id, clears name", item.area_id == "ffffffff-ffff-ffff-ffff-ffffffffffff" and item.area_name == nil)

-- orphan: registry item missing server-side
table.insert(svc._registry.items, { kind = "task", id = "task-absent", source_id = "nct-a",
	state = "synced", title = "Gone", status = "later", priority = 0 })
local er2 = cmd("registry.refresh", nil)
local absent = nil
for _, it in ipairs(svc._registry.items) do
	if it.source_id == "nct-a" then
		absent = it
	end
end
check("missing item orphaned", er2.ok == true and absent.state == "orphaned")

-- orphan guard: 3+ items, majority missing -> warn, no orphan
for i = 1, 3 do
	table.insert(svc._registry.items, { kind = "task", id = "task-m" .. i, source_id = "nct-m" .. i,
		state = "synced", title = "m", status = "later", priority = 0 })
end
server.tasks = {} -- server looks empty (e.g. wrong source_tag)
local er3 = cmd("registry.refresh", nil)
local still_synced = true
for _, it in ipairs(svc._registry.items) do
	if it.source_id and it.source_id:find("^nct%-m") and it.state ~= "synced" then
		still_synced = false
	end
end
local evt = state_store["evt.panel"]
check("mass-missing guard holds", er3.ok == true and still_synced and evt.warning ~= nil)

-- refresh transport failure -> no mutation
server.failNext = 500
local states_before = {}
for _, it in ipairs(svc._registry.items) do
	states_before[it.source_id or "?"] = it.state
end
local er4 = cmd("registry.refresh", nil)
local unchanged = true
for _, it in ipairs(svc._registry.items) do
	if states_before[it.source_id or "?"] ~= it.state then
		unchanged = false
	end
end
check("failed refresh mutates nothing", er4.ok == false and unchanged)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
