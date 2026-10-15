-- lib/ids.luau (M2)
-- source_id generation (D7), date helpers. Stock-lua compatible.
local M = {}

local counter = 0
local seeded = false

-- Collision-resistant idempotency key. The API does not enforce uniqueness
-- of source/source_id, so a collision would silently suppress a create.
function M.newSourceId()
	if not seeded then
		math.randomseed(math.floor(noctalia.nowMs()))
		seeded = true
	end
	counter = counter + 1
	return string.format("nct-%d-%04x-%d", math.floor(noctalia.nowMs()), math.random(0, 0xFFFF), counter)
end

function M.isDate(s)
	return type(s) == "string" and s:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

function M.isUuid(s)
	return type(s) == "string"
		and s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

function M.today()
	return os.date("%Y-%m-%d") -- local date; see V-14
end

function M.utcNow()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

return M
