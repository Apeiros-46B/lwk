local util = require('util')
local core = require('dsl.core')
local html = require('dsl.html')
local css = require('dsl.css')
local ext = require('dsl.ext')
local builtins = require('dsl.builtins')
local config = require('dsl.config')

local Dsl = {}


-- try getting the member with the given key from all submodules
local function get_member(k)
	local existing = rawget(Dsl, k)
	if existing then return existing end

	if html[k] then return html[k] end
	if css[k] then return css[k] end
	if ext[k] then return ext[k] end
	if builtins[k] then return builtins[k] end

	return nil
end


function Dsl.render(root, builder, ctx, lang)
	lang = lang or 'html'
	local resolved = core.resolve_node(nil, root, ctx, lang)
	for _, node in ipairs(resolved) do
		if type(node) == 'table' then
			node:build(builder, ctx, lang)
		else
			builder:push(node)
		end
	end
end

function Dsl.register_component(filepath)
	local name = filepath:match('([^/]+)%.lua$')

	if not name then
		error(('invalid component name "%s"'):format(filepath), 2)
	end

	if get_member(name) ~= nil then
		error(('component "%s" already exists'):format(name), 2)
	end

	local comp = util.eval_with_env(filepath, Dsl)
	Dsl[name] = comp

	util.log('registered component ' .. name, 'info', 'dsl')

	return comp
end

function Dsl.set_config(t)
	for k, v in pairs(t) do
		config[k] = v
	end
end


-- env setup to pass through globals, lazily create HTML elements,
-- and handle write-only component registration
setmetatable(Dsl, {
	__index = function(env, k)
		-- HTML "table" element has a conflict with Lua's table library
		if k ~= 'table' and _G[k] then return _G[k] end
		if type(k) ~= 'string' then return nil end

		local member = get_member(k)
		if member ~= nil then
			rawset(env, k, member)
			return member
		end

		if k:find('^%u') then
			-- component might not be loaded yet, return a lazy wrapper to defer component
			-- resolution to render-time (make not components error when they reference other
			-- components before they have been registered)

			-- not cached so that register_component can install the real one
			return function(props)
				return setmetatable({ _lazy_name = k, _lazy_props = props }, {
					__index = {
						resolve = function(self, parent, ctx, lang)
							local real = get_member(k) or rawget(Dsl, k)
							if not real then
								error(('unknown component "%s"'):format(k), 2)
							end
							return core.resolve_node(parent, real(self._lazy_props), ctx, lang)
						end,
					}
				})
			end
		end

		-- lazily generate HTML elements
		local element = html.Element.new(k)
		rawset(env, k, element)
		return element
	end,
	__newindex = function(env, k, v)
		if type(k) ~= 'string' then
			error(('cannot use non-string key "%s"'):format(tostring(k)), 2)
		end
		if k:find('^%l') then
			error(('component name "%s" cannot start with lowercase'):format(k), 2)
		end
		if get_member(k) ~= nil then
			error(('component "%s" already exists'):format(k), 2)
		end

		rawset(env, k, v)
	end
})


return Dsl
