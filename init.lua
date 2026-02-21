local util = require('util')
local Builder = require('builder')
local dsl = require('dsl')

util.wrap_env(dsl, function()

local doc = html {
	head {
		title "Test Page",

		style {
			rule 'body' {
				margin = 0,
				background_color = '#f4f4f4',
			},

			rule '.btn' {
				padding = '10px 20px',
				border_radius = '4px',

				rule '&:hover' {
					background_color = 'darkgray',
				},
				rule 'span' {
					font_weight = 'bold'
				},

				If {
					cond = function(ctx) return ctx.is_dark_mode end,
					if_true = rule '&.dark' {
						color = 'white',
						background_color = 'black'
					}
				}
			}
		}
	},
	body {
		div {
			class = "container",

			h1 { "Welcome" },

			If {
				cond = true,
				if_true = p { Set { 'class', 'text-green' }, "Condition passed!" }
			},

			ul {
				ForEach {
					items = { "Apple", "Banana", "Cherry" },
					render = function(i, item)
						return li { id = i, item }
					end
				}
			}
		}
	}
}

local b = Builder.new(true) -- pretty = true
local ctx = { is_dark_mode = true }
dsl.render(doc, b, ctx)
print(b:build())

end)
