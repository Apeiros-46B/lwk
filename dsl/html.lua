local util = require('util')
local core = require('dsl.core')

local M = {}

M.attr_seps = {
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

local Element = {}
Element.__index = Element
Element.lang = 'html'
M.Element = Element

-- HACK: make conflicting HTML tags and CSS keywords (e.g. "table") dual-purpose.
-- when called, they act like an HTML tag. when referenced, they act like strings
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
		clone.props[k] = core.merge_attr(clone.props[k], v, M.attr_seps[k] ~= nil)
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
			local sep = M.attr_seps[k] or ' '
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

return M
