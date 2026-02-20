local Builder = require('builder')

local Element = {}
Element.__index = Element

function Element.new(tag, args)
	local self = setmetatable({}, Element)
	self._tag = tag
	if type(args) == 'table' then
		self._args = args
	else
		self._child = args -- string child
	end
	return self
end

function Element.partial(tag)
	return function(args)
		return Element.new(tag, args)
	end
end

function Element:push_to(builder)
	-- start tag and attributes
	builder:push('<')
	builder:push(self._tag)
	if self._args then
		for attr, value in pairs(self._args) do
			if type(attr) == 'string' then
				builder:push(' ')
				builder:push(attr)
				builder:push('="')
				builder:push(value)
				builder:push('"')
			end
		end
	end
	builder:push('>')

	-- children
	if self._args then
		builder:indent()
		builder:newline()
		for i, child in ipairs(self._args) do
			if type(child) == 'table' then
				child:push_to(builder)
			else
				builder:push(child)
			end
			if i ~= #self._args then
				builder:newline()
			end
		end
		builder:unindent()
		builder:newline()
	else
		builder:push(self._child)
	end

	-- end tag
	builder:push('</')
	builder:push(self._tag)
	builder:push('>')
end

function Element:build(...)
	local builder = Builder.new(...)
	self:push_to(builder)
	return builder:build()
end


local H = {}
for _, tag in ipairs({ 'html', 'body', 'p', 'strong' }) do
	H[tag] = Element.partial(tag)
end

local comp = function(args)
	return H.p {
		H.strong ''
	}
end

local document = H.html {
	H.body {
		-- comp { id = 'hi', 'Hello world!' },
		-- comp { 'This is a component too!' },
		H.p { class = 'my-class', H.strong 'Lua HTML DSL' },
	},
}

print(document:build(true))
-- print(vim.inspect(H.html().with({ 'Hi' })))
