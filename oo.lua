local oo = {}

oo.Obj = {}

function oo.extend(super, sub)
	-- TODO this is wrong and only allows instantiating one instance
	return setmetatable(sub, {
		__index = super,
		__call = sub._construct,
	})
end

function oo.abstractmethod()
	error('abstract method not implemented')
end

return oo
