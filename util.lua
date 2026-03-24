---@diagnostic disable: deprecated
local util = {}

util.unpack = table.unpack or unpack

function util.eval_with_env(filepath, env)
	local chunk

	if _VERSION == 'Lua 5.1' then
		local fn, err = loadfile(filepath)
		if fn then
			chunk = setfenv(fn, env)
		else
			error(err)
		end
	else
		local fn, err = loadfile(filepath, nil, env)
		if fn then
			chunk = fn
		else
			error(err)
		end
	end

	return chunk()
end

function util.log(msg, level, scope)
	level = level or 'info'

	local prefix = level
	if scope then
		prefix = prefix .. '(' .. scope .. ')'
	end
	prefix = prefix .. ':'

	print(prefix, msg)
end

-- make a read-only view of a table
function util.freeze(tbl)
	local proxy = {}
	return setmetatable(proxy, {
		__index = tbl,
		__newindex = function (_, _, _)
			error('attempt to modify read-only table')
		end,
		__pairs = function()
			return pairs(tbl)
		end,
		__ipairs = function()
			return ipairs(tbl)
		end,
		__len = function()
			return #tbl
		end
	})
end

-- return a shallow copy of a table
function util.shallow_copy(tbl)
	local mt = getmetatable(tbl)
	local res = {}
	for k, v in pairs(tbl) do
		res[k] = v
	end
	return setmetatable(res, mt)
end

local function spairs_iter(tbl, k)
	local v
	repeat
		k, v = next(tbl, k)
	until type(k) == 'string' or k == nil
	return k, v
end

-- iterate over only pairs with string keys
function util.spairs(tbl)
	return spairs_iter, tbl, nil
end

return util
