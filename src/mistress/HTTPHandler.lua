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
function _M.HTTPHandler:init (fd, node_id, ...)
	self:super().init(...)

	self._fd = fd
	self._node_id = node_id
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
				local test_id = tonumber(path_parts[2])
				local start_time = tonumber(path_parts[3])

				self.logger:info("starting at " .. start_time)
				--...
				assert(not mistress.send(self._fd, utils.build_response('200 OK')))

				local cfg = assert(loadstring(body))()()
				cfg.opts.node_id = self._node_id
				local worker_num = #cfg.workers
				for i, phase in ipairs(cfg.opts.phases) do
					if type(phase.users_rate) == 'number' then
						if phase.users_rate < worker_num then
							self.logger:error("phase #"..i.." rate ("..phase.users_rate..") is less than workers number ("..worker_num..")")
							os.exit(1)
						end
						local divided_rate = phase.users_rate / worker_num
						if (phase.users_rate % worker_num) ~= 0 then
							self.logger:warn("phase #"..i.." rate ("..phase.users_rate..") is not not evenly divisible by workers number ("..worker_num..")")
						end

						phase.users_rate = divided_rate
					elseif type(phase.users_rate) == 'table' then
						assert(phase.users_rate[1] >= worker_num)
						assert(phase.users_rate[2] >= worker_num)
						assert((phase.users_rate[1] % worker_num) == 0)
						assert((phase.users_rate[2] % worker_num) == 0)

						phase.users_rate[1] = utils.round(phase.users_rate[1] / worker_num)
						phase.users_rate[2] = utils.round(phase.users_rate[2] / worker_num)
					else
						error("unexpected rate type: " .. type(phase.users_rate))
					end
				end


				self:sleep(start_time)


				init_launcher(cfg, self.logger, self.manager, test_id, self)
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
	self.logger:info("sending finish indication")
	assert(not mistress.send(self._fd, utils.build_response('200 OK', {keepalive = false, body = 'finished'})))
	C.close(self._fd)
	--TODO break handler loop?
end


return _M
