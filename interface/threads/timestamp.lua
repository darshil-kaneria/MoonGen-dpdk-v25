local hist   = require "histogram"
local mg     = require "moongen"
local timer  = require "timer"
local ts     = require "timestamping"

local Flow  = require "flow"

local thread = { flows = {} }

function thread.prepare(flows, devices)
	local used_rx_devs = {}
	local used_tx_devs = {}
	for _,flow in ipairs(flows) do
		if flow:option "timestamp" then
			local rx = flow:property("rx")[1]
			for _,tx in ipairs(flow:property "tx") do
				table.insert(thread.flows, flow:clone{ tx_dev = tx, rx_dev = rx })
				used_rx_devs[rx] = true
				used_tx_devs[tx] = true
			end
		end
	end

	for dev,_ in pairs(used_rx_devs) do
		devices:reserveRx(dev)
	end
	for dev,_ in pairs(used_tx_devs) do
		devices:reserveTx(dev)
	end
end

function thread.start(devices, ...)
	local rxQueues = {}
	local txQueues = {}

	for i,flow in ipairs(thread.flows) do
		txQueues[flow:property "tx_dev"] = txQueues[flow:property "tx_dev"] or devices:txQueue(flow:property "tx_dev")
		rxQueues[flow:property "rx_dev"] = rxQueues[flow:property "rx_dev"] or devices:rxQueue(flow:property "rx_dev")
		flow:setProperty("txQueue", txQueues[flow:property "tx_dev"])
		flow:setProperty("rxQueue", rxQueues[flow:property "rx_dev"])

		thread.flows[i] = flow
	end

	if #thread.flows > 0 then
		mg.startSharedTask("__INTERFACE_TIMESTAMPING", thread.flows, ...)
	end
end

local function timestampThread(flows, directory)
	local hists, timestampers = {}, {}

	local isUdp = false
	for i,v in ipairs(flows) do
		if v.packet.proto == "Udp" then
			isUdp = true
		end
	end
	for i,v in ipairs(flows) do
		assert((v.packet.proto == "Udp") == isUdp, "Timestamping can only be activated for UDP or Ethernet packets, but not both") 
	end

	for i,v in ipairs(flows) do
		local flow = Flow.restore(v)
		flows[i] = flow
		hists[i] = hist()

		local minLength = isUdp and 84 or 68
		if flow:packetSize() < minLength then
			flow.packet.fillTbl.pktLength = minLength
		end
	end

	for _,flow in ipairs(flows) do
		local rx = flow:property("rx")[1]
		timestampers[rx] = timestampers[rx] or ts:newTimestamper(flow:property "txQueue", flow:property "rxQueue", nil, isUdp)
	end

	local rateLimit = timer:new(0.001)
	local activeFlows = 1
	while mg.running() and activeFlows > 0 do
		activeFlows = 0
		for i,flow in ipairs(flows) do
			if not flow:property("counter"):isZero() then
				activeFlows = activeFlows + 1
				timestampers[flow:property("rx")[1]].txDev = flow:property("txQueue").dev
				timestampers[flow:property("rx")[1]].txQueue = flow:property("txQueue")
				hists[i]:update(timestampers[flow:property("rx")[1]]:measureLatency(
					flow:packetSize(), function(buf)
						if flow.isDynamic then
							flow:fillUpdateBuf(buf)
						else
							flow:fillBuf(buf)
						end

						if isUdp then
							local pkt = buf:getUdpPtpPacket()
							pkt.ptp:setMessageType()
							pkt.ptp:setVersion()
						else
							local pkt = buf:getPtpPacket()
							pkt.eth:setType(0x88f7)
						end
					end
				))
			end
		end
		rateLimit:wait()
		rateLimit:reset()
	end

	for i,flow in ipairs(flows) do
		hists[i]:save(string.format("%s/%s_%d-%d_%d.csv", directory,
			flow.proto.name, flow:option "uid", flow:property("txQueue").id, flow:property("rxQueue").id))
	end
end

__INTERFACE_TIMESTAMPING = timestampThread -- luacheck: globals __INTERFACE_TIMESTAMPING
return thread
