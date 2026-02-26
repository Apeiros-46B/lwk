-- TODO: per-folder context.lua files which allow adding to the context for only the files in that folder and its subfolders (recursive inheritance)
local util = require('util')
local Builder = require('builder')
local Dsl = require('dsl')

local Router = {
	handlers = {},
	routes = {}
}

function Router.register_handler(name, handler)
	Router.handlers[name] = handler
end

function Router.register_route(handler_name, exts)
	if type(exts) ~= 'table' then
		exts = { exts }
	end
	for _, ext in ipairs(exts) do
		Router.routes[ext] = handler_name
	end
end

local function mkdir_parent(path)
	local parent = path:match('(.+)/[^/]+$')
	if parent then
		os.execute(string.format([[mkdir -p '%s']], parent))
	end
end

Router.register_handler('passthrough', function(_, src, dst_dir, rel_path, _)
	local dst = dst_dir .. '/' .. rel_path
	mkdir_parent(dst)

	local cmd = string.format(
		[[ln -f '%s' '%s' 2>/dev/null || cp '%s' '%s']],
		src, dst,
		src, dst
	)
	os.execute(cmd)

	util.log('passed through ' .. rel_path, 'info', 'router')
end)

Router.register_handler('build', function(ctx, src, dst_dir, rel_path, filename)
	-- extract target extension from filename (e.g., .css.lua, .xml.lua)
	local base_path, target_ext = rel_path:match('^(.-)%.([^%.]+)%.lua$')

	local out_lang
	local dst_rel_path

	if target_ext then
		out_lang = target_ext
		dst_rel_path = base_path .. '.' .. target_ext
	else
		-- if no double extension is provided, assume it's HTML
		out_lang = 'html'
		dst_rel_path = rel_path:gsub('%.lua$', '.html')
	end

	local dst = dst_dir .. '/' .. dst_rel_path
	mkdir_parent(dst)

	-- DOCUMENT: reserved ctx names
	local local_ctx = setmetatable({
		rel_path = rel_path,
		dst_rel_path = dst_rel_path,
		filename = filename,
		manifest = ctx.manifest or {},
	}, { __index = ctx })

	local page = util.eval_with_env(src, Dsl)
	if not page then
		util.log(('file "%s" returned nil, skipping build'):format(src), 'warn', 'router')
		return
	end

	local builder = Builder.new()
	Dsl.render(page, builder, local_ctx, out_lang)

	local f = io.open(dst, 'w')
	if not f then
		util.log(('could not open file "%s" for writing'):format(dst), 'error', 'router')
		return
	end
	f:write(builder:build())
	f:close()

	util.log('built ' .. dst_rel_path, 'info', 'router')
end)

Router.register_route('build', 'lua')
Router.register_route('passthrough', {
	'png',
	'jpg',
	'jpeg',
	'gif',
	'svg',
	'mp4',
	'webm',
	'html',
	'css',
	'js',
	'ico',
	'woff2',
})

--- use `find -print0` to find files in a dir
function Router.scan_dir(dir)
	-- escape single quotes
	local safe_dir = dir:gsub([[']], [['\'']])
	local cmd = ([[find '%s' -type f -print0 2> /dev/null]]):format(safe_dir)

	local handle = io.popen(cmd)
	if not handle then
		error('failed to execute `find` for directory ' .. dir)
	end

	local content = handle:read('*a')
	handle:close()

	local files = {}

	-- iterate over null-delimited filenames
	for file in content:gmatch('(.-)%z') do
		files[#files+1] = file
	end

	return files
end

function Router.process(opts)
	-- component instantiation should not affect other components
	local ctx = util.freeze(opts.ctx)
	local in_dir = opts.input_dir
	local out_dir = opts.output_dir
	local comp_dir = opts.components_dir

	Dsl.set_config({
		in_dir = in_dir,
		out_dir = out_dir,
	})

	os.execute(string.format([[mkdir -p '%s']], out_dir))

	if comp_dir then
		local comp_files = Router.scan_dir(comp_dir)
		local comp_prefix = comp_dir:gsub('/+$', '') .. '/'

		for _, src in ipairs(comp_files) do
			local rel_path = src
			if src:sub(1, #comp_prefix) == comp_prefix then
				rel_path = src:sub(#comp_prefix + 1)
			end

			local filename = src:match('([^/]+)$') or src
			local ext = filename:match('%.([^%.]+)$')

			if ext == 'lua' then
				Dsl.register_component(src)
			elseif ext then
				-- treat non-lua files in component dir as assets
				local dst_rel_path = 'components/' .. rel_path
				local handler = Router.handlers['passthrough']
				if handler then
					handler(opts.ctx, src, out_dir, dst_rel_path, filename)
				end
			end
		end
	end

	local in_files = Router.scan_dir(in_dir)
	local in_prefix = in_dir:gsub('/+$', '') .. '/'

	local manifest = {}
	for _, src in ipairs(in_files) do
		local path = src:sub(#in_prefix + 1)
		manifest[#manifest+1] = {
			src = src,
			rel_path = path,
			-- TODO: fix non-html files
			url = '/' .. path:gsub('%.lua$', '.html'):gsub('%.[^%.]+%.html$', '.%1'),
		}
	end

	local global_ctx = util.shallow_copy(opts.ctx)
	global_ctx.manifest = manifest

	-- page instantiations should not affect each other
	ctx = util.freeze(global_ctx)

	for _, src in ipairs(in_files) do
		local rel_path = src
		if src:sub(1, #in_prefix) == in_prefix then
			rel_path = src:sub(#in_prefix + 1)
		end

		local filename = src:match('([^/]+)$') or src
		local ext = filename:match('%.([^%.]+)$')

		if ext then
			local handler_name = Router.routes[ext:lower()] or 'passthrough'
			local handler = Router.handlers[handler_name]

			if handler then
				handler(ctx, src, out_dir, rel_path, filename)
			else
				util.log('no handler defined for ' .. handler_name, 'warn', 'router')
			end
		else
			util.log('skipping extensionless file ' .. src, 'info', 'router')
		end
	end

	if #Dsl.global_styles > 0 then
		local css_builder = Builder.new()
		Dsl.render_global_css(css_builder, ctx)

		local dst = out_dir .. Dsl.global_css_path
		local f = io.open(dst, 'w')
		if not f then
			util.log(
				('could not open file "%s" for writing'):format(dst),
				'error',
				'router'
			)
			return
		end
		f:write(css_builder:build())
		f:close()
		util.log('built global css', 'info', 'router')
	end
end

return Router
