local util = require('util')
local core = require('dsl.core')
local css = require('dsl.css')
local html = require('dsl.html')
local ext = require('dsl.ext')
local builtins = require('dsl.builtins')

local Dsl = {}

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

	local comp = util.eval_with_env(filepath, Dsl)
	Dsl[name] = comp

	util.log('registered component ' .. filepath, 'info', 'dsl')

	return comp
end

-- {{{ global CSS extraction/bundling
Dsl.global_styles = {}

-- registers colocated CSS which is bundled into one file
function Dsl.GlobalStyles(priority, args)
	if type(priority) ~= 'number' then
		args = priority
		priority = 50
	end

	if type(args) ~= 'table' then
		args = { args }
	end

	for _, node in ipairs(args) do
		Dsl.global_styles[#Dsl.global_styles+1] = {
			priority = priority,
			node = node,
		}
	end

	return nil
end

function Dsl.render_global_css(builder, ctx)
	table.sort(Dsl.global_styles, function(a, b)
		return a.priority < b.priority
	end)

	local nodes = {}
	for _, entry in ipairs(Dsl.global_styles) do
		nodes[#nodes+1] = entry.node
	end

	local resolved = core.resolve_node(nil, nodes, ctx, 'css')
	for _, node in ipairs(resolved) do
		if type(node) == 'table' then
			node:build(builder, ctx, 'css')
		else
			builder:push(node)
		end
	end
end

Dsl.global_css_path = '/bundle.css'
Dsl.LinkGlobalStyles = html.Element.new('link') { rel = 'stylesheet', href = Dsl.global_css_path }
-- }}}

-- env setup to pass through globals, lazily create HTML elements,
-- and handle write-only component registration
setmetatable(Dsl, {
	__index = function(env, k)
		-- HTML "table" element has a conflict with Lua's table library
		if k ~= 'table' and _G[k] then return _G[k] end

		if type(k) ~= 'string' then return nil end

		if html[k] then return html[k] end
		if css[k] then return css[k] end
		if ext[k] then return ext[k] end
		if builtins[k] then return builtins[k] end

		if k:find('^%u') then
			-- components always begin with uppercase
			error(('unknown component "%s"'):format(k), 2)
		end

		-- lazily generate HTML elements
		local element = html.Element.new(k)
		rawset(env, k, element)
		return element
	end,
	-- TODO: make it so new components cannot shadow builtins
	__newindex = function(env, k, v)
		if type(k) ~= 'string' then
			error(('cannot use non-string key "%s"'):format(tostring(k)), 2)
		end
		if rawget(env, k) ~= nil then
			error(('component "%s" already exists'):format(k), 2)
		end
		if k:find('^%l') then
			error(('component name "%s" cannot start with lowercase'):format(k), 2)
		end

		rawset(env, k, v)
	end
})

return Dsl
