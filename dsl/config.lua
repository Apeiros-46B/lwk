local util = require('util')

return setmetatable({}, {
	__index = function (_, k)
		util.log('key ' .. k .. ' was not set in config', 'warn', 'dsl')
		return nil
	end
})
