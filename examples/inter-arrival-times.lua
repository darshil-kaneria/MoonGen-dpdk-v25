local mg		= require "moongen"
local memory	= require "memory"
local device	= require "device"
local ts		= require "timestamping"
local hist		= require "histogram"
local log		= require "log"
local timer		= require "timer"

function configure(parser)
	parser:argument("rxDev", "The device to receive from"):convert(tonumber)
end

function master(args)
	local rxDev = device.config{port = args.rxDev, dropEnable = false}
	device.waitForLinks()
	mg.startTask("rxThread", rxDev:getRxQueue(0), rxDev)
	mg.waitForTasks()
end

function rxThread(queue, rxDev)
	queue:enableTimestampsAllPackets()

	local total = 0
	local times = {}
	
	local bufs = memory.createBufArray()
	while mg.running() do
		local n = queue:recv(bufs)
		for i = 1, n do
			local ts = bufs[i]:getTimestamp(rxDev)
			times[#times + 1] = ts
		end
		total = total + n
		bufs:free(n)
	end

	local pkts = rxDev:getRxStats()
	local h = hist:create()
	local last
	for i, v in ipairs(times) do
		if last then
			local diff = v - last
			if diff > 0 then
				h:update(diff)
			end
		end
		last = v
	end

	h:print()
	h:save("histogram.csv")
	print(pkts, total)
	if pkts > total then
		log.warn("Lost packets: " .. pkts - total .. " (this can happen if the NIC still receives data after this script stops the receive loop)")
	end
end
