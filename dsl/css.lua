local util = require('util')
local core = require('dsl.core')
local html = require('dsl.html')
local config = require('dsl.config')

local M = {}


M.global_styles = {}
M.global_css_path = '/bundle.css'
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


-- fallback properties, processed by Rule:build
-- "background_color = Fallback('black', 'var(--bg)')"
local Fallback = {}
Fallback.__index = Fallback
Fallback.lang = 'css'

function Fallback.new(...)
	return setmetatable({ values = {...} }, Fallback)
end
M.Fallback = Fallback.new


-- rules like "Rule '.btn' { color = '#0000FF' }"
local Rule = setmetatable({}, { __index = core.Node })
Rule.__index = Rule
Rule.__call = core.Node.__call

function Rule.new(selector)
	return function(args)
		local self = core.Node.new(Rule, {
			selector = selector,
			lang = 'css'
		})

		if type(args) ~= 'table' then args = { args } end

		for k, v in util.spairs(args) do
			self.props[self.format_key(k)] = v
		end

		for _, v in ipairs(args) do
			self.children[#self.children+1] = v
		end

		return self
	end
end
M.Rule = Rule.new

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
			local v = self.props[k]

			if getmetatable(v) == Fallback then
				-- fallback properties (color = Fallback('black', var 'bg'))
				for j, sub_val in ipairs(v) do
					builder:push(k .. ':' .. tostring(sub_val) .. ';')

					-- don't add a newline if it's the last value of the last property
					if not (i == #keys and j == #v) then
						builder:newline()
					end
				end
			elseif type(v) == 'table' and not getmetatable(v) then
				-- auto-join literal arrays
				local sep = M.attr_seps[k] or ' '

				-- we need to convert all values to string because keywords like
				-- `display = flex` are actually tables with __tostring, not strings
				local stringified = {}
				for j, sub_val in ipairs(v) do
					stringified[j] = tostring(sub_val)
				end

				builder:push(k .. ':' .. table.concat(stringified, sep) .. ';')
				if i < #keys then
					builder:newline()
				end
			else
				builder:push(k .. ':' .. tostring(v) .. ';')
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


-- queries like "Query '@media' { min_width = 600 } { ... }"
local Query = setmetatable({}, { __index = core.Node })
Query.__index = Query

-- intercept bare strings, fallback to Node currying
function Query:__call(args)
	if type(args) == 'string' then
		local clone = util.shallow_copy(self)
		core.capture_trace(clone, 3)
		clone.props = util.shallow_copy(self.props)
		clone.children = util.shallow_copy(self.children)
		clone.props.raw = args
		return setmetatable(clone, Query)
	end

	return core.Node.__call(self, args)
end

function Query.new(name)
	return function(args)
		local self = core.Node.new(Query, { name = name, lang = 'css' })

		-- intercept a bare string and map it to the raw prop
		if type(args) == 'string' then
			self.props.raw = args
			return self
		elseif type(args) ~= 'table' then
			args = { args }
		end

		for k, v in util.spairs(args) do
			self.props[self.format_key(k)] = v
		end

		for _, v in ipairs(args) do
			self.children[#self.children+1] = v
		end

		return self
	end
end
M.Query = Query.new

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


-- insert a quoted value
function M.Quoted(str) return '"' .. (str or '') .. '"' end


-- reference a variable
function M.var(name) return 'var(--' .. Rule.format_key(name) .. ')' end


-- define variables for a selector
function M.Vars(selector)
	return function(args)
		local new_args = {}
		for k, v in util.spairs(args) do
			-- underscore replacement is handled by Rule
			new_args['--' .. k] = v
		end
		return Rule.new(selector)(new_args)
	end
end


-- import a URL
local Import = setmetatable({}, { __index = core.Node })
Import.__index = Import
Import.__call = core.Node.__call

function Import.new(url)
	return core.Node.new(Import, {
		url = url,
		lang = 'css'
	})
end
M.Import = Import.new

function Import:build(builder, _, _)
	local url_str = tostring(self.url)

	if not url_str:match('^url%(') and not url_str:match([=[^["']]=]) then
		url_str = '"' .. url_str .. '"'
	end

	builder:push('@import ' .. url_str .. ';')
end


-- unit helpers e.g. "rem(1.5)"
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
	M[unit] = function(val) return tostring(val) .. unit end
end
function M.pct(val) return tostring(val) .. '%' end
function M.inch(val) return tostring(val) .. 'in' end


function M.InlineSvg(filepath)
	local path

	if filepath:sub(1, 1) == '/' then
		-- absolute path (from project source root)
		local clean_path = filepath:sub(2)
		local root = config.in_dir:gsub('/$', '')
		path = root .. '/' .. clean_path
	else
		-- path relative to the calling file
		-- InlineSvg "icon.svg" in src/components/Header.lua
		-- should read from src/components/icon.svg
		local info = debug.getinfo(2, "S")
		local caller_source = info.source
		if caller_source:sub(1, 1) == '@' then
			caller_source = caller_source:sub(2)
		end
		local caller_dir = caller_source:match("^(.*)/") or "."
		path = caller_dir .. '/' .. filepath
	end

	local f = io.open(path, 'r')
	if not f then
		util.log('could not open "' .. path .. '"', 'warn', 'InlineSvg')
		return 'none'
	end

	local content = f:read('*a')
	f:close()

	content = content:gsub('[\n\r\t]+', ' ')
	content = content:gsub('%%', '%%25')
	content = content:gsub('#', '%%23')
	content = content:gsub('<', '%%3C')
	content = content:gsub('>', '%%3E')
	content = content:gsub('"', '%%22')
	content = content:gsub("'", '%%27')

	return "url('data:image/svg+xml;utf8," .. content .. "')"
end


-- stable sort to preserve within-group ordering of rules
local global_styles_insert_counter = 0

-- registers colocated CSS which is bundled into one file
function M.GlobalStyles(priority, args)
	if type(priority) ~= 'number' then
		args = priority
		priority = 50
	end

	if type(args) ~= 'table' then
		args = { args }
	end

	for _, node in ipairs(args) do
		global_styles_insert_counter = global_styles_insert_counter + 1
		M.global_styles[#M.global_styles+1] = {
			id = global_styles_insert_counter,
			priority = priority,
			node = node,
		}
	end

	return nil
end

function M.render_global_css(builder, ctx)
	table.sort(M.global_styles, function(a, b)
		if a.priority ~= b.priority then
			return a.priority < b.priority
		else
			return a.id < b.id
		end
	end)

	local nodes = {}
	for _, entry in ipairs(M.global_styles) do
		nodes[#nodes+1] = entry.node
	end

	local resolved = core.resolve_node(nil, nodes, ctx, 'css')
	for _, node in ipairs(resolved) do
		if type(node) == 'table' then
			node:build(builder, ctx, 'css')
		else
			builder:push(node)
		end
	end
end

M.LinkGlobalStyles = html.Element.new('link') {
	rel = 'stylesheet',
	href = M.global_css_path,
}


return M
