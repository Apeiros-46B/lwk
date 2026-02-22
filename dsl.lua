local util = require('util')

local Dsl = {}

-- {{{ html handling helpers
local attr_seps = {
	srcset = ', ',
	accept = ', ',
	class = ' ',
	style = ';',
}

function Dsl.register_attr_sep(attr, sep)
	attr_seps[attr] = sep
end

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

local html_escapes = {
	['&'] = '&amp;',
	['<'] = '&lt;',
	['>'] = '&gt;',
	['"'] = '&quot;',
	["'"] = '&#39;'
}

local function escape_html(str)
	local res, _ = str:gsub("[&<>\"']", html_escapes)
	return res
end
-- }}}

-- {{{ debug logging helpers
local function capture_trace(obj, level)
	-- level 3 = user code calling the closure
	level = level or 3
	local info = debug.getinfo(level, 'Sl')
	if info then
		obj.debug_src = ('%s:%d'):format(info.short_src, info.currentline)
	else
		obj.debug_src = 'unknown location'
	end
	obj.debug_trace = debug.traceback('', level)
	return obj
end

function Dsl.raise_error(node, msg)
	local fmt = [[
[DSL] %s
  Location: %s
  Context:  %s
	]]
	local err = fmt:format(
		msg,
		node.debug_src or 'unknown location',
		node.debug_trace or ''
	)
	error(err, 0)
end
-- }}}

-- {{{ tree building helpers
-- parent is the current node that we're pushing into (target of modifiers).
-- components pass their parent instead of themselves so nested modifiers apply properly
local function resolve_node(parent, node, ctx, lang)
	local ty = type(node)
	if not node then return {} end

	if ty == 'string' or ty == 'number' then
		local str = tostring(node)
		if lang == 'html' then
			return { escape_html(str) }
		else
			-- don't escape raw strings in CSS
			return { str }
		end
	elseif ty == 'function' then
		return resolve_node(parent, node(ctx), ctx, lang)
	elseif ty == 'table' then
		if lang and node.lang and lang ~= node.lang then
			Dsl.raise_error(node, ('%s node used in %s context'):format(node.lang, lang))
		end

		if type(node.resolve) == 'function' then
			return node:resolve(parent, ctx, lang)
		else
			-- implicit fragment
			local resolved = {}
			for _, child in ipairs(node) do
				for _, res in ipairs(resolve_node(parent, child, ctx, lang)) do
					resolved[#resolved+1] = res
				end
			end
			return resolved
		end
	end
	return {}
end

local function merge_attr(existing, new_value, mergeable)
	if not mergeable then
		return new_value
	end

	local merged = {}
	if existing ~= nil then
		if type(existing) == 'table' then
			for _, v in ipairs(existing) do
				merged[#merged+1] = v
			end
		else
			merged[#merged+1] = existing
		end
	end

	if new_value ~= nil then
		if type(new_value) == 'table' then
			for _, v in ipairs(new_value) do
				merged[#merged+1] = v
			end
		else
			merged[#merged+1] = new_value
		end
	end

	return merged
end

function Dsl.render(root, builder, ctx, lang)
	lang = lang or 'html'
	local resolved = resolve_node(nil, root, ctx, lang)
	for _, node in ipairs(resolved) do
		if type(node) == 'table' then
			node:build(builder, ctx, lang)
		else
			builder:push(node)
		end
	end
end
-- }}}

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
local Rule = {}
Rule.__index = Rule
Rule.lang = 'css'

function Rule.new(selector)
	return function(args)
		local self = setmetatable({}, Rule)
		capture_trace(self, 3)

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
		for _, res in ipairs(resolve_node(self, child, ctx, 'css')) do
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

			if type(v) == 'table' then
				-- array-based fallbacks (color = { 'black', 'var(--theme)' })
				for j, sub_val in ipairs(v) do
					builder:push(prop .. ':' .. tostring(sub_val) .. ';')

					-- don't add a newline if it's the last value of the last property
					if not (i == #keys and j == #v) then
						builder:newline()
					end
				end
			else
				if v == '' then v = '""' end
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

Dsl.Vars = function(selector)
	return function(args)
		local new_args = {}
		for k, v in util.spairs(args) do
			new_args['--' .. k:gsub('_', '-')] = v
		end
		return Rule.new(selector)(new_args)
	end
end

Dsl.Var = function(name)
	return 'var(--' .. name:gsub('_', '-') .. ')'
end

-- TODO: is it worth having css units and functions syntax
-- }}}

-- {{{ CSS queries
local Query = {}
Query.__index = Query
Query.lang = 'css'

-- media { min_width = 600 } { ... }
function Query:__call(args)
	local clone = util.shallow_copy(self)
	capture_trace(clone, 3)

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
		capture_trace(self, 3)

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
		for _, res in ipairs(resolve_node(self, child, ctx, 'css')) do
			resolved[#resolved+1] = res
		end
	end
	self.children = resolved
	return { self }
end

function Query:build(builder, ctx, parent)
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

-- currying
function Element:__call(args)
	local clone = util.shallow_copy(self)
	capture_trace(clone, 3)

	clone.props = util.shallow_copy(self.props)
	clone.children = util.shallow_copy(self.children)

	if type(args) ~= 'table' then
		args = { args }
	end

	for k, v in util.spairs(args) do
		clone.props[k] = merge_attr(clone.props[k], v, attr_seps[k] ~= nil)
	end

	for _, child in ipairs(args) do
		clone.children[#clone.children+1] = child
	end

	return clone
end

function Element.new(tag)
	return function(args)
		local self = setmetatable({}, Element)
		capture_trace(self, 3)

		self.tag = tag
		self.is_void = is_void_element[tag] or false

		self.props = {}
		self.children = {}

		if tag == 'style' then
			-- switch to css for children when this is a style node
			self.next_lang = 'css'
		end

		if type(args) ~= 'table' then
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

function Element:resolve(_, ctx, lang)
	local resolved = {}
	for _, child in ipairs(self.children) do
		for _, res in ipairs(resolve_node(self, child, ctx, self.next_lang or lang)) do
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
		if type(v) == 'table' then
			local sep = attr_seps[k] or ' '
			str = table.concat(v, sep)
		else
			str = tostring(v)
		end
		builder:push(' ' .. prop .. '="' .. escape_html(str) .. '"')
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
	capture_trace(clone, 3)

	if type(self.args) ~= 'table' then
		clone.args = { self.args }
	else
		clone.args = util.shallow_copy(self.args)
	end

	if type(args) ~= 'table' then
		args = { args }
	end

	for k, v in util.spairs(args) do
		clone.args[k] = merge_attr(clone.args[k], v, attr_seps[k] ~= nil)
	end

	for _, child in ipairs(args) do
		clone.args[#clone.args+1] = child
	end

	return clone
end

function Component.new(name, render_fn, lang)
	return function(args)
		local self = setmetatable({}, Component)
		capture_trace(self, 3)

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
	return resolve_node(parent, inner, ctx, self.lang or lang)
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
	capture_trace(clone, 3)

	clone.args = util.shallow_copy(self.args)

	for _, v in ipairs({ ... }) do
		clone.args[#clone.args + 1] = v
	end

	return clone
end

function Modifier.new(name, apply_fn, lang)
	return function(...)
		local self = setmetatable({}, Modifier)
		capture_trace(self, 3)

		self.name = name
		self.lang = lang -- nil is fine
		self.apply_fn = apply_fn

		self.args = { ... }

		-- unwrap if it's a single table arg
		if #self.args == 1 and type(self.args[1]) == 'table' then
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
	capture_trace(self, 2)
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

	return resolve_node(parent, branch, ctx, lang)
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
	capture_trace(self, 2)
	return self
end
Dsl.For = For.new

function For:resolve(parent, ctx, lang)
	local iter, state, var
	if type(self.items) == 'function' then
		iter, state, var = self.items(ctx)
	elseif type(self.items) == 'table' then
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

	return resolve_node(parent, fragment, ctx, lang)
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
	capture_trace(self, 2)
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
		return resolve_node(parent, branch, ctx, lang)
	elseif self.default ~= nil then
		return resolve_node(parent, self.default, ctx, lang)
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
	elseif type(arg) == 'table' then
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
		for _, res in ipairs(resolve_node(parent, child, inner_ctx, lang)) do
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
		if type(val) == 'table' then
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
	elseif type(current) == 'table' then
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
function Dsl.StyleSheet(args)
	if type(args) ~= 'table' then
		args = { args }
	end

	for _, rule in ipairs(args) do
		Dsl.global_styles[#Dsl.global_styles+1] = rule
	end

	return nil
end

function Dsl.render_global_css(builder, ctx)
	local resolved = resolve_node(nil, Dsl.global_styles, ctx, 'css')
	for _, node in ipairs(resolved) do
		if type(node) == 'table' then
			node:build(builder, ctx, 'css')
		else
			builder:push(node)
		end
	end
end
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
