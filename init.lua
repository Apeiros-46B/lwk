local Builder = require('builder')
local Dsl = require('dsl')

_ENV = Dsl

local user_bio = '<script>alert("hi");</script>'

local doc = html {
	head {
		style {
			Rule '.bio' {
				font_weight = 600,
			},
		},
	},
	body {
		p { class = 'bio', user_bio },
		Raw '<svg><circle r="5"/></svg>',
	},
}

local b = Builder.new(true) -- pretty = true
local ctx = {}
Dsl.render(doc, b, ctx)
print(b:build())
