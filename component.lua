local oo = require('oo')

local Component = {}

Component.push_to = oo.abstractmethod

-- Each(data, cb)
-- cb is a function that returns a component or nil
local Each = {}

function Each:_construct(data, mk_comp)
	self.components = {}
	local i = 1
	for _, v in ipairs(data) do
		local comp = mk_comp(v)
		if comp then
			self.components[i] = comp
			i = i + 1
		end
	end
end

function Each:push_to(builder)
	for _, comp in ipairs(self.components) do
		comp:push_to(builder)
	end
end

Component.Each = oo.extend(Component, Each)

return Component
