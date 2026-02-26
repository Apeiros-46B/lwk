local util = require('util')
local core = require('dsl.core')
local html = require('dsl.html')
local css = require('dsl.css')

local M = {}


-- components define reusable subtrees which are inlined when instantiated
local Component = setmetatable({}, { __index = core.Node })
Component.__index = Component
Component.__call = core.Node.__call
M.Component = Component

function Component.new(name, render_fn, lang)
	return function(args)
		return core.Node.new(Component, {
			tag = name,
			lang = lang,
			render_fn = render_fn,
			props = args or {}
		})
	end
end

-- components preserve exact key names for custom arguments
function Component.format_key(k)
	return k
end

function Component:prop_is_mergeable(key)
	local mod = self.lang == 'css' and css or html
	return mod.attr_seps[key] ~= nil
end

function Component:resolve(parent, ctx, lang)
	local inner = self:render_fn(parent, self.props, ctx)
	-- components are inlined, and modifiers apply to their parents
	return core.resolve_node(parent, inner, ctx, self.lang or lang)
end


-- modifiers are behaviours which apply to the parent node in which they reside
-- this is useful in conjunction with builtin control flow:
-- "If(navbar_page_is_active) { Set('aria-current', 'page') }"
local Modifier = setmetatable({}, { __index = core.Node })
Modifier.__index = Modifier
M.Modifier = Modifier

-- modifiers use varargs, not a single prop/child table, so we override the currying
function Modifier:__call(...)
	local clone = util.shallow_copy(self)
	core.capture_trace(clone, 3)

	clone.args = util.shallow_copy(self.args)

	for _, v in ipairs({ ... }) do
		clone.args[#clone.args+1] = v
	end

	return setmetatable(clone, Modifier)
end

function Modifier.new(name, apply_fn, lang)
	return function(...)
		local self = core.Node.new(Modifier, {
			name = name,
			lang = lang,
			apply_fn = apply_fn,
			args = { ... },
		})

		-- unwrap if it's a single table arg
		if #self.args == 1 and type(self.args[1]) == 'table' and not getmetatable(self.args[1]) then
			self.args = self.args[1]
		end

		return self
	end
end

function Modifier:resolve(parent, ctx, _)
	if parent then
		self:apply_fn(parent, ctx, util.unpack(self.args))
	else
		core.raise_error(self, 'modifier used without a valid parent node')
	end

	-- modifiers are erased from AST. we cannot return nil here, return empty fragment
	return {}
end


return M
