--!nonstrict
-- lib/registry.luau (M1)
-- Local memory of items this plugin created (D2, §7).
-- Single writer: service.luau. Atomic replace via tmp + rename.
-- Tables are plain data so they can travel over noctalia.state.
local M = {}

M.SCHEMA = 1
M.FILENAME = "registry.json"

function M.path()
	local dir, err = noctalia.pluginDataDir()
	if not dir then
		return nil, err
	end
	return dir .. "/" .. M.FILENAME
end

function M.blank()
	return { schema = M.SCHEMA, items = {} }
end

function M.load()
	local p, err = M.path()
	if not p then
		return M.blank(), err
	end
	local raw = noctalia.readFile(p)
	if not raw or raw == "" then
		return M.blank()
	end
	local data = noctalia.json.decode(raw)
	if type(data) ~= "table" or data.schema ~= M.SCHEMA or type(data.items) ~= "table" then
		return M.blank()
	end
	return data
end

function M.save(reg)
	local p = M.path()
	if not p then
		return false
	end
	local encoded = noctalia.json.encode(reg)
	if not encoded then
		return false
	end
	local tmp = p .. ".tmp"
	if not noctalia.writeFile(tmp, encoded) then
		return false
	end
	return noctalia.renameFile(tmp, p)
end

function M.add(reg, item)
	table.insert(reg.items, item)
	return item
end

function M.findById(reg, id)
	for _, item in ipairs(reg.items) do
		if item.id == id then
			return item
		end
	end
	return nil
end

function M.findBySourceId(reg, sourceId)
	for _, item in ipairs(reg.items) do
		if item.source_id == sourceId then
			return item
		end
	end
	return nil
end

-- Removes locally only ("Forget", or after a confirmed remote delete).
-- Matches a remote id or, for items that never synced, the source_id.
-- Returns true when something was removed.
function M.removeById(reg, id)
	for i, item in ipairs(reg.items) do
		if item.id == id or item.source_id == id then
			table.remove(reg.items, i)
			return true
		end
	end
	return false
end

return M
