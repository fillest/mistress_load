local mistress = assert(require 'mistress.mistress')
local utils = assert(require 'mistress.utils')
local inspect = assert(require 'mistress.inspect')
local stat = assert(require 'mistress.stat')
local cookies = assert(require 'mistress.cookies')
local uthread = assert(require 'mistress.uthread')
local connection = assert(require 'mistress.connection')
local xpcall = xpcall
	if not LUA_USE_LUAJIT then
		assert(require 'coxpcall')  -- see https://github.com/keplerproject/coxpcall/blob/master/src/coxpcall.lua, also lua 5.2 and luajit
		xpcall = coxpcall
	end
local _M = utils.module()


local function try (fn, self)
	return xpcall(fn, function (orig_err_ret)
		if orig_err_ret ~= uthread.STOP then
		print("****", orig_err_ret)
		print("****", debug.traceback(self.coroutine))
		end
		--~ return orig_err_ret .. "\n\n" .. debug.traceback(self.coroutine)
		return orig_err_ret
	end)
end

_M.Session = uthread.Uthread:inherit()
function _M.Session:init (id, logger, stat, manager)
	self.id = id
	self.logger = logger
	self.stat = stat
	self.manager = manager
	self.on_before_run = nil
	self.on_after_run = nil
	self._finalizers = {}
	self._hosts_cache = {}
	self._conn_cache = {}
	self._cookies = cookies.Cookies:new()
	self.on_connect = nil -- -_-
	self.on_disconnect = nil
	--TODO dont forget about parallel() crutches when add new stuff
	self.__resm = {}
	self._gonna_shut_down = false


	self.coroutine = coroutine.create(function ()
		local status, err_ret = try(function ()
			if self.on_before_run then
				self.on_before_run()
			end

			self:run()
		end, self)

		if status or (err_ret == uthread.STOP) then
			status, err_ret = try(function ()
				if self.on_after_run then
					self.on_after_run()
				end
			end, self)
		else
			--~ print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!", inspect(status), inspect(err_ret), debug.traceback(self.coroutine))
		end


		self:clean()


		if (not status) and (err_ret ~= uthread.STOP) then
			return err_ret
		end
	end)
end

function _M.Session:receive (fd, do_fetch_body, timeout, is_req, path)
	if do_fetch_body == nil then
		do_fetch_body = true
	end
	timeout = timeout or 20

	local destroy_recv_watcher = mistress.receive(self.id, fd, do_fetch_body, timeout, is_req)
	self._finalizers[destroy_recv_watcher] = true

	local headers = nil
	--~ if do_fetch_body then
		local body = {}
	--~ end
	local res = false
	local er = nil
	local is_gzipped = false
	local status_code
	local is_keepalive = nil
	local url = nil
	repeat
		res, er = self:yield()

		if self._gonna_shut_down then
			error(uthread.STOP)
		end

		if not res then
			-- print("not res", path)
			--~ print(self.id, inspect(utils.map(function (t) return t[0] end, self.manager.active_sessions)))
			destroy_recv_watcher()
			self._finalizers[destroy_recv_watcher] = nil

			return false, er
		end

		-- print(res.parse_failed)

		if res.closed then
			return false, "conn closed"
		end

		if res.parse_failed then
			local fname = "packet_dump " .. os.date() .. "#" .. self.id .. ".bin"
			print(fname, path)
			local f = assert(io.open(fname, 'wb'))
			f:write(res.body)
			f:flush()
			f:close()

			return false, "failed to parse http packet"
		end

		url = url or res.url
		if res.headers then
			headers = res.headers
			status_code = res.status_code
			is_keepalive = res.is_keepalive
			if res.is_gzipped then
				is_gzipped = true
			end
		end
		if do_fetch_body and res.body then
			table.insert(body, res.body)
		end
	until res.is_done

	if do_fetch_body then
		body = table.concat(body)
	end

	if do_fetch_body and is_gzipped then
		--~ error(debug.traceback())
		body = mistress.gunzip(body)
	end

	destroy_recv_watcher()
	self._finalizers[destroy_recv_watcher] = nil

	return headers, do_fetch_body and body or true, res.passed, status_code, is_keepalive, url
end

function _M.Session:connect (remote_ip, remote_port, opts)
	local remote_port = remote_port or 80
	opts = utils.merge_defaults({
		local_ip = '0.0.0.0',
		local_port = 0,
		timeout = 15,
	}, opts)

	local destroy_composite_io_watcher, close_socket = mistress.connect(self.id, remote_ip, remote_port, opts.local_ip, opts.local_port, opts.timeout)
	if not destroy_composite_io_watcher then
		return 0, 'not enough ports'
	end


	self._finalizers[destroy_composite_io_watcher] = true

	local conn = connection.Connection:new()

	local function fin ()
		--~ print("fin @ connect " .. self.id)
		conn:close(true)
	end
	self._finalizers[fin] = true
	conn:add_finalizer(function (leave_fin)
		--~ print("conn:add_finalizer @ connect " .. self.id)
		close_socket()
		if not leave_fin then
			--~ print("cleaning fin @ connect " .. self.id)
			self._finalizers[fin] = nil
		end
	end)


	local fd, passed = self:yield()

	if self._gonna_shut_down then
		error(uthread.STOP)
	end

	destroy_composite_io_watcher()
	self._finalizers[destroy_composite_io_watcher] = nil

	-- assert(type(fd) == 'number' or fd == false, inspect(fd))
	conn.fd = fd

	--~ local close = function ()
		--~ close_socket()
		--~ self._finalizers[close_socket] = nil
	--~ end
	if fd ~= 0 then
		--~ return fd, passed, close
		return conn, passed
	else
		conn:close()

		local errn = passed
		return 0, passed
	end
end

function _M.Session:get_connection (host, remote_port, group_name, opts)
	local ip = self._hosts_cache[host]
	if ip then
		if type(ip) == 'table' then
			ip = ip[math.random(1, #ip)]
		end

		local hkey = ip .. ':' .. remote_port

		local conns = self._conn_cache[hkey]
		if not conns then
			conns = {{}, {}}
			self._conn_cache[hkey] = conns
		end

		local free, busy = unpack(conns)
		local _ckey_fd, conn = next(free)

		if conn then
			return unpack(conn)
		else
			--~ local fd, passed, close_socket = self:connect(ip, remote_port)
			local c, passed = self:connect(ip, remote_port, opts)
			if not (c == 0) then
				--~ print("**connected to " .. host .. ", fd " .. fd .. ", in " .. passed .. " sec")
				self.stat:add(stat.stypes.CONNECT_TIME, {group_name, passed})

				if self.on_connect then self.on_connect() end

				local fd = c.fd
				-- assert(type(fd) == 'number', inspect(fd))
				c:add_finalizer(function ()
					--~ print("get_connection -- close() " .. self.id)
					free[fd] = nil
					busy[fd] = nil

					if self.on_disconnect then self.on_disconnect() end
				end)
				local mark_busy = function ()
					busy[fd] = free[fd]
					free[fd] = nil
				end
				local mark_free = function ()
					free[fd] = busy[fd]
					busy[fd] = nil
				end
				--~ free[fd] = {fd, close, mark_busy, mark_free}
				free[fd] = {c, mark_busy, mark_free}

				return unpack(free[fd])
			else
				local err
				if passed then
					err = passed
					--~ print("**conn error " .. ((err == 111) and 'ECONNREFUSED' or err))
				else
					err = 'timeout'
				end
				self.stat:add(stat.stypes.CONNECT_ERROR, {
					msg = group_name .. ': ' .. err,
					ip = ip,
					time = mistress.now(),
				})

				return nil
			end
		end
	else
		error("host " .. host .. " was not resolved. resolve in advance, it's blocking operation")
	end
end

local function parse_headers (headers_tokens)
	--~ print("**headers_tokens", inspect(headers_tokens))
	local headers = {}
	for i = 1, #headers_tokens, 2 do
		local key = headers_tokens[i]
		if key == nil then
			print(inspect(headers_tokens))
			error('key == nil')
		end
		local value = headers_tokens[i + 1]

		local existing_value = headers[key]
		if existing_value then
			if type(existing_value) == 'table' then
				table.insert(existing_value, value)
			else
				headers[key] = {existing_value, value}
			end
		else
			headers[key] = value
		end
	end
	return headers
end

--see http://codereview.chromium.org/17045/#ps201
--see http://www.nczonline.net/blog/2009/05/05/http-cookies-explained/
--see http://en.wikipedia.org/wiki/HTTP_cookie#Cookie_attributes
function _M.Session:handle_cookies (raw_cookies, host, path)
	if type(raw_cookies) ~= 'table' then
		raw_cookies = {raw_cookies}
	end

	for _, v in ipairs(raw_cookies) do
		--print(v)

		local parts = utils.map(utils.trim, utils.split(v, ';'))
		parts = utils.map(function(s) return utils.split(s, '=') end, parts)

		local cookie = {}
		for i, v in ipairs(parts) do
			local k, v = unpack(v)
			if i == 1 then
				cookie.name = k
				assert(not v:match('^"[^"]+"$'))  --TODO handle quotes
				cookie.value = v
			else
				if k == 'path' or k == 'Path' then
					cookie.path = v
				elseif k == 'expires' or k == 'Expires' then
					cookie.expires = cookies.expires_to_timestamp(v)
				elseif k == 'domain' or k == 'Domain' then --TODO just lowercase it?
					cookie.domain = v
				elseif k == 'HttpOnly' then
					--TODO
				elseif k == 'Max-Age' then
					--TODO
				else
					error("handling cookie '" .. k .. "' part is not implemented, value: " .. (v or 'nil'))
				end
			end
		end
		--print(inspect(cookie))

		cookie.path = cookie.path or '/' --TODO get base of path
		cookie.domain = cookie.domain or host
		--print(inspect(cookie))

		self._cookies:update(cookie)
	end
	--~ print(inspect(self._cookies._cookies))
end

function _M.Session:send (fd, data)
	local pos = 0
	repeat
		-- if type(fd) ~= 'number' then print(inspect(fd)) end
		local errno, sent_len, destroy_watcher = mistress.send(fd, data, self.id, pos)
		if errno then
			if errno == 0 then
				self._finalizers[destroy_watcher] = true

				local timeout = self:yield()
				assert(not timeout)
				if self._gonna_shut_down then
					error(uthread.STOP)
				end

				destroy_watcher()
				self._finalizers[destroy_watcher] = nil

				pos = pos + sent_len

				if pos == #data then
					return
				end
			else
				return errno
			end
		else
			return
		end
	until false
end

function _M.Session:http (host, path, opts)
	--~ print('*****', host, path)
	opts = utils.merge_defaults({
		remote_port = 80,
		keepalive = true,
		method = 'GET',
		basic_auth = false,
		group_name = 'unnamed',  --change to empty
		referer = false,
		fetch_body = false,
		receive_timeout = false,
		headers = {},
		body = false,
		upload = false,
		cookies = false,
		remap_status = false,
	}, opts)

	local conn, mark_busy, mark_free = self:get_connection(host, opts.remote_port, opts.group_name)
	if conn then
		mark_busy()

		local cookies = self._cookies:get_by(host, path)

		if opts.cookies then
			for i = 1, #opts.cookies do
				cookies[#cookies + 1] = opts.cookies[i]
			end
		end

		local req = utils.build_req(path, {
			method = opts.method,
			host = (opts.remote_port == 80) and host or (host .. ':' .. opts.remote_port),
			keepalive = opts.keepalive,
			basic_auth = opts.basic_auth,
			cookies = cookies,
			referer = opts.referer,
			headers = opts.headers,
			body = opts.body,
			upload = opts.upload,
		})

		assert(not self:send(conn.fd, req))
		self.stat:add(stat.stypes.REQUEST_SENT, 1)

		local keepalive = opts.keepalive
		local res = nil
		local headers_tokens, body, passed, status_code, is_keepalive = self:receive(conn.fd, opts.fetch_body, receive_timeout, nil, path)
		--~ print('*****', host, path, "RECV")
		local headers
		if headers_tokens then
			if not is_keepalive then
				keepalive = false
			end
			--~ print("**is_keepalive", is_keepalive)
			--~ print("**body " .. body)
			--~ print("**body", "{{" .. string.sub(body, 1, 50) .. " <...> " .. string.sub(body, -50) .. "}}")

			if opts.remap_status then
				status_code = opts.remap_status[status_code] or status_code
			end

			self.stat:add(stat.stypes.RESPONSE_TIME, {opts.group_name, passed})
			self.stat:add(stat.stypes.RESPONSE_STATUS, {opts.group_name, status_code})

			headers = parse_headers(headers_tokens)

			if headers["Set-Cookie"] then
				self:handle_cookies(headers["Set-Cookie"], host, path)
			end

			res = body

			mark_free()
		else
			local err_msg = body
			self.stat:add(stat.stypes.RESPONSE_ERROR, opts.group_name .. ': ' .. err_msg)

			keepalive = false
		end


		if not keepalive then
			conn:close()
		end

		return res, headers, status_code
	else
		return nil
	end
end

--- usage
-- self:parallel({
-- 	function (self_)
-- 		local res = self_:http(HOST, '/')
-- 	end,
-- 	function (self_)
-- 		local res = self_:http(HOST, '/')
-- 	end,
-- })
function _M.Session:parallel (funs)
	local fns_left = #funs
	for _, fn in ipairs(funs) do
		local sess = self.manager:register(function (id)
			return _M.Session:new(id, self.logger, self.stat, self.manager)
		end)

		--TODO mega crutch
		sess._hosts_cache = self._hosts_cache
		sess._conn_cache = self._conn_cache
		sess._cookies = self._cookies

		sess._finalizers = self._finalizers
		sess.clean = function () end

		sess.on_connect = self.on_connect
		sess.on_disconnect = self.on_disconnect

		--TODO crutch
		sess.run = fn

		sess.on_after_run = function ()
			fns_left = fns_left - 1
			if fns_left == 0 then
				self.manager:plan_resume("", self.id)
			end
		end
		self.manager:plan_resume("", sess.id)
	end

	self:yield()

	if self._gonna_shut_down then
		error(uthread.STOP)
	end
end

function _M.Session:accept (listen_fd)
	local destroy_composite_io_watcher = mistress.accept(self.id, listen_fd)

	self._finalizers[destroy_composite_io_watcher] = true

	local fds = {self:yield()}
	assert(#fds > 0)

	if self._gonna_shut_down then
		error(uthread.STOP)
	end

	--add finalizers for fds

	destroy_composite_io_watcher()
	self._finalizers[destroy_composite_io_watcher] = nil

	return fds
end


return _M
