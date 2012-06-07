local _M = {};
local mistress = assert(require 'mistress.mistress')
local utils = assert(require 'mistress.utils')


_M.stypes = {
	CONCUR_USERS_NUM_MAX = 2,
	START_SESSION = 3,
	RESPONSE_TIME = 4,
	RESPONSE_STATUS = 5,
	REQUEST_SENT = 6,
	CONNECT_TIME = 7,
	CONCUR_USERS_NUM_MIN = 8,
	CONNECT_ERROR = 9,
	RESPONSE_ERROR = 10,
	CONCUR_CONNS_NUM_MIN = 11,
	CONCUR_CONNS_NUM_MAX = 12,
	FINISH_TEST = 13,
}


_M.Stat = utils.Object:inherit()

function _M.Stat:init ()
	self.stat_buf = {}
end

function _M.Stat:reset ()
	self.stat_buf = {}
end

function _M.Stat:add (type, value)
	table.insert(self.stat_buf, {
		time = mistress.now(),
		type = type,
		value = value,
	})
end



return _M
