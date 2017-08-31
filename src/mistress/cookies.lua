local _M = {};
local utils = assert(require 'mistress.utils')
local inspect = assert(require 'mistress.inspect')


--http://stackoverflow.com/a/4105340/1183239
--WARNING: requires TZ env var = UTC
local MON = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
local CEFMT = '%a+, (%d+)[ -](%a+)[ -](%d+) (%d+):(%d+):(%d+) GMT' --https://tools.ietf.org/html/rfc2616#section-3.3.1
function _M.expires_to_timestamp (raw)
	local day, month, year, hour, min, sec = assert(raw:match(CEFMT))

	year = tonumber(year)
	if year < 100 then
		year =  math.floor(tonumber(os.date('%Y')) / 100) * 100 + year
	end

	return os.time({day = day, month = assert(MON[month]), year = year, hour = hour, min = min, sec = sec, isdst = false})
end


_M.Cookies = utils.Object:inherit()
function _M.Cookies:init ()
	self._cookies = {}  -- [domain mask][path prefix][name] = cookie data table
end

function _M.Cookies:update (cookie)
	local paths = self._cookies[cookie.domain]
	if not paths then
		paths = {}
		self._cookies[cookie.domain] = paths
	end

	local data = paths[cookie.path]
	if not data then
		data = {}
		paths[cookie.path] = data
	end

	local old_cookie = data[cookie.name]
	if old_cookie then
		-- os.time here depends on env tz=utc
		if (cookie.expires and (cookie.expires <= (old_cookie.expires or os.time()))) or (cookie.value == nil) or (cookie.value == '') then
			data[cookie.name] = nil
		else
			data[cookie.name] = cookie
		end
	else
		data[cookie.name] = cookie
	end
end

function _M.Cookies:get_by (domain, path)
	local parts = utils.split(domain, '.')
	local masks = {[domain] = true}  -- put strict value
	local buf = {}
	for i = #parts, 1, -1 do
		table.insert(buf, 1, parts[i])
		if i < #parts then  -- don't need last part - tld (there's "co.uk" but anyway)
			masks['.' .. table.concat(buf, '.')] = true  -- put wildcard masks
		end
	end
	--print(inspect(masks))

	local result = {}
	local now = os.time() -- os.time here depends on env tz=utc
	for mask in pairs(masks) do
		local paths = self._cookies[mask]
		if paths then
			for prefix, data in pairs(paths) do
				if utils.startswith(path, prefix) then --TODO check slash!
					for name, cookie in pairs(data) do
						if (cookie.expires == nil) or (cookie.expires > now) then
							table.insert(result, {cookie.name, cookie.value})
						else
							data[name] = nil
						end
					end
				end
			end
		end
	end
	return result
end



return _M
