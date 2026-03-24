---@diagnostic disable: unused-local
local util = require('util')

local M = {}


local html_escapes = {
	['&'] = '&amp;',
	['<'] = '&lt;',
	['>'] = '&gt;',
	['"'] = '&quot;',
	["'"] = '&#39;'
}

function M.escape_html(str)
	local res, _ = str:gsub("[&<>\"']", html_escapes)
	return res
end

function M.capture_trace(obj, level)
	-- level 3 = user code calling the closure
	level = level or 3
	local info = debug.getinfo(level, 'Sl')
	if info then
		obj.debug_src = ('%s:%d'):format(info.short_src, info.currentline)
	else
		obj.debug_src = 'unknown location'
	end
	obj.debug_trace = debug.traceback('', level)
	return obj
end

function M.raise_error(node, msg)
	local fmt = [[
[DSL] %s
  Location: %s
  Context:  %s
	]]
	local err = fmt:format(
		msg,
		node.debug_src or 'unknown location',
		node.debug_trace or ''
	)
	error(err, 0)
end


-- parent is the current node that we're pushing into (target of modifiers).
-- components pass their parent instead of themselves so nested modifiers apply properly
function M.resolve_node(parent, node, ctx, lang)
	local ty = type(node)
	if not node then return {} end

	if ty == 'string' or ty == 'number' or ty == 'boolean' then
		local str = tostring(node)
		if lang == 'html' then
			return { M.escape_html(str) }
		else
			-- don't escape raw strings in CSS
			return { str }
		end
	elseif ty == 'function' then
		return M.resolve_node(parent, node(ctx), ctx, lang)
	elseif ty == 'table' then
		if lang and node.lang and lang ~= node.lang then
			M.raise_error(node, ('%s node used in %s context'):format(node.lang, lang))
		end

		if type(node.resolve) == 'function' then
			return node:resolve(parent, ctx, lang)
		else
			-- implicit fragment
			local resolved = {}
			for _, child in ipairs(node) do
				for _, res in ipairs(M.resolve_node(parent, child, ctx, lang)) do
					resolved[#resolved+1] = res
				end
			end
			return resolved
		end
	end
	return {}
end

function M.merge_attr(existing, new_value, mergeable)
	if not mergeable then
		return new_value
	end

	local merged = {}
	if existing ~= nil then
		if type(existing) == 'table' and not getmetatable(existing) then
			for _, v in ipairs(existing) do
				merged[#merged+1] = v
			end
		else
			merged[#merged+1] = existing
		end
	end

	if new_value ~= nil then
		if type(new_value) == 'table' and not getmetatable(new_value) then
			for _, v in ipairs(new_value) do
				merged[#merged+1] = v
			end
		else
			merged[#merged+1] = new_value
		end
	end

	return merged
end


-- base class for all nodes
local Node = {}
Node.__index = Node
M.Node = Node

function Node.new(subclass, template)
	local self = setmetatable(template or {}, subclass)
	M.capture_trace(self, 4) -- level 4 looks past the subclass ctor

	self.props = self.props or {}
	self.children = self.children or {}

	return self
end

function Node.format_key(k)
	return (k:gsub('_', '-')) -- default behaviour for HTML and CSS props
end

function Node:prop_is_mergeable(key)
	return false -- default is to overwrite properties when merging
end

function Node:build(builder, ctx, lang)
	M.raise_error(self, 'this node is not build()-able')
end

function Node:resolve(parent, ctx, lang)
	local resolved = {}
	for _, child in ipairs(self.children) do
		for _, res in ipairs(M.resolve_node(self, child, ctx, self.next_lang or lang)) do
			resolved[#resolved+1] = res
		end
	end

	local clone = util.shallow_copy(self)
	clone.props = util.shallow_copy(self.props)
	clone.children = resolved

	return { clone }
end

-- for currying. this metamethod must be copied by subclasses to function
function Node:__call(args)
	local clone = util.shallow_copy(self)
	M.capture_trace(clone, 3)

	clone.props = util.shallow_copy(self.props)
	clone.children = util.shallow_copy(self.children)

	if type(args) ~= 'table' or getmetatable(args) then args = { args } end

	for k, v in util.spairs(args) do
		local key = self.format_key(k)
		clone.props[key] = M.merge_attr(clone.props[key], v, self:prop_is_mergeable(key))
	end

	for _, child in ipairs(args) do
		clone.children[#clone.children+1] = child
	end

	return setmetatable(clone, getmetatable(self))
end


return M
