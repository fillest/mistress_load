local utils = assert(require 'mistress.utils')
local session = assert(require 'mistress.session')
local _M = utils.module()


_M.Acceptor = session.Session:inherit()
function _M.Acceptor:init (fd, handler_class, node_id, test_id, ...)
	self:super().init(...)

	self._listen_fd = fd
	self._handler_class = handler_class
	self._node_id = node_id
	self._test_id = test_id
end

function _M.Acceptor:run ()
	repeat
		local fds = self:accept(self._listen_fd)

		for _, fd in ipairs(fds) do
			local handler = self.manager:register(function (id)
				return self._handler_class:new(fd, self._node_id, self._test_id, id, self.logger, self.stat, self.manager)
			end)

			self.manager:plan_resume("", handler.id)
		end
	until false
end


return _M
