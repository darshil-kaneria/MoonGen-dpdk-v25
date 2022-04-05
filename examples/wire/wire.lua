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
local dpdkc	 = require "dpdkc"

local wire = ffi.load("build/wire")

function configure(parser)
	parser:description("Simulates a wire. Forwards the packets from one port to the other with the same spacing and a configurable delay.")
	parser:argument("dev", "Devices to use."):args(2):convert(tonumber)
	parser:option("-d --delay", "The forwarding delay (in ms)."):convert(tonumber):default(10)
	parser:flag("-f --fast", "Optmizes for high packet rate, but decreases delay accuracy.")
	parser:flag("-m --measure", "Measure the time between calling the transmit function and the packet beeing transmitted on the wire. (Used as offset with the fast mode)")
	parser:option("-o --offset", "Offset to use between the SW timestamp and the transmitted packet when using fast mode."):convert(tonumber):default(0)
end

function master(args)
	if args.fast then
		dpdkc.rte_vect_set_max_simd_bitwidth(512)
	end

	local dev1 = device.config({port = args.dev[1], rxQueues = 1, txQueues = 1, numBufs = 7000000, txDescs = 4096, disableOffloads = args.fast})

	local dev2 = nil
	if args.dev[1] ~= args.dev[2] then
		dev2 = device.config({port = args.dev[2], rxQueues = 1, txQueues = 1, txDescs = 4096, disableOffloads = args.fast})
	else
		dev2 = dev1
	end
	device.waitForLinks()

	local linkSpeed = dev2:getLinkStatus().speed
	local INV_SIZE = 9000
	if(linkSpeed ~= 100000) then
		wire.setOtherRate(linkSpeed)
		INV_SIZE = 512
	end

	args.delay = args.delay * 1e6
	
	local barrierReadTs = barrier:new(2)
	local barrierStartReceive = barrier:new(2)

	local timingPipe = pipe:newFastPipe()
	local packetRing = pipe:newPacketRing(8388608)

    mg.startTask("transmitter", dev2:getTxQueue(0), barrierReadTs, timingPipe, barrierStartReceive, packetRing, args, INV_SIZE)
	if not args.fast then
		mg.startTask("timestamper", dev2, barrierReadTs, timingPipe, barrierStartReceive, packetRing)
	end
	mg.startTask("receiver", dev1:getRxQueue(0), barrierStartReceive, packetRing)	
    mg.waitForTasks()
end

ffi.cdef[[
	void receiver_loop(uint8_t port_id, uint16_t queue_id, struct rte_ring* packet_ring);
	void transmitter_loop(uint8_t port_id, uint16_t queue_id, struct rte_ring* packet_ring, struct mempool* pool, uint64_t currentByteOffset, uint64_t firstPacketTimestamp, uint64_t delay, bool fast, int64_t offset);
	uint64_t moongen_send_all_delay_offset_e810(uint8_t port_id, uint16_t queue_id, struct rte_mbuf** load_pkts, uint16_t num_pkts, struct mempool* pool, uint64_t currentByteOffset, uint64_t firstPacketTimestamp, uint64_t delay);
	void setOtherRate(uint64_t rate);
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

function transmitter(queue, barrierReadTs, timingPipe, barrierStartReceive, packetRing, args, INV_SIZE)
	local DELAY_BATCH_SIZE = 128

    -- mempool with invalid packets
    local memInv = memory.createMemPool({n = 8096, func=function(buf)
		buf:getEthernetPacket():fill{
			ethType = 1
		}
	end})

	local delayBufArray = memInv:bufArray(DELAY_BATCH_SIZE)

	local currentByteOffset = 0
	local firstPacketTimestamp = 0
	local firstPacketTimestampSW = 0
	local probePacket = true
	
	-- startup
	local startupTimer = timer:new(1)
	while startupTimer:running() do
		delayBufArray:alloc(INV_SIZE)
		queue:send(delayBufArray)
	end

	-- start receiver
	barrierStartReceive:wait()

	if not args.fast then
		-- send delay probing packet and wait
		local probingTimer = timer:new(1)
		while probingTimer:running() do
			delayBufArray:alloc(INV_SIZE)
			if probePacket then
				delayBufArray[1].ol_flags = bit.bor(delayBufArray[1].ol_flags, dpdk.PKT_TX_IEEE1588_TMST)
				probePacket = false

				if args.measure then
					firstPacketTimestampSW = dpdkc.ice_read_current_timer(queue.dev.id)
				end
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
	end

	if args.measure then
		local offset = ffi.cast("int64_t",firstPacketTimestamp)-ffi.cast("int64_t",firstPacketTimestampSW)
		print("Measured offset: "..tostring(offset))
		print("Terminate this script and set the offset parameter to this value when using fast mode")
	end

	-- start transmitter
	wire.transmitter_loop(queue.dev.id, queue.qid, packetRing.ring, memInv, currentByteOffset, firstPacketTimestamp, args.delay, args.fast or false, args.offset or 0);
end