--  Basic functionality: threads and message-passing
local lunit		= require "luaunit"
local mg		= require "moongen"
local memory	= require "memory"
local device	= require "device"
local timer		= require "timer"

local log		= require "testlog"
local testlib	= require "testlib"
local tconfig	= require "config.tconfig"

local ffi		= require "ffi"

ffi.cdef[[
	typedef struct teststruct {
		double value1;
		uint64_t value2;
	} teststruct_t;

]]

function master()
	log:info( "Function to test: Threads and message-passing" )
	testlib:setRuntime(10)
	testlib:masterSingle()
end

function slave()
	local foo = memory.alloc("teststruct_t*", ffi.sizeof("teststruct_t"))
	foo.value1 = -0.25
	foo.value2 = 0xDEADBEEFDEADBEEFULL
	local res1 = mg.startTask("slave1", 1, "string"):wait()
	local res2 = mg.startTask("slave2", {1, { foo = "bar", cheese = 5 }}):wait()
	local res3 = mg.startTask("slave3", foo):wait()
	return res1 and res2 and res3
end

function slave1(num, str)
	lunit.assertEquals(num, 1)
	lunit.assertEquals(str, "string")
	return true
end

function slave2(arg)
	lunit.assertEquals(arg, {1, {foo = "bar", cheese = 5}})
	return true
end

function slave3(arg)
	lunit.assertEquals(arg.value1, -0.25)
	lunit.assertEquals(arg.value2, 0xDEADBEEFDEADBEEFULL)
	return true
end


