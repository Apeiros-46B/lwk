local util = require('util')
local core = require('dsl.core')
local ext = require('dsl.ext')
local html= require('dsl.html')

local M = {}


-- insert raw strings into tree
local Raw = setmetatable({}, { __index = core.Node })
Raw.__index = Raw

function Raw.new(text)
	return core.Node.new(Raw, { text = tostring(text) })
end
M.Raw = Raw.new

function Raw:build(builder, _, _)
	-- directly push unescaped string
	builder:push(self.text)
end


-- select subtree based on condtiion: If(cond) { 'if_true' } { 'if_false' }
local If = setmetatable({}, { __index = core.Node })
If.__index = If

function If:__call(args)
	local clone = util.shallow_copy(self)

	if type(args) ~= 'table' then args = { args } end

	-- true branch comes first
	if not clone.true_branch then
		clone.true_branch = args
	elseif not clone.false_branch then
		clone.false_branch = args
	else
		core.raise_error(self, 'If already has both true and false branches')
	end

	return setmetatable(clone, If)
end

function If.new(cond)
	return core.Node.new(If, { cond = cond })
end
M.If = If.new

function If:resolve(parent, ctx, lang)
	local eval_cond
	if type(self.cond) == 'function' then
		eval_cond = self.cond(ctx)
	else
		eval_cond = self.cond
	end

	local branch = eval_cond and self.true_branch or self.false_branch
	if not branch then return {} end

	return core.resolve_node(parent, branch, ctx, lang)
end


-- generate subtrees based on table: For(items) { fn }
local For = setmetatable({}, { __index = core.Node })
For.__index = For

function For:__call(args)
	local clone = util.shallow_copy(self)

	if not clone.render_fn then
		clone.render_fn = type(args) == 'table' and args[1] or args
	else
		core.raise_error(self, 'For can only have one block')
	end

	return setmetatable(clone, For)
end

function For.new(items)
	return core.Node.new(For, { items = items })
end
M.For = For.new

function For:resolve(parent, ctx, lang)
	local iter, state, var
	if type(self.items) == 'function' then
		iter, state, var = self.items(ctx)
	elseif type(self.items) == 'table' and not getmetatable(self.items) then
		iter, state, var = ipairs(self.items)
	else
		return {}
	end

	local fragment = {}
	for k, v in iter, state, var do
		if self.render_fn then
			fragment[#fragment+1] = self.render_fn(v, k, ctx)
		else
			core.raise_error(self, 'attempt to render uninitialized For')
		end
	end

	return core.resolve_node(parent, fragment, ctx, lang)
end


-- select subtree based on value:
-- Switch(value) { a = 'if_is_a', b = 'if_is_b', c = 'if_is_c' } { 'default' }
local Switch = setmetatable({}, { __index = core.Node })
Switch.__index = Switch

function Switch:__call(args)
	local clone = util.shallow_copy(self)

	-- cases table comes first, then default comes second
	if not clone.cases then
		if type(args) ~= 'table' then
			core.raise_error(self, 'Switch expects a table of cases')
		end
		clone.cases = args
	elseif not clone.default then
		if type(args) ~= 'table' then
			args = { args }
		end
		clone.default = args
	else
		core.raise_error(self, 'Switch already has both cases and a default branch')
	end

	return setmetatable(clone, Switch)
end

function Switch.new(value)
	return core.Node.new(Switch, { value = value })
end
M.Switch = Switch.new

function Switch:resolve(parent, ctx, lang)
	if not self.cases then return {} end

	local val = type(self.value) == 'function' and self.value(ctx) or self.value
	local branch = val ~= nil and self.cases[val] or nil

	if branch ~= nil then
		return core.resolve_node(parent, branch, ctx, lang)
	elseif self.default ~= nil then
		return core.resolve_node(parent, self.default, ctx, lang)
	end

	-- no match and no default block, remove ourselves from the tree
	return {}
end


-- override an attribute in the parent: Set('aria-current', 'page')
M.Set = ext.Modifier.new('Set', function(_, node, _, k, v)
	if node.props then
		node.props[node.format_key(k)] = v
	end
end)


-- append to an attribute in the parent: Append('class', 'highlighted')
M.Append = ext.Modifier.new('Append', function(_, node, _, k, ...)
	if not node.props then return end

	local values = {}

	for _, val in ipairs({...}) do
		if type(val) == 'table' and not getmetatable(val) then
			for _, v in ipairs(val) do
				values[#values+1] = v
			end
		else
			values[#values+1] = val
		end
	end

	if #values == 0 then return end

	local key, _ = node.format_key(k)
	local current = node.props[key]

	if current == nil then
		node.props[key] = values
	elseif type(current) == 'table' and not getmetatable(current) then
		-- append to existing array
		for _, v in ipairs(values) do
			current[#current+1] = v
		end
	else
		-- promote existing string to an array
		node.props[key] = { current }
		for _, v in ipairs(values) do
			node.props[key][#node.props[key]+1] = v
		end
	end
end)


-- document wrapper
M.Document = ext.Component.new('Document', function(_, _, args, _)
	return { M.Raw('<!DOCTYPE html>\n'), html.Element.new('html')(args) }
end)


-- conditionally apply classes
M.Classes = ext.Component.new('Classes', function(self, _, arg, ctx)
	local map

	if type(arg) == 'function' then
		map = arg(ctx)
	elseif type(arg) == 'table' and not getmetatable(arg) then
		map = arg
	else
		core.raise_error(self, 'argument to Classes should be table or fn(ctx) -> table')
	end

	local active = {}

	for class, cond in pairs(map) do
		local is_active
		if type(cond) == 'function' then
			is_active = cond(ctx)
		else
			is_active = cond
		end

		if is_active then
			active[#active+1] = class
		end
	end

	if #active > 0 then
		return M.Append('class', active)
	end
end, 'html')


-- provide temporary context to children
M.Provide = ext.Component.new('Provide', function(_, parent, args, ctx)
	local provided_data = {}
	local children = {}

	for k, v in pairs(args) do
		if type(k) == 'string' then
			provided_data[k] = v
		elseif type(k) == 'number' then
			children[k] = v
		end
	end

	local inner_ctx = setmetatable(provided_data, { __index = ctx })

	local resolved = {}
	for _, child in ipairs(children) do
		local lang = type(child) == 'table' and child.lang or nil
		for _, res in ipairs(core.resolve_node(parent, child, inner_ctx, lang)) do
			resolved[#resolved+1] = res
		end
	end

	return resolved
end)


return M
