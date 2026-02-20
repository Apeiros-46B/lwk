local Registry = require('registry')
local util = require('util')

local Element = { lang = 'html' }
local Rule = { lang = 'css' }

local Component = {}
local Modifier = {}

local DSL = {}

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
	local err = string.format(
		'\n[ERROR] %s\n' ..
		'  Location : %s\n' ..
		'  Context  : %s\n',
		msg,
		node.debug_src or 'unknown location',
		node.debug_trace or ''
	)
	error(err, 0)
end

-- parent is the current node that we're pushing into (target of modifiers).
-- "If", "For", and similar constructs pass their parent instead of themselves
local function push_node(parent, node, builder, ctx, lang)
	local ty = type(node)

	if ty == 'string' or ty == 'number' then
		-- leaf
		builder:push(node)
	elseif ty == 'function' then
		-- lazy
		push_node(parent, node(ctx), builder, ctx, lang)
	elseif ty == 'table' then
		local mt = getmetatable(node)

		if node.lang and lang and node.lang ~= lang then
			raise_error(node, ("%s node used in %s context"):format(node.lang, lang))
		end

		if mt == Element then
			node:build(builder, ctx, lang)
		elseif mt == Rule then
			node:build(builder, ctx, parent)
		elseif mt == Component then
			node:build(builder, ctx, parent, lang)
		elseif mt == Modifier then
			node:apply(parent, ctx)
		else
			-- implicit fragment
			for _, child in ipairs(node) do
				push_node(parent, child, builder, ctx, lang)
			end
		end
	end
end

-- {{{ HTML elements
Element.__index = Element

function Element.new(tag)
	-- TODO: check if the tag name is valid
	-- maybe need to do this inside the returned function so traceback is correct

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

		for raw_k, v in pairs(args) do
			if type(raw_k) == 'string' then
				local k, _ = raw_k:gsub("_", "-")
				self.props[k] = v
			end
		end

		for _, v in ipairs(args) do
			self.children[#self.children+1] = v
		end

		return self
	end
end

function Element:build(builder, ctx, lang)
	builder:push('<' .. self.tag)
	for k, v in pairs(self.props) do
		builder:push(' ' .. k .. '="' .. tostring(v) .. '"')
	end
	builder:push('>')

	if self.is_void then
		return
	end

	if #self.children > 0 then
		builder:indent()
		builder:newline()
		for _, child in ipairs(self.children) do
			push_node(self, child, builder, ctx, self.next_lang or lang)
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
				local k, _ = raw_k:gsub("_", "-")
				self.props[k] = v
			end
		end

		for _, v in ipairs(args) do
			self.children[#self.children+1] = v
		end

		return self
	end
end

function Rule:build(builder, ctx, parent)
	local selector = self.selector
	if parent and parent.selector then
		if self.selector:find('&') then
			-- child selector directly references parent
			selector = self.selector:gsub('&', '(' .. parent.selector .. ')')
		else
			-- standard descendant selector
			selector = parent.selector .. ' ' .. self.selector
		end
	end

	if next(self.props) ~= nil then
		builder:indent()
		builder:newline()
		builder:push(selector .. '{')
		for k, v in pairs(self.props) do
			local prop = k:gsub('_', '-')
			builder:push(prop .. ':' .. tostring(v) .. ';')
		end
		builder:push('}')
		builder:unindent()
		builder:newline()
	end

	local original_selector = self.selector
	self.selector = selector

	for _, child in ipairs(self.children) do
		push_node(self, child, builder, ctx, 'css')
	end

	self.selector = original_selector
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

function Component:build(builder, ctx, parent, lang)
	local inner = self.render_fn(self.args, ctx)
	local target = self.is_macro and parent or self
	push_node(target, inner, builder, ctx, self.lang or lang)
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

function Modifier:apply(element, ctx)
	self.apply_fn(self, element, ctx, util.unpack(self.args))
end
-- }}}

DSL.Element = Element
DSL.Component = Component
DSL.Modifier = Modifier

DSL.rule = Rule.new

-- {{{ builtin components and modifiers
DSL.If = Component.new_macro('If', function(args, ctx)
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

DSL.ForEach = Component.new_macro('ForEach', function(args, ctx)
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

DSL.Set = Modifier.new('Set', function(_, element, _, k, v)
	if element.props then
		element.props[k] = v
	end
end)
-- }}}

-- env setup to auto-resolve from registry and lazily create HTML elements
setmetatable(DSL, {
	__index = function(env, k)
		if _G[k] then return _G[k] end

		local comp = Registry.get(k)
		if comp then return comp end

		local element = Element.new(k)
		rawset(env, k, element)
		return element
	end
})

return DSL
