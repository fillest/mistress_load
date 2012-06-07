local utils = assert(require 'mistress.utils')
local inspect = assert(require 'mistress.inspect')
local _M = utils.module()


_M.Connection = utils.Object:inherit()
function _M.Connection:init ()
	self.fd = nil

	self._finalizers = {}
end

function _M.Connection:add_finalizer (finalize)
	table.insert(self._finalizers, finalize)
end

function _M.Connection:close (leave_fin)
	local fs = self._finalizers
	for i = #fs, 1, -1 do
		fs[i](leave_fin)
	end
end


return _M
