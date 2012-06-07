local function unlock_new_index (t, k, v)
	rawset(t, k, v)
end

local function GLOBAL_unlock (t)
	local mt = getmetatable(t) or {}
	mt.__newindex = unlock_new_index
	setmetatable(t, mt)
end

local function lock_new_index (t, k, v)
	if k == 'ltn12' or k == 'mime' or k == 'socket' or k == 'lpeg' or k == 'json' or k == 'coxpcall' or k == 'copcall' or k == 'logging' or k == 'posix' then
		rawset(t, k, v)
	else
		GLOBAL_unlock(t)
		print(debug.traceback())
		print("key, value:", k, v)
		error("global variable assigment", 2)
	end
end

local function GLOBAL_lock (t)
	local mt = getmetatable(t) or {}
	mt.__newindex = lock_new_index
	setmetatable(t, mt)
end


GLOBAL_lock(_G)
