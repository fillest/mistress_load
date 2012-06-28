local utils = assert(require 'mistress.utils')
local socket = assert(require 'socket')
local json = assert(require 'json')  -- https://github.com/harningt/luajson
local mistress = assert(require 'mistress.mistress')
local session = assert(require 'mistress.session')
local inspect = assert(require 'mistress.inspect')
local uthread = assert(require 'mistress.uthread')
local stat = assert(require 'mistress.stat')
local ffi = assert(require("ffi"))
	local C = ffi.C
local _M = utils.module()


_M.Launcher = session.Session:inherit()
function _M.Launcher:init (opts, test_id, http_handler, ...)
	self:super().init(...)

	self._opts = utils.merge_defaults({
		total_duration_limit = 0,
		phases = {users_rate = 1, duration = 1},
		sessions = {},
		no_stat_server = false,
		stat_server_host = 'localhost',
		stat_server_port = 7777,
		node_id = false,
	}, opts)

	assert(self._opts.node_id)

	assert(utils.hash_len(self._opts.sessions) > 0)
	self.sessions = self._opts.sessions

	assert(#self._opts.phases > 0)
	self.phases = self._opts.phases

	self._no_stat_server = self._opts.no_stat_server
	self.total_duration_limit = self._opts.total_duration_limit


	self._concur_users_num = 0
	self._concur_users_num_max = 0
	self._concur_users_num_min = 0

	self._concur_conns_num = 0
	self._concur_conns_num_max = 0
	self._concur_conns_num_min = 0


	self.stat_server = {
		conn = nil,
		host = self._opts.stat_server_host,
		port = self._opts.stat_server_port,
	}
	self.test_id = test_id

	self._gonna_shut_down = false

	self._http_handler = http_handler
end

--copypasted to worker manager
function _M.Launcher:connect_to_stat_server ()
	if not self._no_stat_server then
		self.logger:info("connecting to stat server " .. self.stat_server.host .. ":" .. self.stat_server.port)

		local conn, err = self:connect(socket.dns.toip(self.stat_server.host) or self.stat_server.host, self.stat_server.port)
		if not (conn == 0) then
			self.stat_server.conn = conn
		else
			error("failed to connect to stat server, err: " .. ((err == 111) and 'ECONNREFUSED' or err))
		end
	end
end



function _M.Launcher:send_stats (cur_step)
	if not self._no_stat_server then
		--~ print(inspect(self.stat.stat_buf))
		local out_data = json.encode.encode({
			node = self._opts.node_id,
			step = cur_step,
			data = self.stat.stat_buf,
		})
		--print("before", #out_data)
		out_data = mistress.zip(out_data)
		--print("after", #out_data)
		assert(not mistress.send(self.stat_server.conn.fd, utils.build_req('/add_stats/' .. self.test_id, {method = 'POST', host = self.stat_server.host, body = out_data})))
	end
end

function _M.Launcher:finish_test (cur_step)
	if not self._no_stat_server then
		self.stat:add(stat.stypes.FINISH_TEST, 1)
		self:send_stats(cur_step)

		self._http_handler:finish_test()

		--assert(not mistress.send(self.stat_server.conn.fd, utils.build_req('/finish_test/' .. self.test_id, {host = self.stat_server.host})))
		--local _headers, _, _, status_code, _ = self:receive(self.stat_server.conn.fd)
		--if not _headers then
			--error("failed to receive from stat server")
		--end
		--assert(status_code == 200)
--
		--self.stat_server.conn:close()
	end
end


local function repr_rate (rate)
	local t = type(rate)
	if t == 'number' then
		return tostring(rate)
	elseif t == 'table' then
		return "{" .. rate[1] .. ", " .. rate[2] .. "}"
	else
		error("unexpected rate type: " .. t)
	end
end

function _M.Launcher:run ()
	self.logger:info("running session launcher")

	self:connect_to_stat_server()
	--self:register_test()

	self.logger:info("starting test...")
	local test_started = mistress.now()
	local cur_step = 1
	local final_phase = {users_rate = 0, duration = 0}
	local phases = utils.join_arrays(self.phases, {final_phase})
	for i, phase in ipairs(phases) do
		local is_finish_phase = (i == #phases) or self._gonna_shut_down
		local rate = phase.users_rate

		if is_finish_phase then
			self.logger:info("starting finishing phase")
		else
			self.logger:info("starting phase #" .. i .. " with rate " .. repr_rate(rate) .. " and duration " .. phase.duration)
		end

		local calc_rate
		local start_step = cur_step
		if type(rate) == 'number' then
			calc_rate = function (_cur_step) return rate end
		elseif type(rate) == 'table' then
			calc_rate = function (cur_step)
				local abs_step = cur_step - start_step
				local rate_from, rate_to = unpack(rate)
				if rate_to > rate_from then
					return utils.round(rate_from + ((rate_to - rate_from) / phase.duration) * abs_step)
				else
					return utils.round(rate_from - ((rate_from - rate_to) / phase.duration) * abs_step)
				end
			end
		else
			error("unexpected rate type: " .. type(rate))
		end
		local phase_started = mistress.now()
		while ((mistress.now() - phase_started) <= phase.duration) or is_finish_phase do
			--~ self.logger:debug("tick")
			--~ print(utils.hash_len(self.manager.sessions), self._concur_users_num)
			--~ self.logger:debug(os.date("(%T)", mistress.now()) .. " tick")

			self:tick(calc_rate(cur_step), cur_step)
			--~ print(utils.hash_len(self.manager.sessions), self._concur_users_num)
			--~ for id, sess in pairs(self.manager.sessions) do
				--~ print(debug.traceback(sess.coroutine))
			--~ end

			if (is_finish_phase and (self._concur_users_num == 0)) or ((self.total_duration_limit > 0) and (mistress.now() - test_started >= self.total_duration_limit)) then
				self.logger:info("finishing")

				self:finish_test(cur_step + 1)

				--~ os.exit() ---
				C.stop_ev_loop()
				return
			end

			cur_step = cur_step + 1

			if self._gonna_shut_down then
				self._gonna_shut_down = false
				break
			end
		end
	end
end

function _M.Launcher:tick_sleep ()
	local ok, ex = pcall(function ()
		self:sleep(1)
	end)
	if (not ok) and (ex ~= uthread.STOP) then
		error(ex)
	end
end

function _M.Launcher:tick (rate, cur_step)
	self._concur_users_num_max = self._concur_users_num
	self._concur_users_num_min = self._concur_users_num

	self._concur_conns_num_max = self._concur_conns_num
	self._concur_conns_num_min = self._concur_conns_num

	if rate > 0 then
		for _ in utils.range(rate) do
			local launch_after = math.random()

			local sess_class = utils.weighted_random_choice(self.sessions)
			local sess = self.manager:register(function (id)
				return sess_class:new(id, self.logger, self.stat, self.manager)
			end)
			--~ print(mistress.now(), sess.id .. " will sleep " .. launch_after)
			sess.on_before_run = function ()
				--~ print(mistress.now(), "start " .. sess.id )
				sess:sleep(launch_after)
				--~ print(mistress.now(), "real start " .. sess.id )


				self._concur_users_num = self._concur_users_num + 1
				self._concur_users_num_max = math.max(self._concur_users_num, self._concur_users_num_max)

				sess.on_after_run = function ()
					self._concur_users_num = self._concur_users_num - 1
					self._concur_users_num_min = math.min(self._concur_users_num, self._concur_users_num_min)
				end


				self.stat:add(stat.stypes.START_SESSION, 1)
			end

			sess.on_connect = function ()
				self._concur_conns_num = self._concur_conns_num + 1
				self._concur_conns_num_max = math.max(self._concur_conns_num, self._concur_conns_num_max)
			end
			sess.on_disconnect = function ()
				self._concur_conns_num = self._concur_conns_num - 1
				self._concur_conns_num_min = math.min(self._concur_conns_num, self._concur_conns_num_min)
			end

			self.manager:plan_resume("", sess.id)
		end
	end

	self:tick_sleep()  -- meanwhile other sessions will run

	self.stat:add(stat.stypes.CONCUR_USERS_NUM_MAX, self._concur_users_num_max)
	self.stat:add(stat.stypes.CONCUR_USERS_NUM_MIN, self._concur_users_num_min)

	self.stat:add(stat.stypes.CONCUR_CONNS_NUM_MAX, self._concur_conns_num_max)
	self.stat:add(stat.stypes.CONCUR_CONNS_NUM_MIN, self._concur_conns_num_min)

	self:send_stats(cur_step)
	self.stat:reset()
end

function _M.Launcher:shut_down ()
	function self:shut_down ()
		print "!!! hard abort"
		os.exit()
	end

	self.logger:info("interrupted by user, gonna shut down")

	self._gonna_shut_down = true

	self.manager:shut_down()
end


return _M
