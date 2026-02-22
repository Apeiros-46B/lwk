return function(name)
	local new = (';./%s/?.lua;./%s/?/init.lua'):format(name, name)
	package.path = package.path .. new
end
