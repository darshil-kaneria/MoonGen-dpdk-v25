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

function configure(parser)
	parser:argument("dev", "Devices to use: RX-dev TX-dev"):
		args(2):convert(tonumber)
	parser:option("-l --loss", "Loss probabilities [0.0,1.0]. " ..
		      "Gilbert-Elliot: p [r [1-h [1-k]]]"):
		args("+"):convert(tonumber):default({0})
	parser:option("-n --numBufs", "NumBufs of the RX-Dev. " ..
		      "(use hugepages to set more)."):
		convert(tonumber):default(2047)
	parser:flag("-v --verbose", "Print device stats to stdout.")
	return parser:parse()
end

local configureDevices
local printStats
local startTasks

function master(args)
	local devices = configureDevices(args.dev[1], args.dev[2], args.numBufs)
	if args.verbose then                           
	        -- Print send/recv stats while running 
	        stats.startStatsTask{rxDevices = {devices[1]},
				     txDevices = {devices[2]}}
	end                                            
	startTasks(devices, args.dev, args.loss)
	printStats(args.dev, devices)
end

function configureDevices (rxDev, txDev, numBufs)
	local devices = {}
	-- higher values for rx/tx-Descs (e.g. txDescs = 4096) don't work on some
	-- devices. Therefore, they are left at the default value.
	devices[1] = device.config{port = rxDev,
				   rxQueues = 1, txQueues = 1, 
				   numBufs = numBufs, -- rxDescs = 4096,
				   dropEnable = false}
	devices[2] = device.config{port = txDev,
				   rxQueues = 1, txQueues = 1}
	device.waitForLinks()
	return devices
end

function printStats (devs, devices)
	log:info("Stats for: dev %d -> dev %d", devs[1], devs[2])
	local nRecv = devices[1]:getRxStats()
	local nSent = devices[2]:getTxStats()
	log:info("Device %d received %d pkts", devs[1], nRecv)
	log:info("Device %d sent %d pkts", devs[2], nSent)
	log:info("Loss: %g %%", (1 - nSent/nRecv) * 100)
end

function startTasks (devices, devs, loss)
	log:info("Forward: dev %d -> dev %d", devs[1], devs[2])
	lm.startTask("forward_ge",
		     devices[1]:getRxQueue(0), devices[2]:getTxQueue(0),
		     loss)
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
