local util = require('util')

local Element = { lang = 'html' }
local Rule = { lang = 'css' }
local Raw = {}

local Component = {}
local Modifier = {}

local Dsl = {}

local attr_seps = {
	['srcset'] = ', ',
	['accept'] = ', ',
	-- otherwise, default to space
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

local function raise_error(node, msg)
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

-- parent is the current node that we're pushing into (target of modifiers).
-- "If", "For", and similar constructs pass their parent instead of themselves
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
			raise_error(node, ('%s node used in %s context'):format(node.lang, lang))
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

-- {{{ HTML elements
Element.__index = Element

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
	for k, v in pairs(self.props) do
		local str
		if type(v) == 'table' then
			local sep = attr_seps[k] or ' '
			str = table.concat(v, sep)
		else
			str = tostring(v)
		end
		builder:push(' ' .. k .. '="' .. escape_html(str) .. '"')
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

-- {{{ CSS rules
Rule.__index = Rule

function Rule.new(selector)
	return function(args)
		local self = setmetatable({}, Rule)
		capture_trace(self, 3)

		self.selector = selector
		self.props = {}
		self.children = {}

		for raw_k, v in pairs(args) do
			if type(raw_k) == 'string' then
				local k, _ = raw_k:gsub('_', '-')
				self.props[k] = v
			end
		end

		for _, v in ipairs(args) do
			self.children[#self.children+1] = v
		end

		return self
	end
end

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
			local prop = k:gsub('_', '-')
			local val = self.props[k]

			if type(val) == 'table' then
				-- array-based fallbacks (color = { 'black', 'var(--theme)' })
				for j, sub_val in ipairs(val) do
					builder:push(prop .. ':' .. tostring(sub_val) .. ';')

					-- don't add a newline if it's the last value of the last property
					if not (i == #keys and j == #val) then
						builder:newline()
					end
				end
			else
				builder:push(prop .. ':' .. tostring(val) .. ';')
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
-- }}}

-- {{{ support raw unescaped strings
Raw.__index = Raw

function Raw.new(text)
	local self = setmetatable({}, Raw)
	self.text = tostring(text)
	return self
end

function Raw:resolve(_, _, _)
	return { self }
end

function Raw:build(builder, _, _)
	-- directly push unescaped string
	builder:push(self.text)
end
-- }}}

-- {{{ user-defined components
Component.__index = Component

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

function Component.new_macro(name, render_fn)
	return function(args)
		local self = Component.new(name, render_fn)(args)

		self.is_macro = true

		return self
	end
end

function Component:resolve(parent, ctx, lang)
	local inner = self.render_fn(self.args, ctx)

	-- if the component is a macro, modifiers apply to the parent
	local target = self.is_macro and parent or self
	local current_lang = self.lang or lang

	-- components are inlined
	return resolve_node(target, inner, ctx, current_lang)
end
-- }}}

-- {{{ user-defined modifiers
Modifier.__index = Modifier

function Modifier.new(name, apply_fn, lang)
	return function(args)
		local self = setmetatable({}, Modifier)
		capture_trace(self, 3)

		self.name = name
		self.lang = lang -- nil is fine
		self.apply_fn = apply_fn

		if type(args) ~= 'table' then
			self.args = { args }
		else
			self.args = args
		end

		return self
	end
end

function Modifier:resolve(parent, ctx, _)
	if parent then
		self.apply_fn(self, parent, ctx, util.unpack(self.args))
	else
		raise_error(self, 'modifier used without a valid parent node')
	end

	-- modifiers are erased from the AST
	return {}
end
-- }}}

Dsl.Element = Element
Dsl.Component = Component
Dsl.Modifier = Modifier

Dsl.Rule = Rule.new
Dsl.Raw = Raw.new

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

function Dsl.register_attr_sep(attr, sep)
	attr_seps[attr] = sep
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

-- {{{ builtin components
Dsl.If = Component.new_macro('If', function(args, ctx)
	local cond = args.cond
	if cond == nil then
		cond = args[1]
	end

	local evaluated_cond
	if type(cond) == 'function' then
		evaluated_cond = cond(ctx)
	else
		evaluated_cond = cond
	end

	if evaluated_cond then
		return args.if_true or args[2]
	else
		return args.if_false or args[3]
	end
end)

Dsl.ForEach = Component.new_macro('ForEach', function(args, ctx)
	local items = args.items or args[1]
	local render = args.render or args[2]

	local iter, state, var
	if type(items) == 'function' then
		iter, state, var = items(ctx)
	elseif type(items) == 'table' then
		iter, state, var = ipairs(items)
	else
		return nil
	end

	local fragment = {}
	for k, v in iter, state, var do
		fragment[#fragment+1] = render(k, v, ctx)
	end
	return fragment
end)
-- }}}

-- {{{ builtin modifiers
Dsl.Set = Modifier.new('Set', function(_, element, _, k, v)
	if element.props then
		element.props[k] = v
	end
end)

Dsl.Append = Modifier.new('Append', function(_, node, _, key, values)
	if not node.props then return end

	if type(values) ~= 'table' then
		values = { values }
	end

	local current = node.props[key]

	if current == nil then
		-- make fresh array
		node.props[key] = {}
		for _, v in ipairs(values) do
			node.props[key][#node.props[key]+1] = v
		end
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

-- env setup to pass through globals, lazily create HTML elements,
-- and handle write-only component registration
setmetatable(Dsl, {
	__index = function(env, k)
		if _G[k] then return _G[k] end

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
