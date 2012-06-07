local utils = assert(require 'mistress.utils')
local mistress = assert(require 'mistress.mistress')
local inspect = assert(require 'mistress.inspect')
local _M = utils.module()

_M.STOP = {}


_M.Uthread = utils.Object:inherit()

function _M.Uthread:run ()
	error("Must be implemented in subclass")
end

function _M.Uthread:yield ()
	-- don't yield values (see resume_active_sessions)
	return coroutine.yield()
end

function _M.Uthread:resume (...)
	return coroutine.resume(self.coroutine, ...)
end

-- explicit cooperate with other coroutines, for example if you wanna run long loop without implicit yielding
function _M.Uthread:cooperate () --rename to reschedule?
	--TODO use micro-sleep? otherwise it possibli can block ioloop resuming anyway?
	self.manager:plan_resume("", self.id)
	self:yield()

	if self._gonna_shut_down then
		error(_M.STOP)
	end
end

function _M.Uthread:clean ()
	--~ print(self.id, "fin", inspect(self._finalizers))
	for finalize, _dunno in pairs(self._finalizers) do
		--~ print(inspect(debug.getinfo(finalize)))
		finalize()
	end

	self._finalizers = {}
end

-- relative second or absolute timestamp
function _M.Uthread:sleep (sec)  --rename to wait
	local destroy_sleep_watcher = mistress.sleep(self.id, sec)
	self._finalizers[destroy_sleep_watcher] = true

	local y_res = {self:yield()}

	if self._gonna_shut_down then
		error(_M.STOP)
	end

	destroy_sleep_watcher()
	self._finalizers[destroy_sleep_watcher] = nil

	return unpack(y_res)
end


return _M
