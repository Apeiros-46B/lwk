local util = require('util')
local core = require('dsl.core')

local M = {}

M.attr_seps = {
	['font-family'] = ', ',
	['transition'] = ', ',
	['transition-property'] = ', ',
	['animation'] = ', ',
	['animation-name'] = ', ',
	['box-shadow'] = ', ',
	['text-shadow'] = ', ',
	['background-image'] = ', ',
	['background'] = ', ',
	['src'] = ', ',
}

-- {{{ rules
local Fallback = {}
Fallback.__index = Fallback
Fallback.lang = 'css'

function Fallback.new(...)
	return setmetatable({ values = {...} }, Fallback)
end
M.Fallback = Fallback.new

local Rule = {}
Rule.__index = Rule
Rule.lang = 'css'

function Rule.new(selector)
	return function(args)
		local self = setmetatable({}, Rule)
		core.capture_trace(self, 3)

		self.selector = selector
		self.props = {}
		self.children = {}

		for k, v in util.spairs(args) do
			self.props[k:gsub('_', '-')] = v
		end

		for _, v in ipairs(args) do
			self.children[#self.children+1] = v
		end

		return self
	end
end
M.Rule = Rule.new

function Rule:resolve(_, ctx, _)
	local resolved = {}
	for _, child in ipairs(self.children) do
		for _, res in ipairs(core.resolve_node(self, child, ctx, 'css')) do
			resolved[#resolved+1] = res
		end
	end
	self.children = resolved
	return { self }
end

function Rule:build(builder, ctx, parent)
	local selector = self.selector
	if parent and parent.selector then
		if self.selector:find('&') then
			-- child selector directly references parent
			selector = self.selector:gsub('&', parent.selector)
		else
			-- standard descendant selector
			selector = parent.selector .. ' ' .. self.selector
		end
	end

	local has_props = next(self.props) ~= nil

	if has_props then
		builder:push(selector .. '{')
		builder:indent()
		builder:newline()

		-- deterministic key ordering
		local keys = {}
		for k in pairs(self.props) do
			keys[#keys+1] = k
		end
		table.sort(keys)

		for i, k in ipairs(keys) do
			local prop, _ = k:gsub('_', '-')
			local v = self.props[k]

			if getmetatable(v) == Fallback then
				-- fallback properties (color = Fallback('black', var 'bg'))
				for j, sub_val in ipairs(v) do
					builder:push(prop .. ':' .. tostring(sub_val) .. ';')

					-- don't add a newline if it's the last value of the last property
					if not (i == #keys and j == #v) then
						builder:newline()
					end
				end
			elseif type(v) == 'table' and not getmetatable(v) then
				-- auto-join literal arrays
				local sep = M.attr_seps[prop] or ' '

				-- we need to convert all values to string because keywords like
				-- `display = flex` are actually tables with __tostring, not strings
				local stringified = {}
				for j, sub_val in ipairs(v) do
					stringified[j] = tostring(sub_val)
				end

				builder:push(prop .. ':' .. table.concat(stringified, sep) .. ';')
				if i < #keys then
					builder:newline()
				end
			else
				builder:push(prop .. ':' .. tostring(v) .. ';')
				if i < #keys then
					builder:newline()
				end
			end
		end

		builder:unindent()
		builder:newline()
		builder:push('}')
	end

	if has_props and #self.children > 0 then
		builder:newline()
	end

	local original_selector = self.selector
	self.selector = selector

	for i, child in ipairs(self.children) do
		if type(child) == 'table' then
			-- only rules will be left in the AST
			child:build(builder, ctx, self)
		end
		if i < #self.children then
			builder:newline()
		end
	end

	self.selector = original_selector
end

local Import = {}
Import.__index = Import
Import.lang = 'css'

function Import.new(url)
	local self = setmetatable({ url = url }, Import)
	return core.capture_trace(self, 3)
end
M.Import = Import.new

function Import:resolve()
	return { self }
end

function Import:build(builder, _, _)
	local url_str = tostring(self.url)

	if not url_str:match('^url%(') and not url_str:match('^"') and not url_str:match("^'") then
		url_str = '"' .. url_str .. '"'
	end

	builder:push('@import ' .. url_str .. ';')
end

-- TODO: make pathing work properly with router
-- function M.InlineSvg(filepath)
-- 	local f = io.open(filepath, 'r')
-- 	if not f then
-- 		util.log('could not open "' .. filepath .. '"', 'warn')
-- 		return 'none'
-- 	end
--
-- 	local content = f:read('*a')
-- 	f:close()
--
-- 	content = content:gsub('[\n\r\t]+', ' ')
-- 	content = content:gsub('%%', '%%25')
-- 	content = content:gsub('#', '%%23')
-- 	content = content:gsub('<', '%%3C')
-- 	content = content:gsub('>', '%%3E')
-- 	content = content:gsub('"', '%%22')
-- 	content = content:gsub("'", '%%27')
--
-- 	return "url('data:image/svg+xml;utf8," .. content .. "')"
-- end

function M.Vars(selector)
	return function(args)
		local new_args = {}
		for k, v in util.spairs(args) do
			new_args['--' .. k:gsub('_', '-')] = v
		end
		return Rule.new(selector)(new_args)
	end
end

function M.Str(str)
	str = str or ''
	return '"' .. str .. '"'
end

function M.var(name)
	return 'var(--' .. name:gsub('_', '-') .. ')'
end

local css_units = {
	'px', 'cm', 'mm', 'Q', 'pc', 'pt',
	'em', 'ex', 'ch', 'rem', 'lh', 'rlh', 'cap', 'ic',
	'vw', 'vh', 'vmin', 'vmax', 'vi', 'vb',
	'svw', 'svh', 'svmin', 'svmax', 'svi', 'svb',
	'lvw', 'lvh', 'lvmin', 'lvmax', 'lvi', 'lvb',
	'dvw', 'dvh', 'dvmin', 'dvmax', 'dvi', 'dvb',
	'cqw', 'cqh', 'cqi', 'cqb', 'cqmin', 'cqmax',
	'deg', 'grad', 'rad', 'turn',
	's', 'ms',
	'dpi', 'dpcm', 'dppx', 'x',
	'fr'
}

for _, unit in ipairs(css_units) do
	M[unit] = function(val)
		return tostring(val) .. unit
	end
end

function M.pct(val)
	return tostring(val) .. '%'
end
function M.inch(val)
	return tostring(val) .. 'in'
end
-- }}}

-- {{{ queries
local Query = {}
Query.__index = Query
Query.lang = 'css'

-- media { min_width = 600 } { ... }
function Query:__call(args)
	local clone = util.shallow_copy(self)
	core.capture_trace(clone, 3)

	clone.props = util.shallow_copy(self.props)
	clone.children = util.shallow_copy(self.children)

	-- string should be mapped to the raw prop
	if type(args) == 'string' then
		clone.props.raw = args
		return clone
	elseif type(args) ~= 'table' then
		args = { args }
	end

	for k, v in util.spairs(args) do
		clone.props[k:gsub('_', '-')] = v
	end

	for _, child in ipairs(args) do
		clone.children[#clone.children+1] = child
	end

	return clone
end

function Query.new(name)
	return function(args)
		local self = setmetatable({}, Query)
		core.capture_trace(self, 3)

		self.name = name
		self.props = {}
		self.children = {}

		-- intercept a bare string and map it to the raw prop
		if type(args) == 'string' then
			self.props.raw = args
			args = {} -- clear args so the loops below safely do nothing
		elseif type(args) ~= 'table' then
			args = { args }
		end

		for k, v in util.spairs(args) do
			self.props[k:gsub('_', '-')] = v
		end

		for _, v in ipairs(args) do
			self.children[#self.children+1] = v
		end

		return self
	end
end
M.Query = Query.new

function Query:resolve(_, ctx, _)
	local resolved = {}
	for _, child in ipairs(self.children) do
		for _, res in ipairs(core.resolve_node(self, child, ctx, 'css')) do
			resolved[#resolved+1] = res
		end
	end
	self.children = resolved
	return { self }
end

function Query:build(builder, ctx, _)
	local conditions = {}
	local keys = {}

	-- deterministic key ordering
	for k in pairs(self.props) do
		keys[#keys+1] = k
	end
	table.sort(keys)

	for _, k in ipairs(keys) do
		local v = self.props[k]
		if k == 'raw' then
			conditions[#conditions+1] = tostring(v)
		elseif type(v) == 'boolean' then
			if v then conditions[#conditions+1] = k end
		else
			conditions[#conditions+1] = '(' .. k .. ':' .. tostring(v) .. ')'
		end
	end

	local query_str = table.concat(conditions, ' and ')

	if query_str ~= '' then
		builder:push(self.name .. ' ' .. query_str .. ' {')
	else
		builder:push(self.name .. ' {')
	end

	builder:indent()
	builder:newline()

	for i, child in ipairs(self.children) do
		if type(child) == 'table' then
			child:build(builder, ctx, self)
		end
		if i < #self.children then
			builder:newline()
		end
	end

	builder:unindent()
	builder:newline()
	builder:push('}')
end
-- }}}

return M
