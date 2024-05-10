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
		Entry{ RXdev=args.devs[1], TXdev=args.devs[2], loss=args.loss,
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
		lm.startTask(entry.loss and "forward_ge" or "forward",
			     deviceConfigs[entry.RXdev]:getRxQueue(0),
			     deviceConfigs[entry.TXdev]:getTxQueue(0),
			     entry.loss)
	end
	lm.waitForTasks()
end

ffi.cdef [[
void fwd(struct moonem_dev const* rx_dev,
         struct moonem_dev const* tx_dev);
]]
function forward (rxQueue, txQueue)
	local rx_dev = ffi.new("struct moonem_dev",
			       { port_id = rxQueue.id, queue_id = rxQueue.qid })
	local tx_dev = ffi.new("struct moonem_dev",
			       { port_id = txQueue.id, queue_id = txQueue.qid })
	C.fwd(rx_dev, tx_dev)
end

ffi.cdef [[
struct moonem_dev {
     uint8_t port_id;
     uint16_t queue_id;
};
void fwd_ge(struct moonem_dev const* rx_dev,
            struct moonem_dev const* tx_dev,
	    struct ge_model* model);
]]
local createGE
function forward_ge (rxQueue, txQueue, loss)
	local rx_dev = ffi.new("struct moonem_dev",
			       { port_id = rxQueue.id, queue_id = rxQueue.qid })
	local tx_dev = ffi.new("struct moonem_dev",
			       { port_id = txQueue.id, queue_id = txQueue.qid })
	local ge_model = createGE(loss)
	C.fwd_ge(rx_dev, tx_dev, ge_model)
end

ffi.cdef [[
struct ge_model {
     bool good;
     int p;
     int r;
     int h_;
     int k_;
};
int get_rand_max();
]]
function createGE (loss)
	local p  = loss[1] or 0
	local r  = loss[2] or 1 - p
	local h_ = loss[3] or 1
	local k_ = loss[4] or 0
	-- are the supplied probabilities valid?
	assert(p  >= 0.0 and p  <= 1.0, "Error: p ∉ [0,1]")
	assert(r  >= 0.0 and r  <= 1.0, "Error: r ∉ [0,1]")
	assert(h_ >= 0.0 and h_ <= 1.0, "Error: 1-h ∉ [0,1]")
	assert(k_ >= 0.0 and k_ <= 1.0, "Error: 1-k ∉ [0,1]")
	-- create the GE-model
	local model = ffi.new("struct ge_model")
	model.good = true
	local RAND_MAX = C.get_rand_max()
	model.p  = p  * RAND_MAX
	model.r  = r  * RAND_MAX
	model.h_ = h_ * RAND_MAX
	model.k_ = k_ * RAND_MAX
	return model
end
