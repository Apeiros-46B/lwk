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

-- iterate over only pairs with string keys
function util.spairs(tbl)
	return coroutine.wrap(function()
		for k, v in pairs(tbl) do
			if type(k) == 'string' then
				coroutine.yield(k, v)
			end
		end
	end)
end

return util
