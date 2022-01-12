local mg     = require "moongen"
local memory = require "memory"
local device = require "device"
local ts     = require "timestamping"
local stats  = require "stats"
local hist   = require "histogram"
local timer  = require "timer"
local bit	 = require "bit"
local dpdk 	 = require "dpdk"
local barrier= require "barrier"
local pipe   = require "pipe"
local ffi	 = require "ffi"

local wire = ffi.load("build/wire")

function configure(parser)
	parser:description("Simulates a wire. Forwards the packets from one port to the other with the same spacing and a configurable delay.")
	parser:argument("dev", "Devices to use."):args(2):convert(tonumber)
	parser:option("-d --delay", "The forwarding delay (in ms)."):convert(tonumber):default(10)
	parser:option("-o --output", "File to output statistics to")
end

function master(args)
	local dev1 = device.config({port = args.dev[1], rxQueues = 1, txQueues = 1, numBufs = 7000000})
	local dev2 = device.config({port = args.dev[2], rxQueues = 1, txQueues = 1, txDescs = 4096})
	device.waitForLinks()

	--stats.startStatsTask{dev1, dev2}

	args.delay = args.delay * 1e6
	
	local barrierReadTs = barrier:new(2)
	local barrierStartReceive = barrier:new(2)

	local timingPipe = pipe:newFastPipe()
	local packetRing = pipe:newPacketRing(8388608)
	
    mg.startTask("transmitter", dev2:getTxQueue(0), barrierReadTs, timingPipe, barrierStartReceive, packetRing, args)
	mg.startTask("timestamper", dev2, barrierReadTs, timingPipe, barrierStartReceive, packetRing)
	mg.startTask("receiver", dev1:getRxQueue(0), barrierStartReceive, packetRing)	
	--mg.sleepMillisIdle(3000)
	--mg.startTask("testReceiver", dev2:getRxQueue(0))
	--mg.startTask("testTransmitter", dev2:getTxQueue(0))
    mg.waitForTasks()
end

ffi.cdef[[
	void receiver_loop(uint8_t port_id, uint16_t queue_id, struct rte_ring* packet_ring);
	void transmitter_loop(uint8_t port_id, uint16_t queue_id, struct rte_ring* packet_ring, struct mempool* pool, uint64_t currentByteOffset, uint64_t firstPacketTimestamp, uint64_t delay);
	uint64_t moongen_send_all_delay_offset_e810(uint8_t port_id, uint16_t queue_id, struct rte_mbuf** load_pkts, uint16_t num_pkts, struct mempool* pool, uint64_t currentByteOffset, uint64_t firstPacketTimestamp, uint64_t delay);
	]]

function receiver(queue, barrierStartReceive, packetRing)
	queue.dev:enableRxTimestampsAllPackets()
	barrierStartReceive:wait()
	wire.receiver_loop(queue.dev.id, queue.qid, packetRing.ring)
end

function timestamper(dev, barrierReadTs, timingPipe, barrierStartReceive)
	dev:enableTxTimestamps()
	barrierReadTs:wait()
	local sendingTime = dev:getTxTimestamp()
	local d = memory.alloc("uint32_t*", ffi.sizeof("uint32_t"))
	d[1] = sendingTime
	timingPipe:send(d)
end

function transmitter(queue, barrierReadTs, timingPipe, barrierStartReceive, packetRing, args)
	local INV_SIZE = 9000
	local DELAY_BATCH_SIZE = 2048

    -- mempool with invalid packets
    local memInv = memory.createMemPool({n = 8096, func=function(buf)
		buf:getEthernetPacket():fill{
			ethType = 1
		}
	end})

	local delayBufArray = memInv:bufArray(DELAY_BATCH_SIZE)
	
	local currentByteOffset = 0
	local firstPacketTimestamp = 0
	local probePacket = true
	
	-- startup
	local startupTimer = timer:new(1)
	while startupTimer:running() do
		delayBufArray:alloc(INV_SIZE)
		queue:send(delayBufArray)
	end

	-- start receiver
	barrierStartReceive:wait()
	
	-- send delay probing packet and wait
	local probingTimer = timer:new(1)
	while probingTimer:running() do
		delayBufArray:alloc(INV_SIZE)
		if probePacket then
			delayBufArray[1].ol_flags = bit.bor(delayBufArray[1].ol_flags, dpdk.PKT_TX_IEEE1588_TMST)
			probePacket = false
		else
			delayBufArray[1].ol_flags = bit.band(delayBufArray[1].ol_flags, bit.bnot(dpdk.PKT_TX_IEEE1588_TMST))
		end

		queue:send(delayBufArray)
		currentByteOffset = currentByteOffset + DELAY_BATCH_SIZE * (INV_SIZE + 24)
	end

	-- request TX timestamp from timestamping thread 
	barrierReadTs:wait()

	-- wait for timing information from other thread
	while mg.running() do
		delayBufArray:alloc(INV_SIZE)
		queue:send(delayBufArray)
		currentByteOffset = currentByteOffset + DELAY_BATCH_SIZE * (INV_SIZE + 24)

		local receivedValue = timingPipe:tryRecv(0)
		if receivedValue ~= nil then
			local data = ffi.cast("uint32_t*", receivedValue)
			firstPacketTimestamp = data[1]
			break
		end
	end

	-- start transmitter
	wire.transmitter_loop(queue.dev.id, queue.qid, packetRing.ring, memInv, currentByteOffset, firstPacketTimestamp, args.delay);
end