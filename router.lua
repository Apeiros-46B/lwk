local util = require('util')
local Builder = require('builder')
local Dsl = require('dsl')

local Router = { handlers = {} }

-- create the parent directory of a given path
local function mkdir_parent(path)
	local parent = path:match('(.+)/[^/]+$')
	if parent then
		os.execute(string.format([[mkdir -p '%s']], parent))
	end
end

-- list all files in a dir recursively, sorted by increasing depth. if ctx_only then
-- only return _ctx.lua files, otherwise return all other files
local function find_files(dir, search_ctxs)
	local safe_dir = dir:gsub("'", [['\'']])
	local negate = search_ctxs and '' or '!'
	local stdout = io.popen(([[find '%s' -type f %s -name '_ctx.lua' -printf '%%d %%p\0' 2> /dev/null | sort -z | cut -zd' ' -f2-]]):format(safe_dir, negate))
	if not stdout then
		error('failed to find files in directory ' .. dir)
	end

	local content = stdout:read('*a')
	stdout:close()

	local files = {}

	-- iterate over null-delimited filenames
	for file in content:gmatch('(.-)%z') do
		files[#files+1] = file
	end

	return files
end

-- hardlink or copy a file to the output directory
local function passthrough(src, rel_path, out_dir)
	local dst = out_dir .. '/' .. rel_path
	mkdir_parent(dst)
	os.execute(("ln -f '%s' '%s' 2> /dev/null || cp '%s' '%s'"):format(src, dst, src, dst))
	util.log('passed ' .. rel_path, 'info', 'router')
end

-- build inherited directory context from _ctx.lua files
local function build_dir_contexts(in_dir)
	local prefix = in_dir:gsub('/+$', '') .. '/'
	local ctxs = {}

	-- find_files sorts by depth with shallowest first
	for _, src in ipairs(find_files(in_dir, true)) do
		local dir_path = src:sub(#prefix + 1):gsub('/?_ctx%.lua$', '')
		local result = dofile(src)

		if type(result) ~= 'table' then
			util.log(('%s should return a table'):format(src), 'error', 'router')
		else
			local parent_ctx = {}

			if dir_path ~= '' then
				local parent_dir = dir_path:match('^(.*)/[^/]+$')
				parent_ctx = ctxs[parent_dir] or ctxs[''] or {}
			end

			ctxs[dir_path] = util.deep_merge(parent_ctx, result)
		end
	end

	return ctxs
end


-- discover pages and build manifest/sitemap
local function phase1(opts)
	util.log('-> indexing files', 'info', 'router')

	local prefix = opts.in_dir:gsub('/+$', '') .. '/'
	local dir_ctxs = build_dir_contexts(opts.in_dir)
	local manifest = { pages = {}, groups = {} }

	for _, src in ipairs(find_files(opts.in_dir, false)) do
		local rel_path = src:sub(#prefix + 1)
		local filename = src:match('([^/]+)$') or src
		local base_name, target_ext, handler_ext = filename:match('^(.+)%.([^%.]+)%.([^%.]+)$')
		local handler = handler_ext
			and Router.handlers[handler_ext]
			and Router.handlers[handler_ext][target_ext]

		if not handler then
			passthrough(src, rel_path, opts.out_dir)
		else
			local dir = rel_path:match('^(.*)/[^/]+$')
			local dir_ctx = dir_ctxs[dir or ''] or {}

			local route_base = dir and (dir .. '/' .. base_name) or base_name
			local route = '/' .. route_base .. '.' .. target_ext

			local meta, ast, final_route = handler(src, rel_path, filename, dir_ctx, opts.out_dir)
			if ast then
				manifest.pages[#manifest.pages + 1] = {
					meta = util.deep_merge(dir_ctx, meta or {}),
					filename = filename,
					rel_path = rel_path,
					dst_rel_path = (final_route or route):gsub('^/', ''),
					_ctx = dir_ctx,
					_ast = ast,
				}
				util.log('registered ' .. rel_path, 'info', 'router')
			end
		end
	end

	return manifest
end

-- transform manifest using user middlewares
local function phase2(manifest, middlewares)
	if not middlewares then return end
	util.log('-> executing middleware', 'info', 'router')

	for _, f in ipairs(middlewares) do
		local ok, err = pcall(f, manifest)
		if not ok then util.log(('transformer error: %s'):format(err), 'error', 'router') end
	end
end

-- render pages to output files
local function phase3(manifest, opts)
	util.log('-> rendering files', 'info', 'router')

	local user_ctx = opts.ctx or {}
	local frozen_manifest = util.freeze(manifest)

	for _, page in ipairs(manifest.pages) do
		local toplevel_ctx = {
			page = page,
			dir = page._dir_ctx or {},
			manifest = frozen_manifest,
		};
		local ctx = util.deep_merge(toplevel_ctx, user_ctx)
		ctx.state = {}

		local builder = Builder.new()
		local lang = page.dst_rel_path:match('%.([^%.]+)$') or 'html'
		Dsl.render(page._ast, builder, ctx, lang)

		local dst = opts.out_dir .. '/' .. page.dst_rel_path
		mkdir_parent(dst)

		local f = io.open(dst, 'w')
		if f then
			f:write(builder:build())
			f:close()
			util.log('rendered ' .. page.dst_rel_path, 'info', 'router')
		else
			util.log(('cannot write "%s"'):format(dst), 'error', 'router')
		end
	end

	-- write global CSS bundle
	if #Dsl.global_styles > 0 then
		local ctx = util.deep_merge({ manifest = frozen_manifest }, user_ctx)
		ctx.state = {}

		local builder = Builder.new()
		Dsl.render_global_css(builder, ctx)

		local dst = opts.out_dir .. Dsl.global_css_path
		mkdir_parent(dst)

		local f = io.open(dst, 'w')
		if f then
			f:write(builder:build())
			f:close()
			util.log('rendered bundle.css', 'info', 'router')
		else
			util.log(('cannot write "%s"'):format(dst), 'error', 'router')
		end
	end
end


function Router.process(opts)
	Dsl.set_config({ in_dir = opts.in_dir, out_dir = opts.out_dir })
	os.execute(("mkdir -p '%s'"):format(opts.out_dir))

	if opts.components_dir then
		util.log('-> registering components', 'info', 'router')
		for _, src in ipairs(find_files(opts.components_dir, false)) do
			if src:match('%.([^%.]+)$') == 'lua' then
				Dsl.register_component(src)
			end
		end
	end

	local manifest = phase1(opts)
	phase2(manifest, opts.middlewares or {})
	phase3(manifest, opts)
end


-- register a handler for a src extension/dst extension pair
function Router.register_handler(src_ext, dst_ext, fn)
	local target = Router.handlers[src_ext]

	if not target then
		target = {}
		Router.handlers[src_ext] = target
	end

	target[dst_ext] = fn
end

-- evaluates lua page files with Dsl environment, returns unrendered component
local function lua_handler(src, _, _, _)
	local results = { util.eval_with_env(src, Dsl) }
	if #results == 0 then
		util.log(('file "%s" returned nil, skipping'):format(src), 'warn', 'router')
		return nil, nil, nil
	end
	if #results == 1 then
		return nil, results[1], nil
	end
	return results[1], results[2], nil
end
Router.register_handler('lua', 'html', lua_handler)
Router.register_handler('lua', 'css', lua_handler)


return Router
