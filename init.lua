local Builder = require('builder')
local Dsl = require('dsl')

_ENV = Dsl

local doc = If(function(ctx) return ctx.a == 2 end) {
	'True'
} {
	'False'
}

local b = Builder.new(true) -- pretty = true
local ctx = { a = 2 }
Dsl.render(doc, b, ctx)
print(b:build())
