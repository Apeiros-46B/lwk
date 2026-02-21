local Builder = require('builder')
local Dsl = require('dsl')

_ENV = Dsl

local user_bio = '<script>alert("hi");</script>'

local my_div = div { class = 'red', id = 'my_div', ['@click'] = 'alert("Hi")' }
local your_div = my_div { class = 'bold', p 'Inherited' }

local doc = html {
	head {
		style {
			Rule '.bio' {
				font_weight = 600,
			},
		},
	},
	body {
		your_div {
			class = 'italic',
			id = 'the_div',
			p { class = 'bio', user_bio },
			If {
				cond = true,
				if_true = Append { 'class', 'true' },
				if_false = Set { 'id', 'false' },
			},
		},
		Raw '<svg><circle r="5"/></svg>',
	},
}

local b = Builder.new(true) -- pretty = true
local ctx = {}
Dsl.render(doc, b, ctx)
print(b:build())
