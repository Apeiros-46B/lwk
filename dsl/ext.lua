local util = require('util')
local core = require('dsl.core')
local html = require('dsl.html')
local css = require('dsl.css')

local M = {}

local Component = {}
Component.__index = Component
M.Component = Component

-- currying
function Component:__call(args)
	local clone = util.shallow_copy(self)
	core.capture_trace(clone, 3)

	if type(self.args) ~= 'table' then
		clone.args = { self.args }
	else
		clone.args = util.shallow_copy(self.args)
	end

	if type(args) ~= 'table' then
		args = { args }
	end

	local attr_seps = self.lang == 'css' and css.attr_seps or html.attr_seps
	for k, v in util.spairs(args) do
		clone.args[k] = core.merge_attr(clone.args[k], v, attr_seps[k] ~= nil)
	end

	for _, child in ipairs(args) do
		clone.args[#clone.args+1] = child
	end

	return clone
end

function Component.new(name, render_fn, lang)
	return function(args)
		local self = setmetatable({}, Component)
		core.capture_trace(self, 3)

		self.tag = name
		self.lang = lang -- nil is fine
		self.args = args or {}
		self.render_fn = render_fn

		return self
	end
end

function Component:resolve(parent, ctx, lang)
	local inner = self:render_fn(parent, self.args, ctx)
	-- components are inlined, and modifiers apply to their parents
	return core.resolve_node(parent, inner, ctx, self.lang or lang)
end


local Modifier = {}
Modifier.__index = Modifier
M.Modifier = Modifier

-- currying
function Modifier:__call(...)
	local clone = util.shallow_copy(self)
	core.capture_trace(clone, 3)

	clone.args = util.shallow_copy(self.args)

	for _, v in ipairs({ ... }) do
		clone.args[#clone.args + 1] = v
	end

	return clone
end

function Modifier.new(name, apply_fn, lang)
	return function(...)
		local self = setmetatable({}, Modifier)
		core.capture_trace(self, 3)

		self.name = name
		self.lang = lang -- nil is fine
		self.apply_fn = apply_fn

		self.args = { ... }

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
