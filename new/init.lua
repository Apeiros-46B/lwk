local Builder = require('builder')
local dsl = require('dsl')

_ENV = dsl

local b = Builder.new()

local doc = ul {
	ForEach {
		items = { 'apples', 'bananas', 'cherries' },
		render = function(k, v)
			return li { id = k, v }
		end
	}
}

doc:build(b, {})
print(b:build())
