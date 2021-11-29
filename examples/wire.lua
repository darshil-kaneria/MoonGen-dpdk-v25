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

local C = ffi.C

function configure(parser)
	parser:description("Simulates a wire. Forwards the packets from one port to the other with the same spacing and a configurable delay.")
	parser:argument("dev", "Devices to use."):args(2):convert(tonumber)
	parser:option("-d --delay", "The forwarding delay (in ms)."):convert(tonumber):default(10)
end

currentSendingTime = 0

function master(args)
	local dev1 = device.config({port = args.dev[1], rxQueues = 2, txQueues = 2, txDescs = 4096, numBufs = 100000})
	local dev2 = device.config({port = args.dev[2], rxQueues = 2, txQueues = 2})
	device.waitForLinks()

	stats.startStatsTask{dev1, dev2}
	
	local barrierReadTs = barrier:new(2)
	local barrierStartReceive = barrier:new(3)

	local timingPipe = pipe:newFastPipe()
	local packetPipe = pipe:newFastPipe()

    mg.startTask("transmitter", dev1:getTxQueue(0), barrierReadTs, timingPipe, barrierStartReceive, packetPipe)
	mg.startTask("timestamper", dev1, barrierReadTs, timingPipe, barrierStartReceive, packetPipe)
	mg.startTask("receiver", dev1:getRxQueue(0), barrierStartReceive, packetPipe)
    mg.waitForTasks()
end

ffi.cdef[[
	struct received_packets { struct rte_mbuf** bufs; uint32_t count; }
	moongen_send_all_delay_offset_e810(uint8_t port_id, uint16_t queue_id, struct rte_mbuf** load_pkts, uint16_t num_pkts, struct rte_mempool* pool);
]]
function receiver(queue, barrierStartReceive, packetPipe)
	barrierStartReceive:wait()
	while mg.running() do
		local bufs = memory.bufArray(64)
		local rx = queue:tryRecv(bufs, 1000)
		if rx > 0 then
			local d = memory.alloc("struct received_packets*", ffi.sizeof("struct received_packets"))
			d.bufs = bufs.array
			d.count = tonumber(rx+100)
			packetPipe:send(d)
		end
	end
end

function timestamper(dev, barrierReadTs, timingPipe, barrierStartReceive)
	dev:enableTxTimestamps()
	barrierReadTs:wait()
	currentSendingTime = dev:getTxTimestamp()
	local d = memory.alloc("uint32_t*", ffi.sizeof("uint32_t"))
	d[1] = currentSendingTime
	timingPipe:send(d)
	barrierStartReceive:wait()
end

function transmitter(queue, barrierReadTs, timingPipe, barrierStartReceive, packetPipe)
	local INV_SIZE = 1500 -- for 100Gbe this corresponds to 10 ns (including IPG, CRC, etc)
	local DELAY_BATCH_SIZE = 2048

	-- mempool with valid packets
    local memVal = memory.createMemPool({n = 4096, func=function(buf)
		buf:getEthernetPacket():fill{
            ethSrc = "02:03:04:05:06:07",
            ethDst = "02:03:04:05:06:08",
            ethType = 0x1234
		}
	end})

    -- mempool with invalid packets
    local memInv = memory.createMemPool({n = 4096, func=function(buf)
		buf:getEthernetPacket():fill{
			ethType = 1
		}
	end})

	local startupBufArray = memInv:bufArray(DELAY_BATCH_SIZE)
	local probingBufArray = memInv:bufArray(DELAY_BATCH_SIZE)

	local currentByteOffset = 0
	local probePacket = true

	print("Starting transmitter")
	-- startup
	local startupTimer = timer:new(1)
	while startupTimer:running() do
		startupBufArray:alloc(INV_SIZE)
		queue:send(startupBufArray)
	end
	
	-- send delay probing packet and wait
	local probingTimer = timer:new(1)
	while probingTimer:running() do
		probingBufArray:alloc(INV_SIZE)
		if probePacket then
			probingBufArray[1].ol_flags = bit.bor(probingBufArray[1].ol_flags, dpdk.PKT_TX_IEEE1588_TMST)
			probePacket = false
		else
			probingBufArray[1].ol_flags = bit.band(probingBufArray[1].ol_flags, bit.bnot(dpdk.PKT_TX_IEEE1588_TMST))
		end

		queue:send(probingBufArray)
		currentByteOffset = currentByteOffset + DELAY_BATCH_SIZE * (INV_SIZE + 24)
	end

	-- request TX timestamp from timestamping thread 
	barrierReadTs:wait()

	-- wait for timing information from other thread
	while mg.running() do
		probingBufArray:alloc(INV_SIZE)
		queue:send(probingBufArray)
		currentByteOffset = currentByteOffset + DELAY_BATCH_SIZE * (INV_SIZE + 24)

		local receivedValue = timingPipe:tryRecv(0)
		if receivedValue ~= nil then
			local data = ffi.cast("uint32_t*", receivedValue)
			currentSendingTime = data[1]
			break
		end
	end

	barrierStartReceive:wait()
	print(currentByteOffset)
	print(currentSendingTime)
	print(currentSendingTime + currentByteOffset * 0.08)

	while mg.running() do
		local receivedValue = packetPipe:tryRecv(0)
		if receivedValue ~= nil then
			-- send packets with delay
			local data = ffi.cast("struct received_packets*", receivedValue)

		else
			-- just send delay
			probingBufArray:alloc(INV_SIZE)
			queue:send(probingBufArray)
			currentByteOffset = currentByteOffset + DELAY_BATCH_SIZE * (INV_SIZE + 24)
		end
	end
end