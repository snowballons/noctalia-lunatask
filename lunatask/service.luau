-- service.luau (M1: registry owner + command protocol + ping)
-- Owns: token resolution (D3), registry.json (D2/D8), FIFO request queue (D9),
-- GET /v1/ping. M2+ adds task/note/journal ops onto handleOp.
local api = require("./lib/api.luau")
local registry = require("./lib/registry.luau")
local ids = require("./lib/ids.luau")

noctalia.setUpdateInterval(1000)

-- ── registry (single writer: this service) ──────────────────────
local reg = registry.load()

local function publishRegistry()
	noctalia.state.set("registry", { schema = reg.schema, items = reg.items })
end

publishRegistry()

-- ── token resolution (D3: env -> file -> setting) ───────────────
local function resolveToken()
	local env = noctalia.getenv("LUNATASK_ACCESS_TOKEN")
	if env ~= nil and env ~= "" then
		return noctalia.string.trim(env)
	end

	local file = noctalia.getConfig("token_file")
	if file ~= nil and file ~= "" then
		-- Trim: settings GUI entries can carry stray whitespace.
		local raw = noctalia.readFile(noctalia.expandPath(noctalia.string.trim(file)))
		if raw ~= nil and raw ~= "" then
			return noctalia.string.trim(raw)
		end
	end

	local setting = noctalia.getConfig("token")
	if setting ~= nil and setting ~= "" then
		return noctalia.string.trim(setting)
	end
	return nil
end

local function ping(reply)
	local token = resolveToken()
	if not token then
		reply({ ok = false, err = { kind = "config", status = 0, message = "no token" } })
		return
	end
	api.request(token, "GET", "/ping", nil, reply)
end

-- ── verification seam: last ping outcome on disk (no secrets) ──
local function writeStatus(r)
	local dir = noctalia.pluginDataDir()
	if not dir then
		return
	end
	local status = r.status or (r.err and r.err.status) or 0
	local kind = (r.err and r.err.kind) or "-"
	local encoded = noctalia.json.encode({
		ok = r.ok == true,
		status = status,
		kind = kind,
		at = noctalia.nowMs(),
	})
	if encoded then
		noctalia.writeFile(dir .. "/status.json", encoded)
	end
end

-- ── command queue (D9: one request in flight, FIFO) ─────────────
local queue = {}
local busy = false
local lastSeq = { panel = 0, launcher = 0 }

local function reply(sender, seq, op, result)
	noctalia.state.set("evt." .. sender, {
		seq = seq,
		op = op,
		ok = result.ok == true,
		err = result.err,
		orphaned = result.orphaned,
		warning = result.warning,
	})
end

-- Per-op logic. M1: ping, registry.refresh, registry.forget.
-- M2: task.create, task.retry. M3: task.update, task.delete, real reconcile.
local VALID_STATUS = { later = true, next = true, started = true, waiting = true, completed = true }

local function adoptCreate(item, id)
	item.id = id
	item.state = "synced"
	item.last_error = nil
	item.updated_at = ids.utcNow()
	registry.save(reg)
	publishRegistry()
end

local function failCreate(item, err, done)
	item.state = "failed"
	item.last_error = err and err.kind or "server"
	item.updated_at = ids.utcNow()
	registry.save(reg)
	publishRegistry()
	done({ ok = false, err = err })
end

-- Outcome unknown (204 duplicate, 5xx, network): recover the id by lookup (D7).
local function recoverCreate(token, sourceTag, sourceId, item, fallbackErr, done)
	api.listTasksBySource(token, sourceTag, sourceId, function(l)
		local t = l.ok and l.tasks and l.tasks[1]
		if t and t.id then
			adoptCreate(item, t.id)
			done({ ok = true })
		else
			failCreate(item, fallbackErr or { kind = "server", status = 0, message = "unknown outcome" }, done)
		end
	end)
end

local function finishPostTask(token, sourceTag, sourceId, item, r, done)
	if r.ok and r.data and r.data.task and r.data.task.id then
		adoptCreate(item, r.data.task.id)
		done({ ok = true })
	elseif r.ok then
		recoverCreate(token, sourceTag, sourceId, item, nil, done)
	else
		local kind = r.err and r.err.kind
		if kind == "server" or kind == "network" or kind == "timeout" then
			recoverCreate(token, sourceTag, sourceId, item, r.err, done)
		else
			failCreate(item, r.err, done)
		end
	end
end

local function postTask(token, sourceTag, sourceId, fields, item, done)
	local payload = {
		area_id = fields.area_id,
		name = fields.title,
		status = fields.status,
		priority = fields.priority,
		source = sourceTag,
		source_id = sourceId,
	}
	if fields.scheduled_on then
		payload.scheduled_on = fields.scheduled_on
	end
	if fields.note then
		payload.note = fields.note
	end
	api.request(token, "POST", "/tasks", payload, function(r)
		finishPostTask(token, sourceTag, sourceId, item, r, done)
	end)
end

local function taskCreate(args, done)
	args = args or {}
	local title = args.title and noctalia.string.trim(tostring(args.title)) or ""
	if title == "" then
		done({ ok = false, err = { kind = "validation", status = 0, message = "title required" } })
		return
	end
	local areas = noctalia.getConfig("areas")
	local areaName = args.area
	local areaId = (type(areas) == "table" and type(areaName) == "string") and areas[areaName] or nil
	if type(areaId) == "string" then
		areaId = noctalia.string.trim(areaId)
	end
	if not ids.isUuid(areaId) then
		done({ ok = false, err = { kind = "validation", status = 0, message = "unknown area" } })
		return
	end
	local status = args.status
	if not VALID_STATUS[status] then
		status = noctalia.getConfig("default_task_status")
	end
	if not VALID_STATUS[status] then
		status = "later"
	end
	local priority = args.priority
	if priority == nil then
		priority = 0
	end
	if type(priority) ~= "number" or priority < -2 or priority > 2 or priority ~= math.floor(priority) then
		done({ ok = false, err = { kind = "validation", status = 0, message = "bad priority" } })
		return
	end
	local scheduled = args.scheduled_on
	if scheduled == nil or scheduled == "" then
		scheduled = nil
	elseif not ids.isDate(scheduled) then
		done({ ok = false, err = { kind = "validation", status = 0, message = "bad date" } })
		return
	end
	local note = args.note and noctalia.string.trim(tostring(args.note)) or nil
	if note == "" then
		note = nil
	end
	local token = resolveToken()
	if not token then
		done({ ok = false, err = { kind = "config", status = 0, message = "no token" } })
		return
	end
	local sourceTag = noctalia.getConfig("source_tag")
	if type(sourceTag) ~= "string" or sourceTag == "" then
		sourceTag = "noctalia"
	end
	local cacheBodies = noctalia.getConfig("cache_bodies") == true
	local sourceId = ids.newSourceId()
	local now = ids.utcNow()
	local item = {
		kind = "task",
		id = nil,
		source_id = sourceId,
		state = "pending_create",
		title = title,
		area_id = areaId,
		area_name = areaName,
		status = status,
		priority = priority,
		scheduled_on = scheduled,
		has_note = note ~= nil,
		body = (cacheBodies and note) or nil,
		note_dropped = nil,
		created_at = now,
		updated_at = now,
		last_error = nil,
	}
	registry.add(reg, item)
	registry.save(reg)
	publishRegistry()
	postTask(token, sourceTag, sourceId, {
		area_id = areaId,
		title = title,
		status = status,
		priority = priority,
		scheduled_on = scheduled,
		note = note,
	}, item, done)
end

local function taskRetry(args, done)
	local key = args and args.id
	-- Failed creates have no remote id yet; source_id is the stable key
	-- (it is always minted at submit time).
	local item = nil
	if type(key) == "string" and key ~= "" then
		item = registry.findById(reg, key) or registry.findBySourceId(reg, key)
	end
	if not item or item.kind ~= "task" then
		done({ ok = false, err = { kind = "not_found", status = 0, message = "unknown id" } })
		return
	end
	if item.state ~= "failed" then
		done({ ok = false, err = { kind = "validation", status = 0, message = "only failed items can be retried" } })
		return
	end
	local token = resolveToken()
	if not token then
		done({ ok = false, err = { kind = "config", status = 0, message = "no token" } })
		return
	end
	local sourceTag = noctalia.getConfig("source_tag")
	if type(sourceTag) ~= "string" or sourceTag == "" then
		sourceTag = "noctalia"
	end
	item.state = "pending_create"
	-- Same source_id: a POST for an item that actually exists returns 204,
	-- and the lookup path adopts it instead of duplicating (D7).
	item.note_dropped = (item.has_note and item.body == nil) or nil
	registry.save(reg)
	publishRegistry()
	postTask(token, sourceTag, item.source_id, {
		area_id = item.area_id,
		title = item.title,
		status = item.status,
		priority = item.priority,
		scheduled_on = item.scheduled_on,
		note = item.body,
	}, item, done)
end

-- Stable lookup: remote id when synced, source_id before first sync.
local function findTask(key)
	if type(key) ~= "string" or key == "" then
		return nil
	end
	return registry.findById(reg, key) or registry.findBySourceId(reg, key)
end

local function syncTaskFromResponse(item, remote)
	-- Metadata comes from the response; titles/bodies only from our edits
	-- (the API never returns them, C1).
	if remote.status ~= nil then
		item.status = remote.status
	end
	if remote.priority ~= nil then
		item.priority = remote.priority
	end
	item.scheduled_on = remote.scheduled_on
	item.state = "synced"
	item.last_error = nil
	item.updated_at = ids.utcNow()
end

local function taskUpdate(args, done)
	args = args or {}
	local item = findTask(args.id)
	if not item or item.kind ~= "task" then
		done({ ok = false, err = { kind = "not_found", status = 0, message = "unknown id" } })
		return
	end
	if item.id == nil then
		done({ ok = false, err = { kind = "validation", status = 0, message = "not created yet" } })
		return
	end
	local changes = args.changes
	if type(changes) ~= "table" then
		done({ ok = false, err = { kind = "validation", status = 0, message = "missing changes" } })
		return
	end
	-- Validate first, send only the changed attributes (partial PUT).
	local payload = {}
	local count = 0
	if changes.name ~= nil then
		local name = noctalia.string.trim(tostring(changes.name))
		if name == "" then
			done({ ok = false, err = { kind = "validation", status = 0, message = "title required" } })
			return
		end
		payload.name = name
		count = count + 1
	end
	if changes.note ~= nil then
		payload.note = tostring(changes.note)
		count = count + 1
	end
	if changes.status ~= nil then
		if not VALID_STATUS[changes.status] then
			done({ ok = false, err = { kind = "validation", status = 0, message = "bad status" } })
			return
		end
		payload.status = changes.status
		count = count + 1
	end
	if changes.priority ~= nil then
		local p = changes.priority
		if type(p) ~= "number" or p < -2 or p > 2 or p ~= math.floor(p) then
			done({ ok = false, err = { kind = "validation", status = 0, message = "bad priority" } })
			return
		end
		payload.priority = p
		count = count + 1
	end
	if changes.scheduled_on ~= nil then
		if not ids.isDate(changes.scheduled_on) then
			done({ ok = false, err = { kind = "validation", status = 0, message = "bad date" } })
			return
		end
		payload.scheduled_on = changes.scheduled_on
		count = count + 1
	end
	if count == 0 then
		done({ ok = true })
		return
	end
	local token = resolveToken()
	if not token then
		done({ ok = false, err = { kind = "config", status = 0, message = "no token" } })
		return
	end
	local cacheBodies = noctalia.getConfig("cache_bodies") == true
	item.state = "pending_update"
	registry.save(reg)
	publishRegistry()
	api.request(token, "PUT", "/tasks/" .. item.id, payload, function(r)
		if r.ok and r.data and r.data.task then
			if payload.name then
				item.title = payload.name
			end
			if payload.note ~= nil then
				item.has_note = true
				item.note_dropped = nil
				item.body = cacheBodies and payload.note or nil
			end
			syncTaskFromResponse(item, r.data.task)
			registry.save(reg)
			publishRegistry()
			done({ ok = true })
		elseif r.status == 404 then
			item.state = "orphaned"
			item.updated_at = ids.utcNow()
			registry.save(reg)
			publishRegistry()
			done({ ok = false, err = { kind = "not_found", status = 404, message = "gone from Lunatask" } })
		else
			item.state = "failed"
			item.last_error = r.err and r.err.kind or "server"
			item.updated_at = ids.utcNow()
			registry.save(reg)
			publishRegistry()
			done({ ok = false, err = r.err })
		end
	end)
end

local function taskDelete(args, done)
	local key = args and args.id
	local item = findTask(key)
	-- Idempotent success: unknown locally means nothing to delete.
	if not item or item.kind ~= "task" then
		done({ ok = true })
		return
	end
	-- Never synced remotely: drop locally, goal achieved.
	if item.id == nil then
		registry.removeById(reg, item.source_id)
		registry.save(reg)
		publishRegistry()
		done({ ok = true })
		return
	end
	local token = resolveToken()
	if not token then
		done({ ok = false, err = { kind = "config", status = 0, message = "no token" } })
		return
	end
	item.state = "pending_delete"
	registry.save(reg)
	publishRegistry()
	api.request(token, "DELETE", "/tasks/" .. item.id, nil, function(r)
		if r.ok or r.status == 404 then
			-- 404 on delete is success: the goal (gone) is achieved.
			registry.removeById(reg, item.source_id)
			registry.save(reg)
			publishRegistry()
			done({ ok = true })
		else
			item.state = "failed"
			item.last_error = r.err and r.err.kind or "server"
			item.updated_at = ids.utcNow()
			registry.save(reg)
			publishRegistry()
			done({ ok = false, err = r.err })
		end
	end)
end

-- Reconciliation (§7.5): refresh metadata from the server, mark items that
-- vanished elsewhere as orphaned. Never mutates on transport failure, and
-- never mass-orphans on a suspiciously empty response.
local function reconcileKind(items, remoteById, apply, done_count)
	local missing = {}
	for _, item in ipairs(items) do
		if item.id ~= nil and item.state ~= "orphaned" and item.state ~= "pending_create"
			and item.state ~= "pending_update" and item.state ~= "pending_delete" then
			local remote = remoteById[item.id]
			if remote then
				apply(item, remote)
			else
				missing[#missing + 1] = item
			end
		end
	end
	return missing
end

local function reconcile(done)
	local token = resolveToken()
	if not token then
		done({ ok = false, err = { kind = "config", status = 0, message = "no token" } })
		return
	end
	local sourceTag = noctalia.getConfig("source_tag")
	if type(sourceTag) ~= "string" or sourceTag == "" then
		sourceTag = "noctalia"
	end
	api.listTasks(token, sourceTag, function(tr)
		if not tr.ok then
			done({ ok = false, err = tr.err })
			return
		end
		api.listNotes(token, sourceTag, function(nr)
			if not nr.ok then
				done({ ok = false, err = nr.err })
				return
			end
			local remoteTasks = {}
			for _, t in ipairs(tr.tasks) do
				if t.id ~= nil then
					remoteTasks[t.id] = t
				end
			end
			local remoteNotes = {}
			for _, n in ipairs(nr.notes) do
				if n.id ~= nil then
					remoteNotes[n.id] = n
				end
			end
			local regTasks = {}
			local regNotes = {}
			for _, item in ipairs(reg.items) do
				if item.kind == "task" then
					regTasks[#regTasks + 1] = item
				elseif item.kind == "note" then
					regNotes[#regNotes + 1] = item
				end
			end
			local taskMissing = reconcileKind(regTasks, remoteTasks, function(item, remote)
				syncTaskFromResponse(item, remote)
			end)
			local noteMissing = reconcileKind(regNotes, remoteNotes, function(item, _remote)
				item.state = "synced"
				item.last_error = nil
				item.updated_at = ids.utcNow()
			end)
			-- Orphan guard: a response that wrongly looks empty (e.g. changed
			-- source_tag) must not wipe the registry. Refuse to orphan the
			-- majority, and say so.
			local warning = nil
			local function applyMissing(missing)
				local orphaned = 0
				if #missing > 0 and not (#regTasks + #regNotes >= 3 and #missing > (#regTasks + #regNotes) / 2) then
					for _, item in ipairs(missing) do
						item.state = "orphaned"
						item.updated_at = ids.utcNow()
						orphaned = orphaned + 1
					end
				elseif #missing > 0 then
					warning = "refresh skipped orphaning (" .. tostring(#missing) .. " missing)"
				end
				return orphaned
			end
			local orphaned = applyMissing(taskMissing) + applyMissing(noteMissing)
			registry.save(reg)
			publishRegistry()
			done({ ok = true, orphaned = orphaned, warning = warning })
		end)
	end)
end
local function handleOp(op, args, done)
	if op == "ping" then
		ping(function(r)
			writeStatus(r)
			done(r)
		end)
	elseif op == "registry.refresh" then
		reconcile(done)
	elseif op == "registry.forget" then
		local id = args and args.id
		if type(id) ~= "string" or id == "" then
			done({ ok = false, err = { kind = "validation", status = 0, message = "missing id" } })
			return
		end
		if registry.removeById(reg, id) then
			registry.save(reg)
			publishRegistry()
			done({ ok = true })
		else
			done({ ok = false, err = { kind = "not_found", status = 0, message = "unknown id" } })
		end
	elseif op == "task.create" then
		taskCreate(args, done)
	elseif op == "task.retry" then
		taskRetry(args, done)
	elseif op == "task.update" then
		taskUpdate(args, done)
	elseif op == "task.delete" then
		taskDelete(args, done)
	else
		done({ ok = false, err = { kind = "validation", status = 0, message = "unknown op" } })
	end
end

local function pump()
	if busy or #queue == 0 then
		return
	end
	busy = true
	local job = table.remove(queue, 1)
	job.run(function(result)
		busy = false
		reply(job.sender, job.seq, job.op, result)
		pump()
	end)
end

local function enqueue(sender, msg)
	if type(msg) ~= "table" or type(msg.seq) ~= "number" or msg.seq <= (lastSeq[sender] or 0) then
		return
	end
	lastSeq[sender] = msg.seq
	table.insert(queue, {
		sender = sender,
		seq = msg.seq,
		op = msg.op,
		run = function(done)
			handleOp(msg.op, msg.args, done)
		end,
	})
	pump()
end

noctalia.state.watch("cmd.panel", function(msg)
	enqueue("panel", msg)
end)
noctalia.state.watch("cmd.launcher", function(msg)
	enqueue("launcher", msg)
end)

-- Watchdog tick. M1: nothing to expire yet; M7 drives retry timers here.
function update()
end

-- Test hooks (singleton service => address with the `all` target):
--   noctalia msg plugin snowballons/lunatask:core all ping
--   noctalia msg plugin snowballons/lunatask:core all refresh
function onIpc(event, _payload)
	if event == "ping" then
		ping(function(r)
			-- Never log the token or bodies (§10.1): method + status only.
			local status = tostring(r.status or (r.err and r.err.status) or 0)
			local kind = (r.err and r.err.kind) or "-"
			noctalia.log("ping ok=" .. tostring(r.ok) .. " status=" .. status .. " kind=" .. kind)
			writeStatus(r)
			if r.ok then
				noctalia.notify("Lunatask", noctalia.tr("notify.connected"))
			elseif r.err and r.err.kind == "config" then
				noctalia.notifyError("Lunatask", noctalia.tr("err.config"))
			elseif r.err and r.err.kind == "auth" then
				noctalia.notifyError("Lunatask", noctalia.tr("err.auth"))
			else
				noctalia.notifyError("Lunatask", noctalia.tr("err.network"))
			end
		end)
	elseif event == "refresh" then
		reconcile(function(r)
			noctalia.log("refresh ok=" .. tostring(r.ok) .. " orphaned=" .. tostring(r.orphaned or 0))
		end)
	end
end

function onConfigChanged()
	-- Settings were updated in place; drop anything derived from them.
	-- noctalia.state survives a service restart, so caches must be keyed
	-- to config (§5.4).
	noctalia.state.set("token_checked", false)
end

function onExit(_signal, _reason)
	registry.save(reg)
	noctalia.log("lunatask service exiting")
end

-- Seam for the mock harness (host ignores chunk return values).
return {
	resolveToken = resolveToken,
	ping = ping,
	handleOp = handleOp,
	enqueue = enqueue,
	_registry = reg,
}
