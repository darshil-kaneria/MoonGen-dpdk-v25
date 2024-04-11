local mg			= require "moongen"
local memory		= require "memory"
local device		= require "device"
local stats			= require "stats"
local histogram		= require "histogram"
local log			= require "log"
local timer			= require "timer"


function configure(parser)
	parser:argument("rxDev", "Device to receive from."):convert(tonumber)
	parser:option("-i --saveInterval", "Interval to create histogram files."):default(60):convert(tonumber)
end

function master(args)
	local rxDev = device.config{port = args.rxDev, dropEnable = false}
	device.waitForLinks()
	mg.startTask("counterSlave", rxDev:getRxQueue(0), args)
	mg.waitForTasks()
end


function counterSlave(queue, args)
	local rxCtr = stats:newDevRxCounter(queue.dev)
	-- to track if we lose packets on the NIC
	local pktCtr = stats:newPktRxCounter("Packets counted", "plain")
	local hist = histogram:create()
	local timer = timer:new(args.saveInterval)

	local bufs = memory.bufArray()
	while mg.running() do
		local rx = queue:tryRecv(bufs, 100)
		for i = 1, rx do
			local buf = bufs[i]
			local size = buf:getSize()
			hist:update(size)
			pktCtr:countPacket(buf)
		end
		bufs:free(rx)
		rxCtr:update()
		pktCtr:update()
		if timer:expired() then
			-- FIXME: this is really slow and might lose packets
			-- however, the histogram sucks and moving this to another thread would require a rewrite
			timer:reset()
			hist:print()
			hist:save("hist" .. time() .. ".csv")
		end
	end
	rxCtr:finalize()
	pktCtr:finalize()
	hist:print()
	hist:save("hist" .. time() .. ".csv")
	-- TODO: check the queue's overflow counter to detect lost packets
end

