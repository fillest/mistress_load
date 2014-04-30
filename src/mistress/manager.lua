local utils = assert(require 'mistress.utils')
local inspect = assert(require 'mistress.inspect')
local mistress = assert(require 'mistress.mistress')
local _M = utils.module()


_M.Manager = utils.Object:inherit()
function _M.Manager:init ()
	self.sessions = {}
	self.active_sessions = {}
	self.active_sessions_ids = {}
	self.next_id = 0
end

function _M.Manager:register (callback)
	--local next_id = #self.sessions + 1 --its O(n) isnt it?
	self.next_id = self.next_id + 1
	local session = callback(self.next_id)
	--table.insert(self.sessions, session)
	self.sessions[self.next_id] = session

	return session
end

--- Mark session to be resumed on next cb_prepare
-- This is called in C callbacks
-- @param id Session id
-- @param ... Params for session:resume()
function _M.Manager:plan_resume (from, id, ...)  --TODO rename enqueue_awake?
	--~ if coroutine.status((self.sessions[id].coroutine)) == 'dead' then
		--~ print(debug.traceback())
	--~ end
	--print(...)
	--~ table.insert(self.sessions[id].__resm, {from, debug.traceback()})
	-- print("plan", from, id)


	if self.active_sessions_ids[id] == nil then
		--~ print(inspect(self.active_sessions))
		--~ for id, params in pairs(self.active_sessions) do
			--~ print("-" ,id)
		--~ end

		self.active_sessions_ids[id] = true


		--~ self.active_sessions[id] = {...}
		--~ print(inspect(self.active_sessions))
		--~ for id, params in pairs(self.active_sessions) do
			--~ print("-" ,id)
		--~ end
		table.insert(self.active_sessions, {id, {...}})
	else
		print("**'late resume' from: " .. from)   --TODO need to inspect stack, can we get two recv callbacks?
	end
end

local CORO_DEAD = 'dead'
function _M.Manager:resume_active_sessions ()  --TODO rename to resume_awake_sessions?
	--~ for id, params in pairs(self.active_sessions) do
		--~ print("---" ,id)
	--~ end
	--~ local ss = self.active_sessions
	--~ self.active_sessions = {}
	--~ for id, params in pairs(ss) do
		--~ print("---" ,id)
	--~ end
	for _i, v in ipairs(self.active_sessions) do
	--~ for id, params in pairs(ss) do
		local id, params = unpack(v)
		--~ print(mistress.now(), "resuming", id)
		--print(unpack(params))
		local sess = self.sessions[id]
		if sess then
			local is_success, err_ret = sess:resume(unpack(params))

			if is_success then
				if err_ret then
					error(err_ret)
				end
			else
				if err_ret then
					--~ print "======================================================"
					--~ print(id, inspect(self.sessions[id].__resm))
					print(id, inspect(debug.getinfo(sess.run)))
					error(err_ret)
				else
					--~ print "------------------------------------------------------------"
					error(debug.traceback(sess.coroutine))
				end
			end

			if coroutine.status(sess.coroutine) == CORO_DEAD then  --TODO move to uthread
				self.sessions[id] = nil
			end
		else
			print("!! sess " .. id .. " is absent")
		end
	end

	self.active_sessions = {}
	self.active_sessions_ids = {}
	--~ print(mistress.now(), "done resuming")
end

function _M.Manager:shut_down ()
	--~ self.active_sessions = {}
	--~ self.active_sessions_ids = {}

	for id, sess in pairs(self.sessions) do
		sess._gonna_shut_down = true

		self:plan_resume("", id)
	end
end


return _M
