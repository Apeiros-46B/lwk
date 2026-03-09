local Builder = {}
Builder.__index = Builder

function Builder.new(pretty)
	local self = setmetatable({}, Builder)
	self.strs = {}
	self.pretty = pretty
	self.indents = 0
	return self
end

function Builder:push(str)
	if not str then return end
	self.strs[#self.strs+1] = str
end

local indent_cache = {}

function Builder:indent()
	if not self.pretty then return end
	self.indents = self.indents + 1
end

function Builder:unindent()
	if not self.pretty then return end
	self.indents = self.indents - 1
end

function Builder:newline()
	if not self.pretty then return end
	local str = indent_cache[self.indents]

	if not str then
		str = '\n' .. ('  '):rep(self.indents)
		indent_cache[self.indents] = str
	end

	self:push(str)
end

function Builder:build()
	return table.concat(self.strs)
end

return Builder
