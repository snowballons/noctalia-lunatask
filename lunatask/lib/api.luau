-- lib/api.luau (M0)
-- Thin wrapper around noctalia.http for the Lunatask API.
-- Base URL: https://api.lunatask.app/v1
-- Auth: "Authorization: bearer <token>" (lowercase bearer, per docs).
-- Response handling decides by HTTP status, NOT by res.ok alone (V-01):
-- the docs only show { ok, status, body } without defining ok for non-2xx.
local M = {}

M.BASE = "https://api.lunatask.app/v1"

-- Reconciliation lookup (C6/D7): find items by idempotency pair.
-- Always resolves { ok, tasks } on transport success, even when empty.
function M.listTasksBySource(token, sourceTag, sourceId, cb)
	local q = "/tasks?source=" .. noctalia.string.urlEncode(sourceTag) .. "&source_id=" .. noctalia.string.urlEncode(sourceId)
	M.request(token, "GET", q, nil, function(r)
		if r.ok then
			local tasks = (r.data and r.data.tasks) or {}
			if type(tasks) ~= "table" then
				tasks = {}
			end
			cb({ ok = true, tasks = tasks })
		else
			cb({ ok = false, err = r.err })
		end
	end)
end

-- Full reconcile lists (§7.5): everything this source tag created.
-- Resolves { ok, tasks } / { ok, notes }; empty arrays are valid.
function M.listTasks(token, sourceTag, cb)
	local q = "/tasks?source=" .. noctalia.string.urlEncode(sourceTag)
	M.request(token, "GET", q, nil, function(r)
		if r.ok then
			local tasks = (r.data and r.data.tasks) or {}
			if type(tasks) ~= "table" then
				tasks = {}
			end
			cb({ ok = true, tasks = tasks })
		else
			cb({ ok = false, err = r.err })
		end
	end)
end

function M.listNotes(token, sourceTag, cb)
	local q = "/notes?source=" .. noctalia.string.urlEncode(sourceTag)
	M.request(token, "GET", q, nil, function(r)
		if r.ok then
			local notes = (r.data and r.data.notes) or {}
			if type(notes) ~= "table" then
				notes = {}
			end
			cb({ ok = true, notes = notes })
		else
			cb({ ok = false, err = r.err })
		end
	end)
end

-- Single-note recovery (D7): find by idempotency pair.
function M.listNotesBySource(token, sourceTag, sourceId, cb)
	local q = "/notes?source=" .. noctalia.string.urlEncode(sourceTag) .. "&source_id=" .. noctalia.string.urlEncode(sourceId)
	M.request(token, "GET", q, nil, function(r)
		if r.ok then
			local notes = (r.data and r.data.notes) or {}
			if type(notes) ~= "table" then
				notes = {}
			end
			cb({ ok = true, notes = notes })
		else
			cb({ ok = false, err = r.err })
		end
	end)
end

-- Map HTTP status to plugin err.kind (spec §11.1).
-- No 429 / Retry-After is documented, so there is no rate-limit branch.
function M.classify(status)
	if status == 401 then
		return "auth"
	elseif status == 402 then
		return "plan"
	elseif status == 404 then
		return "not_found"
	elseif status == 400 or status == 422 then
		return "validation"
	elseif status == 500 or status == 503 or status == 524 then
		return "server"
	else
		return "server"
	end
end

-- Build the Authorization header value. Split out for unit tests.
function M.authHeader(token)
	return "Authorization: bearer " .. token
end

-- cb({ ok, status, data, err = { kind, status, message } })
-- body may be nil (GET / DELETE without payload).
function M.request(token, method, path, body, cb)
	local headers = {
		M.authHeader(token),
		"Accept: application/json",
	}
	local payload = ""
	if body ~= nil then
		local encoded, err = noctalia.json.encode(body)
		if not encoded then
			cb({ ok = false, status = 0, err = { kind = "validation", status = 0, message = tostring(err) } })
			return
		end
		payload = encoded
		table.insert(headers, "Content-Type: application/json")
	end

	local accepted = noctalia.http({
		url = M.BASE .. path,
		method = method,
		body = payload,
		headers = headers,
		follow_redirects = false,
	}, function(res)
		local status = (res and res.status) or 0
		if status >= 200 and status < 300 then
			local data = nil
			if status ~= 204 and res.body ~= nil and res.body ~= "" then
				local decoded = noctalia.json.decode(res.body)
				if decoded == nil then
					cb({ ok = false, status = status, err = { kind = "server", status = status, message = "bad json" } })
					return
				end
				data = decoded
			end
			cb({ ok = true, status = status, data = data })
		elseif status == 0 then
			cb({ ok = false, status = 0, err = { kind = "network", status = 0, message = "transport" } })
		else
			cb({ ok = false, status = status, err = { kind = M.classify(status), status = status, message = res.body } })
		end
	end)

	if not accepted then
		cb({ ok = false, status = 0, err = { kind = "network", status = 0, message = "request not accepted" } })
	end
end

return M
