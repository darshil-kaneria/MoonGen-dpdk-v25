local mod = {}

local mg              = require "moongen"
local device          = require "device"
local pkt             = require "packet"
local memory          = require "memory"
local ffi             = require "ffi"
local log             = require "log"
local dpdkc           = require "dpdkc"
local pipe            = require "pipe"
local crc_ratecontrol = require "crc-ratecontrol"
local serpent         = require "Serpent"

local C = ffi.C

ffi.cdef [[
	struct DelayEmulator { };

	struct DelayEmulator* mg_launchtimer_create(struct RateLimiterCRC* ratelimiter, struct rte_ring* packet_ring, uint8_t port_id, uint64_t LINE_RATE, uint64_t PACKET_OVERHEAD);
    void mg_launchtimer_transmit_loop(struct DelayEmulator* launchtimer);
]]

local C = ffi.C

local launchTimer = {}
mod.launchTimer = launchTimer
launchTimer.__index = launchTimer

function mod.new(queue, queue_size)
	local queue_size = queue_size or 4194304
    local ratecontrol = crc_ratecontrol.new(queue)
    local packet_ring = pipe:newPacketRing(queue_size)
	local linkSpeed = queue.dev:getLinkStatus().speed
	local launchtimer = C.mg_launchtimer_create(ratecontrol.delayer, packet_ring.ring, queue.id, linkSpeed, ratecontrol.pktOverhead)
	return setmetatable({
		queue = queue,
		ratecontrol = ratecontrol,
		packet_ring = packet_ring,
		launchtimer = launchtimer
	}, launchTimer)
end

-- needs to be called from main thread
function launchTimer:start()
	mg.startTask("__MG_LAUNCH_TIMESTAMP_MAIN", self)
end

function launchTimer:send(bufs)
	repeat
		if pipe:sendToPacketRing(self.packet_ring.ring, bufs) then
			break
		end
	until not mg.running()
end

function launchTimer:sendN(bufs, n)
	repeat
		if pipe:sendToPacketRing(self.packet_ring.ring, bufs, n) then
			break
		end
	until not mg.running()
end

function launchTimer:__serialize()
	return "require 'launch-timestamp'; return " .. serpent.addMt(serpent.dumpRaw(self), "require('launch-timestamp').launchTimer"), true
end

function __MG_LAUNCH_TIMESTAMP_MAIN(launchtimer)
	C.mg_launchtimer_transmit_loop(launchtimer.launchtimer)
end

return mod
