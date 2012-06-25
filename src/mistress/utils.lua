local mistress = assert(require 'mistress.mistress')
local mime = assert(require('mime'))
local ffi = assert(require("ffi"))
local C = ffi.C


local module_mt = {
	__index = function (_t, k)
		error("access to undeclared module field '" .. k .. "'", 2)
	end
}
local function module ()
	return setmetatable({}, module_mt)
end


local _M = module()
_M.module = module


function _M.merge_defaults (defaults, t)
	local result = {}
	t = t or {}

	for k, v in pairs(defaults) do
		if t[k] == nil then
			result[k] = v
		else
			result[k] = t[k]
		end
	end

	return result
end


_M.Object = {}
function _M.Object:construct (is_inherit_mode, ...)
	local obj = {}

	setmetatable(obj, self)
	self.__index = self

	if is_inherit_mode then
		self:init_super(obj)
	else
		obj:init(...)
	end

	return obj
end

function _M.Object:init (...)
	-- override this
end

function _M.Object:init_super (class)
	class.super = function (instance)
		return setmetatable({}, {__index = function (_class_super, method_name)
			return function (...)
				self[method_name](instance, ...)
			end
		end})
	end
end

function _M.Object:inherit ()
	return self:construct(true)
end

function _M.Object:new (...)
	return self:construct(false, ...)
end


--http://lua-users.org/wiki/RangeIterator
-- range(a) returns an iterator from 1 to a (step = 1)
-- range(a, b) returns an iterator from a to b (step = 1)
-- range(a, b, step) returns an iterator from a to b, counting by step.
function _M.range(a, b, step)
  if not b then
    b = a
    a = 1
  end
  step = step or 1
  local f =
    step > 0 and
      function(_, lastvalue)
        local nextvalue = lastvalue + step
        if nextvalue <= b then return nextvalue end
      end or
    step < 0 and
      function(_, lastvalue)
        local nextvalue = lastvalue + step
        if nextvalue >= b then return nextvalue end
      end or
      function(_, lastvalue) return lastvalue end
  return f, nil, a - step
end


function _M.map (callback, array)
	local new_array = {}
	for i, v in ipairs(array) do
		new_array[i] = callback(v)
	end
	return new_array
end


function _M.basic_auth_encode (login, passwd)
	return assert(mime.b64(login .. ':' .. passwd))
end


function _M.build_response (status, opts)
	opts = _M.merge_defaults({
		http_vsn = "1.1",
		body = false,
		keepalive = true,
		server = "Mistress/0.1",
	}, opts)

	local lines = {
		"HTTP/" .. opts.http_vsn .. " " .. status,

		"Connection: " .. (opts.keepalive and "Keep-Alive" or "close"),
		"Content-Length: " .. (opts.body and #opts.body or 0),
		"Server: " .. opts.server,
	}

	return table.concat(lines, '\r\n') .. '\r\n\r\n' .. (opts.body and opts.body or '')
end

function _M.build_req (path, opts)
	opts = _M.merge_defaults({
		method = "GET",
		http_vsn = "1.1",
		host = false, -- +port?
		body = false,
		keepalive = true,
		user_agent = "Mistress/0.1",
		basic_auth = false,
		cookies = false,
		referer = false,
	}, opts)

	local lines = {
		opts.method .. " " .. path .. " HTTP/" .. opts.http_vsn,

		"Connection: " .. (opts.keepalive and "Keep-Alive" or "close"),
		"Accept-Encoding: gzip, deflate",
		"Accept: */*",
		"User-Agent: " .. opts.user_agent,
		--~ "Accept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.7",
		"Accept-Language: en-us,en;q=0.5",
	}
	assert(opts.host)
	if opts.host then
		table.insert(lines, "Host: " .. opts.host)
	end
	if opts.body then
		table.insert(lines, "Content-Length: " .. #opts.body)
	end
	if opts.referer then
		table.insert(lines, "Referer: " .. opts.referer)
	end
	if opts.basic_auth then
		local login, pwd = unpack(opts.basic_auth)
		table.insert(lines, "Authorization: Basic " .. _M.basic_auth_encode(login, pwd))
	end
	if opts.cookies and (#opts.cookies > 0) then
		local make_value = function (pair) return pair[1] .. '=' .. pair[2] end
		table.insert(lines, "Cookie: " .. table.concat(_M.map(make_value, opts.cookies), '; '))
	end

	return table.concat(lines, '\r\n') .. '\r\n\r\n' .. (opts.body and opts.body or '')
end


--http://snippets.luacode.org/snippets/Weighted_random_choice_104
--[[
The `choices' table contains pairs of
associated (choice, weight) values:

{ Lua = 20, Python = 10, Perl = 5, PHP = 2 }
--]]
function _M.weighted_random_choice(choices)
	local threshold = math.random(0, _M.weighted_total(choices))
	local last_choice
	for choice, weight in pairs(choices) do
		threshold = threshold - weight
		if threshold <= 0 then return choice end
		last_choice = choice
	end
	return last_choice
end

function _M.weighted_total(choices)
	local total = 0
	for choice, weight in pairs(choices) do
		total = total + weight
	end
	return total
end

function _M.hash_len (t)
	local num = 0
	for _, _ in pairs(t) do
		num = num + 1
	end
	return num
end

function _M.join_arrays (t1, t2)
	local res = {}
	for _, v in ipairs(t1) do table.insert(res, v) end
	for _, v in ipairs(t2) do table.insert(res, v) end
	return res
end

function _M.trim (s) --http://lua-users.org/wiki/StringTrim
	return s:match'^%s*(.*%S)' or ''
end

-- ".1.2" -> {"1", "2"}
function _M.split (s, sep) --http://lua-users.org/wiki/SplitJoin
	local sep, fields = sep or ":", {}
	local pattern = string.format("([^%s]+)", sep)
	s:gsub(pattern, function(c) fields[#fields + 1] = c end)
	return fields
end

function _M.startswith (s, prefix)
	return s:sub(1, #prefix) == prefix
end

function _M.endswith (s, postfix)
	return s:sub(- #postfix) == postfix
end

function _M.reversed (arr)
	local res = {}
	for _, value in ipairs(arr) do
		table.insert(res, 1, value)
	end
	return res
end

function _M.slice (arr, i1, i2, step)
	i1 = i1 or 1
	i2 = i2 or #arr
	step = step or 1

	local res = {}
	for i = i1, i2, step do
		table.insert(res, arr[i])
	end
	return res
end


--from http://lua-users.org/wiki/AlternativeGetOpt
function _M.getopt( arg, options )
  local tab = {}
  for k, v in ipairs(arg) do
    if string.sub( v, 1, 2) == "--" then
      local x = string.find( v, "=", 1, true )
      if x then tab[ string.sub( v, 3, x-1 ) ] = string.sub( v, x+1 )
      else      tab[ string.sub( v, 3 ) ] = true
      end
    elseif string.sub( v, 1, 1 ) == "-" then
      local y = 2
      local l = string.len(v)
      local jopt
      while ( y <= l ) do
        jopt = string.sub( v, y, y )
        if string.find( options, jopt, 1, true ) then
          if y < l then
            tab[ jopt ] = string.sub( v, y+1 )
            y = l
          else
            tab[ jopt ] = arg[ k + 1 ]
          end
        else
          tab[ jopt ] = true
        end
        y = y + 1
      end
    end
  end
  return tab
end

function _M.get_cwd ()
	local length = 2048
	local cDir = ffi.new("char[?]", length)
	C.getcwd(cDir, length)
	return ffi.string(cDir)
end

function _M.get_urandom_seed ()
	local seed = 1

	local f = io.open('/dev/urandom', 'rb')
	local urandom = f:read(32)
	f:close()

	for i = 1, string.len(urandom) do
		seed = seed + string.byte(urandom, i)
	end

	return seed
end


function _M.sub (s, tab)
	return (s:gsub('($%b{})', function (w) return tab[w:sub(3, -2)] or w end))
end


function _M.round (num, idp)  -- from http://lua-users.org/wiki/SimpleRound
	local mult = 10^(idp or 0)
	if num >= 0 then
		return math.floor(num * mult + 0.5) / mult
	else
		return math.ceil(num * mult - 0.5) / mult
	end
end


return _M
