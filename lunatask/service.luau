-- service.luau (M1: registry owner + command protocol + ping)
-- Owns: token resolution (D3), registry.json (D2/D8), FIFO request queue (D9),
-- GET /v1/ping. M2+ adds task/note/journal ops onto handleOp.
local api = require("./lib/api.luau")
local registry = require("./lib/registry.luau")

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
		local raw = noctalia.readFile(noctalia.expandPath(file))
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
	})
end

-- Per-op logic. M1 ops: ping, registry.refresh, registry.forget.
-- M2+ adds task.create/update/delete, note.*, journal.create.
local function handleOp(op, args, done)
	if op == "ping" then
		ping(function(r)
			writeStatus(r)
			done(r)
		end)
	elseif op == "registry.refresh" then
		-- M1: republish only. M3 adds server reconciliation (§7.5).
		publishRegistry()
		done({ ok = true })
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
		publishRegistry()
		noctalia.log("registry republished items=" .. tostring(#reg.items))
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
