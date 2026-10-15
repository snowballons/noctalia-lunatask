-- service.luau (M0: token resolution + ping only)
-- Owns: token resolution (D3), GET /v1/ping via noctalia.http, onIpc test hook.
-- M1 adds: registry, command/event protocol, queue. M2+ adds task/note/journal ops.
local api = require("./lib/api.luau")

noctalia.setUpdateInterval(1000)

-- Token resolution order (D3): env -> file -> setting.
-- Returns trimmed token string or nil.
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

-- Watchdog tick. M0 has no queue; M7 drives retry timers here.
function update()
end

-- Test hook (singleton service => address with `all` target):
--   noctalia msg plugin snowballons/lunatask:core all ping
function onIpc(event, _payload)
	if event == "ping" then
		ping(function(r)
			-- Never log the token or bodies (§10.1): method + status only.
			local status = tostring(r.status or (r.err and r.err.status) or 0)
			local kind = (r.err and r.err.kind) or "-"
			noctalia.log("ping ok=" .. tostring(r.ok) .. " status=" .. status .. " kind=" .. kind)
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
	end
end

function onConfigChanged()
	-- Settings were updated in place; drop anything derived from them.
	-- noctalia.state survives a service restart, so caches must be keyed
	-- to config (§5.4). M0 keeps only this flag.
	noctalia.state.set("token_checked", false)
end

function onExit(_signal, _reason)
	noctalia.log("lunatask service exiting")
end

-- Exposed for the mock test harness (tools/mock_ping.lua re-requires this
-- file with a stubbed noctalia; the service table is the seam).
-- In Noctalia these are globals; returning them harms nothing.
return {
	resolveToken = resolveToken,
	ping = ping,
}
