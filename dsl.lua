local util = require('util')
local core = require('dsl.core')

local Dsl = {}

local css_attr_seps = {
	['font-family'] = ', ',
	['transition'] = ', ',
	['transition-property'] = ', ',
	['animation'] = ', ',
	['animation-name'] = ', ',
	['box-shadow'] = ', ',
	['text-shadow'] = ', ',
	['background-image'] = ', ',
	['background'] = ', ',
	['src'] = ', ',
}

local html_attr_seps = {
	srcset = ', ',
	accept = ', ',
	class = ' ',
	style = ';',
}

local is_void_element = {
	area = true,
	base = true,
	br = true,
	col = true,
	embed = true,
	hr = true,
	img = true,
	input = true,
	link = true,
	meta = true,
	source = true,
	track = true,
	wbr = true,
}


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

-- {{{ raw strings
local Raw = {}
Raw.__index = Raw

function Raw.new(text)
	local self = setmetatable({}, Raw)
	self.text = tostring(text)
	return self
end
Dsl.Raw = Raw.new

function Raw:resolve(_, _, _)
	return { self }
end

function Raw:build(builder, _, _)
	-- directly push unescaped string
	builder:push(self.text)
end
-- }}}

-- {{{ CSS rules
local Fallback = {}
Fallback.__index = Fallback
Fallback.lang = 'css'

function Fallback.new(...)
	return setmetatable({ values = {...} }, Fallback)
end
Dsl.Fallback = Fallback.new

local Rule = {}
Rule.__index = Rule
Rule.lang = 'css'

function Rule.new(selector)
	return function(args)
		local self = setmetatable({}, Rule)
		core.capture_trace(self, 3)

		self.selector = selector
		self.props = {}
		self.children = {}

		for k, v in util.spairs(args) do
			self.props[k:gsub('_', '-')] = v
		end

		for _, v in ipairs(args) do
			self.children[#self.children+1] = v
		end

		return self
	end
end
Dsl.Rule = Rule.new

function Rule:resolve(_, ctx, _)
	local resolved = {}
	for _, child in ipairs(self.children) do
		for _, res in ipairs(core.resolve_node(self, child, ctx, 'css')) do
			resolved[#resolved+1] = res
		end
	end
	self.children = resolved
	return { self }
end

function Rule:build(builder, ctx, parent)
	local selector = self.selector
	if parent and parent.selector then
		if self.selector:find('&') then
			-- child selector directly references parent
			selector = self.selector:gsub('&', parent.selector)
		else
			-- standard descendant selector
			selector = parent.selector .. ' ' .. self.selector
		end
	end

	local has_props = next(self.props) ~= nil

	if has_props then
		builder:push(selector .. '{')
		builder:indent()
		builder:newline()

		-- deterministic key ordering
		local keys = {}
		for k in pairs(self.props) do
			keys[#keys+1] = k
		end
		table.sort(keys)

		for i, k in ipairs(keys) do
			local prop, _ = k:gsub('_', '-')
			local v = self.props[k]

			if getmetatable(v) == Fallback then
				-- fallback properties (color = Fallback('black', var 'bg'))
				for j, sub_val in ipairs(v) do
					builder:push(prop .. ':' .. tostring(sub_val) .. ';')

					-- don't add a newline if it's the last value of the last property
					if not (i == #keys and j == #v) then
						builder:newline()
					end
				end
			elseif type(v) == 'table' and not getmetatable(v) then
				-- auto-join literal arrays
				local sep = css_attr_seps[prop] or ' '

				-- we need to convert all values to string because keywords like
				-- `display = flex` are actually tables with __tostring, not strings
				local stringified = {}
				for j, sub_val in ipairs(v) do
					stringified[j] = tostring(sub_val)
				end

				builder:push(prop .. ':' .. table.concat(stringified, sep) .. ';')
				if i < #keys then
					builder:newline()
				end
			else
				builder:push(prop .. ':' .. tostring(v) .. ';')
				if i < #keys then
					builder:newline()
				end
			end
		end

		builder:unindent()
		builder:newline()
		builder:push('}')
	end

	if has_props and #self.children > 0 then
		builder:newline()
	end

	local original_selector = self.selector
	self.selector = selector

	for i, child in ipairs(self.children) do
		if type(child) == 'table' then
			-- only rules will be left in the AST
			child:build(builder, ctx, self)
		end
		if i < #self.children then
			builder:newline()
		end
	end

	self.selector = original_selector
end

local Import = {}
Import.__index = Import
Import.lang = 'css'

function Import.new(url)
	local self = setmetatable({ url = url }, Import)
	return core.capture_trace(self, 3)
end
Dsl.Import = Import.new

function Import:resolve()
	return { self }
end

function Import:build(builder, _, _)
	local url_str = tostring(self.url)

	if not url_str:match('^url%(') and not url_str:match('^"') and not url_str:match("^'") then
		url_str = '"' .. url_str .. '"'
	end

	builder:push('@import ' .. url_str .. ';')
end

function Dsl.InlineSvg(filepath)
	local f = io.open(filepath, 'r')
	if not f then
		util.log('could not open "' .. filepath .. '"', 'warn')
		return 'none'
	end

	local content = f:read('*a')
	f:close()

	content = content:gsub('[\n\r\t]+', ' ')
	content = content:gsub('%%', '%%25')
	content = content:gsub('#', '%%23')
	content = content:gsub('<', '%%3C')
	content = content:gsub('>', '%%3E')
	content = content:gsub('"', '%%22')
	content = content:gsub("'", '%%27')

	return "url('data:image/svg+xml;utf8," .. content .. "')"
end

function Dsl.Vars(selector)
	return function(args)
		local new_args = {}
		for k, v in util.spairs(args) do
			new_args['--' .. k:gsub('_', '-')] = v
		end
		return Rule.new(selector)(new_args)
	end
end

function Dsl.var(name)
	return 'var(--' .. name:gsub('_', '-') .. ')'
end

local css_units = {
	'px', 'cm', 'mm', 'Q', 'pc', 'pt',
	'em', 'ex', 'ch', 'rem', 'lh', 'rlh', 'cap', 'ic',
	'vw', 'vh', 'vmin', 'vmax', 'vi', 'vb',
	'svw', 'svh', 'svmin', 'svmax', 'svi', 'svb',
	'lvw', 'lvh', 'lvmin', 'lvmax', 'lvi', 'lvb',
	'dvw', 'dvh', 'dvmin', 'dvmax', 'dvi', 'dvb',
	'cqw', 'cqh', 'cqi', 'cqb', 'cqmin', 'cqmax',
	'deg', 'grad', 'rad', 'turn',
	's', 'ms',
	'dpi', 'dpcm', 'dppx', 'x',
	'fr'
}

for _, unit in ipairs(css_units) do
	Dsl[unit] = function(val)
		return tostring(val) .. unit
	end
end

function Dsl.pct(val)
	return tostring(val) .. '%'
end
function Dsl.inch(val)
	return tostring(val) .. 'in'
end

function Dsl.Str(str)
	return '"' .. str .. '"'
end
-- }}}

-- {{{ CSS queries
local Query = {}
Query.__index = Query
Query.lang = 'css'

-- media { min_width = 600 } { ... }
function Query:__call(args)
	local clone = util.shallow_copy(self)
	core.capture_trace(clone, 3)

	clone.props = util.shallow_copy(self.props)
	clone.children = util.shallow_copy(self.children)

	-- string should be mapped to the raw prop
	if type(args) == 'string' then
		clone.props.raw = args
		return clone
	elseif type(args) ~= 'table' then
		args = { args }
	end

	for k, v in util.spairs(args) do
		clone.props[k:gsub('_', '-')] = v
	end

	for _, child in ipairs(args) do
		clone.children[#clone.children+1] = child
	end

	return clone
end

function Query.new(name)
	return function(args)
		local self = setmetatable({}, Query)
		core.capture_trace(self, 3)

		self.name = name
		self.props = {}
		self.children = {}

		-- intercept a bare string and map it to the raw prop
		if type(args) == 'string' then
			self.props.raw = args
			args = {} -- clear args so the loops below safely do nothing
		elseif type(args) ~= 'table' then
			args = { args }
		end

		for k, v in util.spairs(args) do
			self.props[k:gsub('_', '-')] = v
		end

		for _, v in ipairs(args) do
			self.children[#self.children+1] = v
		end

		return self
	end
end
Dsl.Query = Query.new

function Query:resolve(_, ctx, _)
	local resolved = {}
	for _, child in ipairs(self.children) do
		for _, res in ipairs(core.resolve_node(self, child, ctx, 'css')) do
			resolved[#resolved+1] = res
		end
	end
	self.children = resolved
	return { self }
end

function Query:build(builder, ctx, _)
	local conditions = {}
	local keys = {}

	-- deterministic key ordering
	for k in pairs(self.props) do
		keys[#keys+1] = k
	end
	table.sort(keys)

	for _, k in ipairs(keys) do
		local v = self.props[k]
		if k == 'raw' then
			conditions[#conditions+1] = tostring(v)
		elseif type(v) == 'boolean' then
			if v then conditions[#conditions+1] = k end
		else
			conditions[#conditions+1] = '(' .. k .. ':' .. tostring(v) .. ')'
		end
	end

	local query_str = table.concat(conditions, ' and ')

	if query_str ~= '' then
		builder:push(self.name .. ' ' .. query_str .. ' {')
	else
		builder:push(self.name .. ' {')
	end

	builder:indent()
	builder:newline()

	for i, child in ipairs(self.children) do
		if type(child) == 'table' then
			child:build(builder, ctx, self)
		end
		if i < #self.children then
			builder:newline()
		end
	end

	builder:unindent()
	builder:newline()
	builder:push('}')
end
-- }}}

-- {{{ HTML elements
local Element = {}
Element.__index = Element
Element.lang = 'html'
Dsl.Element = Element

-- HACK: make conflicting HTML tags and CSS keywords (e.g. "table") dual-purpose. when called,
-- they act like an HTML tag. when referenced, they act like strings
local ElementCtor = {}

function ElementCtor:__call(args)
	local node = setmetatable({}, Element)
	core.capture_trace(node, 3)

	node.tag = self.tag
	node.is_void = is_void_element[self.tag] or false
	node.props = {}
	node.children = {}

	if self.tag == 'style' then
		-- switch to css for children when this is a style node
		node.next_lang = 'css'
	end

	if type(args) ~= 'table' then
		args = { args }
	end

	for k, v in util.spairs(args) do
		node.props[k:gsub('_', '-')] = v
	end

	for _, v in ipairs(args) do
		node.children[#node.children+1] = v
	end

	return node
end

function ElementCtor:__tostring()
	-- return the tag, so user can write `align_items = center` nicely
	return self.tag
end

-- currying
function Element:__call(args)
	local clone = util.shallow_copy(self)
	core.capture_trace(clone, 3)

	clone.props = util.shallow_copy(self.props)
	clone.children = util.shallow_copy(self.children)

	if type(args) ~= 'table' then
		args = { args }
	end

	for k, v in util.spairs(args) do
		clone.props[k] = core.merge_attr(clone.props[k], v, html_attr_seps[k] ~= nil)
	end

	for _, child in ipairs(args) do
		clone.children[#clone.children+1] = child
	end

	return clone
end

function Element.new(tag)
	return setmetatable({ tag = tag:gsub('_', '-') }, ElementCtor)
end

function Element:resolve(_, ctx, lang)
	local resolved = {}
	for _, child in ipairs(self.children) do
		for _, res in ipairs(core.resolve_node(self, child, ctx, self.next_lang or lang)) do
			resolved[#resolved+1] = res
		end
	end
	self.children = resolved
	return { self }
end

function Element:build(builder, ctx, lang)
	builder:push('<' .. self.tag)

	-- deterministic key ordering
	local keys = {}
	for k in pairs(self.props) do
		keys[#keys+1] = k
	end
	table.sort(keys)

	for _, k in ipairs(keys) do
		local prop, _ = k:gsub('_', '-')
		local v = self.props[k]

		local str
		if type(v) == 'table' and not getmetatable(v) then
			local sep = html_attr_seps[k] or ' '
			str = table.concat(v, sep)
		else
			str = tostring(v)
		end
		builder:push(' ' .. prop .. '="' .. core.escape_html(str) .. '"')
	end
	builder:push('>')

	if self.is_void then return end

	if #self.children > 0 then
		builder:indent()
		builder:newline()
		for i, child in ipairs(self.children) do
			if type(child) == 'table' then
				-- table children are guaranteed to be Elements or Rules
				child:build(builder, ctx, self.next_lang or lang)
			else
				builder:push(child)
			end
			if i < #self.children then
				builder:newline()
			end
		end
		builder:unindent()
		builder:newline()
	end

	builder:push('</' .. self.tag .. '>')
end
-- }}}

-- {{{ components
local Component = {}
Component.__index = Component
Dsl.Component = Component

-- currying
function Component:__call(args)
	local clone = util.shallow_copy(self)
	core.capture_trace(clone, 3)

	if type(self.args) ~= 'table' then
		clone.args = { self.args }
	else
		clone.args = util.shallow_copy(self.args)
	end

	if type(args) ~= 'table' then
		args = { args }
	end

	for k, v in util.spairs(args) do
		clone.args[k] = core.merge_attr(clone.args[k], v, html_attr_seps[k] ~= nil)
	end

	for _, child in ipairs(args) do
		clone.args[#clone.args+1] = child
	end

	return clone
end

function Component.new(name, render_fn, lang)
	return function(args)
		local self = setmetatable({}, Component)
		core.capture_trace(self, 3)

		self.tag = name
		self.lang = lang -- nil is fine
		self.args = args or {}
		self.render_fn = render_fn

		return self
	end
end

function Component:resolve(parent, ctx, lang)
	local inner = self:render_fn(parent, self.args, ctx)
	-- components are inlined, and modifiers apply to their parentsd
	return core.resolve_node(parent, inner, ctx, self.lang or lang)
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
-- }}}

-- {{{ modifiers
local Modifier = {}
Modifier.__index = Modifier
Dsl.Modifier = Modifier

-- currying
function Modifier:__call(...)
	local clone = util.shallow_copy(self)
	core.capture_trace(clone, 3)

	clone.args = util.shallow_copy(self.args)

	for _, v in ipairs({ ... }) do
		clone.args[#clone.args + 1] = v
	end

	return clone
end

function Modifier.new(name, apply_fn, lang)
	return function(...)
		local self = setmetatable({}, Modifier)
		core.capture_trace(self, 3)

		self.name = name
		self.lang = lang -- nil is fine
		self.apply_fn = apply_fn

		self.args = { ... }

		-- unwrap if it's a single table arg
		if #self.args == 1 and type(self.args[1]) == 'table' and not getmetatable(self.args[1]) then
			self.args = self.args[1]
		end

		return self
	end
end

function Modifier:resolve(parent, ctx, _)
	if parent then
		self:apply_fn(parent, ctx, util.unpack(self.args))
	else
		Dsl.raise_error(self, 'modifier used without a valid parent node')
	end

	-- modifiers are erased from AST. we cannot return nil here, return empty fragment
	return {}
end
-- }}}

-- {{{ builtin control flow
local If = {}
If.__index = If

-- If(cond) { 'if_true' } { 'if_false' }
function If:__call(children)
	local clone = util.shallow_copy(self)

	if type(children) ~= 'table' then
		children = { children }
	end

	-- true branch comes first
	if not clone.true_branch then
		clone.true_branch = children
	elseif not clone.false_branch then
		clone.false_branch = children
	else
		Dsl.raise_error(self, 'If already has both true and false branches')
	end

	return clone
end

function If.new(cond)
	local self = setmetatable({ cond = cond }, If)
	core.capture_trace(self, 2)
	return self
end
Dsl.If = If.new

function If:resolve(parent, ctx, lang)
	local eval_cond
	if type(self.cond) == 'function' then
		eval_cond = self.cond(ctx)
	else
		eval_cond = self.cond
	end

	local branch = eval_cond and self.true_branch or self.false_branch
	if not branch then return {} end

	return core.resolve_node(parent, branch, ctx, lang)
end

local For = {}
For.__index = For

-- For(items) { fn }
function For:__call(args)
	local clone = util.shallow_copy(self)

	if not clone.render_fn then
		clone.render_fn = type(args) == 'table' and args[1] or args
	else
		Dsl.raise_error(self, 'For can only have one block')
	end

	return clone
end

function For.new(items)
	local self = setmetatable({ items = items }, For)
	core.capture_trace(self, 2)
	return self
end
Dsl.For = For.new

function For:resolve(parent, ctx, lang)
	local iter, state, var
	if type(self.items) == 'function' then
		iter, state, var = self.items(ctx)
	elseif type(self.items) == 'table' and not getmetatable(self.items) then
		-- TODO: support dictionaries as well. unordered keys is an issue
		iter, state, var = ipairs(self.items)
	else
		return {}
	end

	local fragment = {}
	for k, v in iter, state, var do
		if self.render_fn then
			fragment[#fragment+1] = self.render_fn(v, k, ctx)
		else
			Dsl.raise_error(self, 'attempt to render uninitialized For')
		end
	end

	return core.resolve_node(parent, fragment, ctx, lang)
end

local Switch = {}
Switch.__index = Switch

-- Switch(value) { a = 'if_is_a', b = 'if_is_b', c = 'if_is_c' } { 'default' }
function Switch:__call(args)
	local clone = util.shallow_copy(self)

	-- cases table comes first, then default comes second
	if not clone.cases then
		if type(args) ~= 'table' then
			Dsl.raise_error(self, 'Switch expects a table of cases')
		end
		clone.cases = args
	elseif not clone.default then
		if type(args) ~= 'table' then
			args = { args }
		end
		clone.default = args
	else
		Dsl.raise_error(self, 'Switch already has both cases and a default branch')
	end

	return clone
end

function Switch.new(value)
	local self = setmetatable({ value = value }, Switch)
	core.capture_trace(self, 2)
	return self
end
Dsl.Switch = Switch.new

function Switch:resolve(parent, ctx, lang)
	if not self.cases then return {} end

	local val = self.value
	if type(val) == 'function' then
		val = val(ctx)
	end

	local branch
	if val ~= nil then
		branch = self.cases[val]
	end

	if branch ~= nil then
		return core.resolve_node(parent, branch, ctx, lang)
	elseif self.default ~= nil then
		return core.resolve_node(parent, self.default, ctx, lang)
	end

	-- no match and no default block, remove ourselves from the tree
	return {}
end
-- }}}

-- {{{ builtin components
Dsl.Document = Component.new('Document', function(_, _, args, _)
	return { Dsl.Raw('<!DOCTYPE html>\n'), Dsl.html(args) }
end)

Dsl.Classes = Component.new('Classes', function(self, _, arg, ctx)
	local map

	if type(arg) == 'function' then
		map = arg(ctx)
	elseif type(arg) == 'table' and not getmetatable(arg) then
		map = arg
	else
		Dsl.raise_error(self, 'argument to Classes should be table or fn(ctx) -> table')
	end

	local active = {}

	for class, cond in pairs(map) do
		local is_active
		if type(cond) == 'function' then
			is_active = cond(ctx)
		else
			is_active = cond
		end

		if is_active then
			active[#active+1] = class
		end
	end

	if #active > 0 then
		return Dsl.Append('class', active)
	end
end, 'html')

Dsl.Provide = Component.new('Provide', function(_, parent, args, ctx)
	local provided_data = {}
	local children = {}

	for k, v in pairs(args) do
		if type(k) == 'string' then
			provided_data[k] = v
		elseif type(k) == 'number' then
			children[k] = v
		end
	end

	local inner_ctx = setmetatable(provided_data, { __index = ctx })

	local resolved = {}
	for _, child in ipairs(children) do
		local lang = type(child) == 'table' and child.lang or nil
		for _, res in ipairs(core.resolve_node(parent, child, inner_ctx, lang)) do
			resolved[#resolved+1] = res
		end
	end

	return resolved
end)
-- }}}

-- {{{ builtin modifiers
Dsl.Set = Modifier.new('Set', function(_, node, _, k, v)
	if node.props then
		node.props[k:gsub('_', '-')] = v
	end
end)

Dsl.Append = Modifier.new('Append', function(_, node, _, k, ...)
	if not node.props then return end

	local values = {}

	for _, val in ipairs({...}) do
		if type(val) == 'table' and not getmetatable(val) then
			for _, v in ipairs(val) do
				values[#values+1] = v
			end
		else
			values[#values+1] = val
		end
	end

	if #values == 0 then return end

	local key, _ = k:gsub('_', '-')
	local current = node.props[key]

	if current == nil then
		node.props[key] = values
	elseif type(current) == 'table' and not getmetatable(current) then
		-- append to existing array
		for _, v in ipairs(values) do
			current[#current+1] = v
		end
	else
		-- upgrade existing string to an array
		node.props[key] = { current }
		for _, v in ipairs(values) do
			node.props[key][#node.props[key]+1] = v
		end
	end
end)
-- }}}

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
Dsl.LinkGlobalStyles = Element.new('link') { rel = 'stylesheet', href = Dsl.global_css_path }
-- }}}

-- env setup to pass through globals, lazily create HTML elements,
-- and handle write-only component registration
setmetatable(Dsl, {
	__index = function(env, k)
		-- HTML "table" element has a conflict with Lua's table library
		if k ~= 'table' and _G[k] then return _G[k] end
		if type(k) ~= 'string' then return nil end
		if k:find('^%u') then
			-- components always begin with uppercase
			error(('unknown component "%s"'):format(k), 2)
		end

		-- lazily generate HTML elements
		local element = Element.new(k)
		rawset(env, k, element)
		return element
	end,
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
