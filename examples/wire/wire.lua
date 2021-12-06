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

local wire = ffi.load("wire")

function configure(parser)
	parser:description("Simulates a wire. Forwards the packets from one port to the other with the same spacing and a configurable delay.")
	parser:argument("dev", "Devices to use."):args(2):convert(tonumber)
	parser:option("-d --delay", "The forwarding delay (in ms)."):convert(tonumber):default(10)
	parser:option("-o --output", "File to output statistics to")
end

function master(args)
	local dev1 = device.config({port = args.dev[1], rxQueues = 2, txQueues = 2, txDescs = 4096, numBufs = 5000000})
	local dev2 = device.config({port = args.dev[2], rxQueues = 2, txQueues = 2})
	device.waitForLinks()

	--stats.startStatsTask{dev1, dev2}

	args.delay = args.delay * 1e6
	
	local barrierReadTs = barrier:new(2)
	local barrierStartReceive = barrier:new(3)

	local timingPipe = pipe:newFastPipe()
	local packetPipe = pipe:newFastPipe()
	
    mg.startTask("transmitter", dev1:getTxQueue(0), barrierReadTs, timingPipe, barrierStartReceive, packetPipe, args)
	mg.startTask("timestamper", dev1, barrierReadTs, timingPipe, barrierStartReceive, packetPipe)
	mg.startTask("receiver", dev2:getRxQueue(0), barrierStartReceive, packetPipe)	
	--mg.sleepMillisIdle(3000)
	--mg.startTask("testReceiver", dev2:getRxQueue(0))
	--mg.startTask("testTransmitter", dev2:getTxQueue(0))
    mg.waitForTasks()
end

function testTransmitter(txQueue)
	local mem = memory.createMemPool(function(buf)
		buf:getEthernetPacket():fill{
			ethType = 0x1234
		}
	end)
	local bufs = mem:bufArray(1)
	while mg.running() do
		bufs:alloc(1500)
		txQueue:send(bufs)
		mg.sleepMillisIdle(100)
	end
end

function testReceiver(rxQueue)
	local bufs = memory.createBufArray()
	while mg.running() do
		local n = rxQueue:recv(bufs)
		for i = 1, n do
			local ts = bufs[i]:getTimestamp(rxQueue.dev)
			print(ts)
		end
		bufs:free(n)
	end
end

ffi.cdef[[
	struct received_packets { struct rte_mbuf** bufs; uint32_t count; };
	uint64_t moongen_send_all_delay_offset_e810(uint8_t port_id, uint16_t queue_id, struct rte_mbuf** load_pkts, uint16_t num_pkts, struct mempool* pool, uint64_t currentByteOffset, uint64_t firstPacketTimestamp, uint64_t delay);
]]

function receiver(queue, barrierStartReceive, packetPipe)
	barrierStartReceive:wait()
	while mg.running() do
		local bufs = memory.bufArray(64)
		local rx = queue:tryRecv(bufs, 1000)
		if rx > 0 then
			local d = memory.alloc("struct received_packets*", ffi.sizeof("struct received_packets"))
			d.bufs = bufs.array
			d.count = rx
			local ts = bufs[1]:getTimestamp(queue.dev)
			packetPipe:send(d)
		end
	end
end

function timestamper(dev, barrierReadTs, timingPipe, barrierStartReceive)
	dev:enableTxTimestamps()
	barrierReadTs:wait()
	local sendingTime = dev:getTxTimestamp()
	local d = memory.alloc("uint32_t*", ffi.sizeof("uint32_t"))
	d[1] = sendingTime
	timingPipe:send(d)
	barrierStartReceive:wait()
end

function transmitter(queue, barrierReadTs, timingPipe, barrierStartReceive, packetPipe, args)
	local INV_SIZE = 9000
	local DELAY_BATCH_SIZE = 512

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
	--local startupTimer = timer:new(1)
	--while startupTimer:running() do
	--	delayBufArray:alloc(INV_SIZE)
	--	queue:send(delayBufArray)
	--end
	
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

	-- start receiver
	barrierStartReceive:wait()

	-- wait for packets from receiver or send delay packets
	while mg.running() do
		local receivedValue = packetPipe:tryRecv(0)
		if receivedValue ~= nil then
			-- send packets with delay
			local data = ffi.cast("struct received_packets*", receivedValue)
			currentByteOffset = wire.moongen_send_all_delay_offset_e810(queue.dev.id, queue.qid, data.bufs, data.count, memInv, currentByteOffset, firstPacketTimestamp, args.delay)
		else
			-- just send delay
			delayBufArray:alloc(INV_SIZE)
			queue:send(delayBufArray)
			currentByteOffset = currentByteOffset + DELAY_BATCH_SIZE * (INV_SIZE + 24)
		end
	end
end