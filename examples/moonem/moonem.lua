-- MoonEm: Network Emulation with MoonGen

-- import modules
local lm     = require "libmoon"
local device = require "device"
local stats  = require "stats"
local log    = require "log"
local memory = require "memory"

local ffi = require "ffi"
local C   = ffi.C

-- no more external access after this point
_ENV = nil

function configure (parser)
	parser:option("-d --devs", "Devices to use: <RX-dev> <TX-dev>"):
		args(2):convert(tonumber)
	parser:option("-m --model", "Packet loss model. " ..
		      "Valid choices: ge|netem"):
		args(1):default("ge")
	parser:option("-l --loss", "Loss probabilities [0.0,1.0]. " ..
		      "Gilbert-Elliot: p [r [1-h [1-k]]]"):
		args("+"):convert(tonumber):default({0})
	parser:option("-n --numBufs", "NumBufs of the RX-Dev. " ..
		      "(use hugepages to set more)."):
		convert(tonumber):default(2047)
	parser:option("-c --config", "Read configuration from file"):
		args(1):default(nil)
	parser:flag("-v --verbose", "Print device stats to stdout.")
	return parser:parse()
end

local startTasks
local printStats

local entries = {}

function master (args)
	if args.devs then
		-- Add config-entry for CLI config
		Entry{ RXdev=args.devs[1], TXdev=args.devs[2],
		       model=args.model, loss=args.loss,
		       RXnumBufs=args.numBufs}
	end
	if args.config then
		-- Add entries from config-file
		dofile(args.config)
	end
	-- Configure all devices
	local configurator = newConfigurator()
	local deviceConfigs = {}
	for i, entry in ipairs(entries) do
		RXconfig, TXconfig = configurator(entry)
		if RXconfig then deviceConfigs[entry.RXdev] = RXconfig end
		if TXconfig then deviceConfigs[entry.TXdev] = TXconfig end
	end
	device.waitForLinks()
	
	if args.verbose then                           
	        -- Print send/recv stats while running
		local RXdevs = {}
		local TXdevs = {}
		for _, entry in ipairs(entries) do
			RXdevs[#RXdevs + 1] = deviceConfigs[entry.RXdev]
			TXdevs[#TXdevs + 1] = deviceConfigs[entry.TXdev]
		end
	        stats.startStatsTask{rxDevices = RXdevs,
				     txDevices = TXdevs}
	end                                            

	startTasks(entries, deviceConfigs)

	if not args.verbose then
		printStats(entries, deviceConfigs)
	end
end

function Entry (entry)
	assert(entry.RXdev, "Error in Entry: RXdev required.")
	assert(entry.TXdev, "Error in Entry: TXdev required.")
	entries[#entries + 1] = entry
end

function newConfigurator ()
	local configuredDevs = {RX={}, TX={}} -- every dev configured only once
	return function (entry)
		assert(not configuredDevs.RX[entry.RXdev],
		       "Error: RXdev %d already configured as RX.", entry.RXdev)
		assert(not configuredDevs.TX[entry.TXdev],
		       "Error: TXdev %d already configured as TX.", entry.TXdev)

		local function configure (dev, numBufs)
			-- Careful, higher rx/tx-Descs values (e.g. txDescs=4096) cause
			-- issues on some devices.
			return device.config{port = dev,
					     rxQueues = 1,
					     txQueues = 1,
					     numBufs = numBufs,
					     -- rxDescs = 4096,
					     dropEnable = false}
		end
		local RXdev = not configuredDevs[entry.RXdev] and configure(entry.RXdev, entry.RXnumBufs)
		local TXdev = not configuredDevs[entry.TXdev] and configure(entry.TXdev, entry.TXnumBufs)
		configuredDevs.RX[entry.RXdev] = true
		configuredDevs.TX[entry.TXdev] = true
		configuredDevs[entry.RXdev] = true
		configuredDevs[entry.TXdev] = true
		return RXdev, TXdev
	end
end

function printStats (entries, deviceConfigs)
	for _, entry in ipairs(entries) do
		log:info("%d -> %d", entry.RXdev, entry.TXdev)
		local nRecv = deviceConfigs[entry.RXdev]:getRxStats()
		local nSent = deviceConfigs[entry.TXdev]:getTxStats()
		log:info("%d received %d pkts", entry.RXdev, nRecv)
		log:info("%d sent %d pkts", entry.TXdev, nSent)
		log:info("Loss: %g %%", (1 - nSent/nRecv) * 100)
	end
end

function startTasks (entries, deviceConfigs)
	for _, entry in ipairs(entries) do
		log:info("Forward: dev %d -> dev %d", entry.RXdev, entry.TXdev)
		lm.startTask(entry.loss and "forward_loss" or "forward",
			     deviceConfigs[entry.RXdev]:getRxQueue(0),
			     deviceConfigs[entry.TXdev]:getTxQueue(0),
			     entry.model, entry.loss)
	end
	lm.waitForTasks()
end

ffi.cdef [[
void fwd(struct moonem_dev const* rx,
         struct moonem_dev const* tx);
]]
function forward (rxQueue, txQueue)
	local rx = ffi.new("struct moonem_dev",
			   { port_id = rxQueue.id, queue_id = rxQueue.qid })
	local tx = ffi.new("struct moonem_dev",
			   { port_id = txQueue.id, queue_id = txQueue.qid })
	C.fwd(rx, tx)
end

ffi.cdef [[
struct moonem_dev {
     uint8_t port_id;
     uint16_t queue_id;
};
enum loss_model { ge, netem };
void fwd_loss(struct moonem_dev const* rx,
              struct moonem_dev const* tx,
              enum loss_model model_type,
	      size_t const len,
              double const* prob);
]]
function forward_loss (rxQueue, txQueue, model, loss)
	local rx = ffi.new("struct moonem_dev",
			   { port_id = rxQueue.id, queue_id = rxQueue.qid })
	local tx = ffi.new("struct moonem_dev",
			   { port_id = txQueue.id, queue_id = txQueue.qid })
	local prob = ffi.new("double const[?]", #loss, loss)
	C.fwd_loss(rx, tx,
		   model or "ge",
		   #loss, prob)
end
