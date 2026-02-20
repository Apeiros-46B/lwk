local Registry = {}

local items = {}

function Registry.get(k)
	return items[k]
end

function Registry.register(k, v)
	items[k] = v
end

return Registry
