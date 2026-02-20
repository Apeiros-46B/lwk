local util = {}

---@diagnostic disable-next-line: deprecated
util.unpack = table.unpack or unpack

function util.wrap_env(env, fn, ...)
	if _VERSION == 'Lua 5.1' then
		setfenv(fn, env)(...)
	else
		_ENV = env
		fn(...)
	end
end

return util
