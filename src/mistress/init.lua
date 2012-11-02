package.path = package.path .. ';' .. LUA_SRC_PATH .. '/?.lua'
--package.path = package.path .. ';' .. '/usr/share/lua/5.1/?.lua'
--package.path = package.path .. ';' .. '/usr/share/lua/5.1/?/init.lua'
--package.path = package.path .. ';' .. '/usr/share/lua/5.1/?/?.lua'
package.path = package.path .. ';' .. './?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/local/lib/lua/5.1/?.lua;/usr/local/lib/lua/5.1/?/init.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua'
package.cpath = package.cpath .. ';' .. './?.so;/usr/local/lib/lua/5.1/?.so;/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;/usr/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so'


io.stdout:setvbuf("no")
io.stderr:setvbuf("no")


assert(require 'mistress.lock_globals')
local inspect = assert(require 'mistress.inspect')
local utils = assert(require 'mistress.utils')
	local map = utils.map
	local sub = utils.sub
local stat = assert(require 'mistress.stat')
local manager = assert(require 'mistress.manager')
local mistress = assert(require 'mistress.mistress')
local session = assert(require 'mistress.session')
local launcher = assert(require 'mistress.launcher')
assert(require 'logging')  -- http://www.keplerproject.org/lualogging/manual.html
assert(require 'logging.console')
local ffi = assert(require("ffi"))
local C = ffi.C
ffi.cdef [[
	void stop_ev_loop ();
	int script_listen (int port, int backlog);
	int close (int fd);
	char *getcwd(char *buf, size_t size);
]]
local Acceptor = require("mistress.acceptor").Acceptor
local HTTPHandler = require("mistress.HTTPHandler").HTTPHandler


local function check_env (logger)
	local f = assert(io.popen('ulimit -n'))
	local ulimitn = assert(f:read('*n'))
	local ulimitn_wanted_lvl = 60000
	if ulimitn < ulimitn_wanted_lvl then
		logger:warn('`ulimit -n` is < ' .. ulimitn_wanted_lvl)
	end
	f:close()

	local f = assert(io.popen('cat /proc/sys/net/ipv4/ip_local_port_range'))
	local range = assert(f:read('*a'))
	local port_l, port_h = unpack(map(tonumber, {range:match("(%d+)%s+(%d+)")}))
	local wanted_port_range = 60000
	if (port_h - port_l) < wanted_port_range then
		logger:warn('usable local port range is < ' .. wanted_port_range)
	end
	f:close()
end


local function init_scheduler ()
	local manager = manager.Manager:new()

	mistress.register_plan_resume(function (...) manager:plan_resume(...) end)
	mistress.register_resume_active_sessions(function (...) manager:resume_active_sessions(...) end)

	return manager
end





local WorkersManager = session.Session:inherit()
function WorkersManager:init (cfg, script, ...)
	self:super().init(...)

	self._cfg = cfg
	self._cfg.opts = utils.merge_defaults({
		--total_duration_limit = 0,
		--phases = {users_rate = 1, duration = 1},
		--sessions = {},
		no_stat_server = false,
		stat_server_host = 'localhost',
		stat_server_port = 7777,
		--node_id = false,
		start_delay = 8,
		project_id = false,
	}, self._cfg.opts)

	self._workers = self._cfg.workers
	self._start_delay = self._cfg.opts.start_delay
	self._script = script
	self._no_stat_server = self._cfg.opts.no_stat_server

	self.stat_server = {
		conn = nil,
		host = self._cfg.opts.stat_server_host,
		port = self._cfg.opts.stat_server_port,
	}

	self._test_id = nil
end

--copypaste from launcher
function WorkersManager:connect_to_stat_server ()
	if not self._no_stat_server then
		self.logger:info("connecting to stat server " .. self.stat_server.host .. ":" .. self.stat_server.port)

		local conn, err = self:connect(utils.resolve_host(self.stat_server.host), self.stat_server.port)
		if not (conn == 0) then
			self.stat_server.conn = conn
		else
			error("failed to connect to stat server, err: " .. ((err == 111) and 'ECONNREFUSED' or err))
		end
	end
end

function WorkersManager:register_test (worker_num, delayed_start_time, project_id)
	if not self._no_stat_server then
		self.logger:info("registering test")

		assert(not mistress.send(self.stat_server.conn.fd, utils.build_req(
			'/new_test?worker_num='..worker_num
			..'&delayed_start_time='..delayed_start_time
			..'&project_id='..project_id,
			{method = 'POST', host = self.stat_server.host, body = self._script}
		))) --TODO host+port
		local _headers, body, _, status_code, _ = self:receive(self.stat_server.conn.fd)
		if not _headers then
			error("conn to stat server was closed")
		end
		assert(status_code == 200, 'status_code == 200')

		self._test_id = body
	end
end


function WorkersManager:run ()
	self:connect_to_stat_server()


	self.logger:info('starting workers')
	local t_start = os.time()
	for i, worker in ipairs(self._workers) do
		local host, port, ssh_port, ssh_user, mistress_path = unpack(worker)

		ssh_port = ssh_port or 22
		ssh_user = ssh_user and (ssh_user .. "@") or ""
		mistress_path = mistress_path or "/home/f/proj/mistress-load"

		local cmd = sub([[ssh -p ]]..ssh_port.." "..ssh_user..[[${host} -o "PasswordAuthentication no" -o "StrictHostKeyChecking no" 'screen -S mistress_worker${node_id} -d -m bash -c ]]
			..[["cd ]]..mistress_path..[[ && ]]
			..[[build/dev/mistress --worker --port=${port} --node-id=${node_id} ]]
			..[[>> worker${node_id}.log 2>&1"']], {
				node_id = i,
				port = port,
				host = host,
			})
		self.logger:info('running: ' .. cmd)
		if os.execute(cmd) ~= 0 then
			self.logger:error("failed to start worker")
			os.exit(1)
		end
	end
	self:sleep(3) --TODO properly wait workers to start
	self.logger:info('all workers were started(hopefully) in ' .. os.difftime(os.time(), t_start) .. ' seconds')


	local delayed_start_time = mistress.now() + self._start_delay
	self:register_test(#self._workers, delayed_start_time, self._cfg.opts.project_id)

	local workers_left = #self._workers
	local function on_worker_finished ()
		workers_left = workers_left - 1
		if workers_left == 0 then
			self.logger:info("all workers finished")
			C.stop_ev_loop()
		end
	end

	self.logger:debug('resolving hosts')
	local workers_resolved = {}
	for i, worker in ipairs(self._workers) do
		local host, _port = unpack(worker)
		workers_resolved[host] = utils.resolve_host(host)
	end

	local fns = {}
	for i, worker in ipairs(self._workers) do
		local host, port = unpack(worker)

		fns[#fns + 1] = function (_self)
			_self.logger:info("communicating with woker " .. host .. ":" .. port)

			local t_start = os.time()
			local conn, err = _self:connect(workers_resolved[host], port, {timeout = 40})
			self.logger:info(host .. ":" .. port .. ' connect took ' .. os.difftime(os.time(), t_start) .. ' seconds')

			if not (conn == 0) then
				local req = utils.build_req('/start/' .. self._test_id .. '/' .. delayed_start_time, {
					host = host .. ':' .. port,
					keepalive = true,
					body = self._script,
				})
				assert(not mistress.send(conn.fd, req))

				local _headers, body, _, status_code, _ = _self:receive(conn.fd)
				if not _headers then
					error(body)
				end
				assert(status_code == 200, 'status_code = '..status_code)


				self.logger:info("waiting worker to finish")
				local _headers, body, _, status_code, _ = _self:receive(conn.fd, true, 0)
				if not _headers then
					error(body)
				end
				assert(status_code == 200, 'status_code = '..status_code)
				assert(body == 'finished')

				on_worker_finished()
			else
				--tofix: err can be nil
				--self.logger:
				error("failed to connect to worker " .. host .. ":" .. port..", err: " .. ((err == 111) and 'ECONNREFUSED' or err or 'timeout'))
			end
		end
	end
	self.logger:info('communicating with workers')
	self:parallel(fns)
end


local function get_default_rng_seed ()
	return os.time() + utils.get_urandom_seed()
end


local function run_worker (opts, logger, manager)
	check_env(logger)

	math.randomseed(get_default_rng_seed())

	local host = '0.0.0.0'
	local port = (opts.port and tonumber(opts.port)) or 6677
	local backlog = 666
	local node_id = opts['node-id'] or 1
	logger:info("worker mode, node id = "..node_id..", listening on "..host..":" .. port)
	local fd = C.script_listen(port, backlog)


	local acceptor = manager:register(function (id)
		return Acceptor:new(fd, HTTPHandler, node_id, id, logger, false, manager)
	end)
	manager:plan_resume("", acceptor.id)


	--~

	--~ mistress.register_shut_down(function () launcher:shut_down() end)
	--mistress.register_shut_down(function () C.stop_ev_loop() end)
end

local function run_manager (opts, logger, manager)
	logger:info("manager mode")

	local script = opts.s
	if not script then
		print "**usage error: pass yor test script name as command line argument -s myscript (you can omit '.lua')"
		os.exit(1)
	end
	local script_path = utils.get_cwd() .. '/' .. script .. (utils.endswith(script, '.lua') and '' or '.lua')

	local f = assert(io.open(script_path, 'rb'))
	local script_content = assert(f:read('*a'))
	f:close()

	local test_config = assert(dofile(script_path))()

	if test_config.logging_level then
		logger:setLevel(test_config.logging_level)
	end

	math.randomseed(test_config.rng_seed or get_default_rng_seed())


	local wmgr = manager:register(function (id)
		return WorkersManager:new(test_config, script_content, id, logger, false, manager)
	end)
	manager:plan_resume("", wmgr.id)
end

local function start ()
	local opts = utils.getopt(ARGV, 's')

	if opts.h then
		print "usage: ... <`--worker` or `-s script`>"
		os.exit()
	end

	local logger = logging.console()
	logger:setLevel(logging.DEBUG)

	local manager = init_scheduler()

	if opts.worker then
		run_worker(opts, logger, manager)
	else
		run_manager(opts, logger, manager)
	end
end


start()
