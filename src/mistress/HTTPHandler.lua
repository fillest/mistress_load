local utils = assert(require 'mistress.utils')
local session = assert(require 'mistress.session')
local C = assert(require('ffi')).C
local mistress = assert(require('mistress.mistress'))
local stat = assert(require('mistress.stat'))
local launcher = assert(require('mistress.launcher'))
local socket_url = require("socket.url")
local inspect = assert(require 'mistress.inspect')
local _M = utils.module()


local function init_launcher (test_config, logger, manager, test_id, http_handler)
	local launcher = manager:register(function (id)
		return launcher.Launcher:new(test_config.opts, test_id, http_handler, id, logger, stat.Stat:new(), manager)
	end)
	manager:plan_resume("", launcher.id)

	mistress.register_shut_down(function () launcher:shut_down() end)
end


_M.HTTPHandler = session.Session:inherit()
function _M.HTTPHandler:init (fd, node_id, test_id, ...)
	self:super().init(...)

	self._fd = fd
	self._node_id = node_id
	self._test_id = test_id
end

function _M.HTTPHandler:run ()
	repeat
		local headers_tokens, body, _passed, _, is_keepalive, url = self:receive(self._fd, true, 0, 1)
		if headers_tokens then
			local path = socket_url.parse(url).path  --http://w3.impa.br/~diego/software/luasocket/url.html
			--~ print(inspect({path, headers_tokens, is_keepalive}))
			local path_parts = socket_url.parse_path(path)
			--~ print(inspect(path_parts))
			if path_parts[1] == 'start' then
				self.logger:info("starting at " .. tonumber(path_parts[2]))
				--...
				assert(not mistress.send(self._fd, utils.build_response('200 OK', {keepalive = false})))

				local cfg = assert(loadstring(body))()()
				--print(inspect(cfg))
				cfg.opts.node_id = self._node_id
				for i, phase in ipairs(cfg.opts.phases) do
					phase.users_rate = phase.users_rate / #cfg.workers
				end
				--print(inspect(cfg))


				self:sleep(tonumber(path_parts[2]))


				init_launcher(cfg, self.logger, self.manager, self._test_id, self)
				self.logger:info("starting launcher")
			else
				assert(not mistress.send(self._fd, utils.build_response('404 Not Found', {keepalive = false})))
				self.logger:warn("404: " .. path)
			end

			-- just keep receiving to keep socket opened
		else
			local err_msg = body
			if err_msg == 'conn closed' then
				print "??conn closed"
				os.exit(0)
				break
			else
				print("??recv error:", err_msg)
				os.exit(1)
			end
		end
	until false

	C.close(self._fd)
end

function _M.HTTPHandler:finish_test ()
	--
end


return _M
