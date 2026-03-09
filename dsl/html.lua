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


-- elements are nodes which are transformed into HTML tags
-- "p { id = 'my-paragraph', 'Hello world!' }"
local Element = setmetatable({}, { __index = core.Node })
Element.__index = Element
Element.__call = core.Node.__call
M.Element = Element

-- automagically interpret uncalled "elements" as CSS keywords e.g.
-- "display = flex" = "display = 'flex'" => "display: flex;"
Element.__tostring = function(self) return self.tag end

function Element.new(tag)
	return core.Node.new(Element, {
		tag = Element.format_key(tag),
		is_void = is_void_element[tag] or false,
		next_lang = tag == 'style' and 'css' or nil
	})
end

function Element:is_mergeable(key)
	return M.attr_seps[key] ~= nil
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
		local v = self.props[k]

		local str
		if type(v) == 'table' and not getmetatable(v) then
			local sep = M.attr_seps[k] or ' '
			str = table.concat(v, sep)
		else
			str = tostring(v)
		end
		builder:push(' ' .. k .. '="' .. core.escape_html(str) .. '"')
	end
	builder:push('>')

	if self.is_void then return end

	if #self.children > 0 then
		builder:indent()
		builder:newline()
		for i, child in ipairs(self.children) do
			if type(child) == 'table' then
				-- fragments are resolved during the resolve step, so
				-- table children are guaranteed to be Nodes
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
