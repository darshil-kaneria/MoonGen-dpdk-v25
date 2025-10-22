local mod = {}

local ffi    = require "ffi"
local dpdkc  = require "dpdkc"
local log    = require "log"

ffi.cdef [[
    enum loss_type {
        NONE,
        UNIFORM,
        GE,
        NETEM
    };

    struct moonem_config {
        uint64_t delay;
        uint64_t rate;
        uint64_t capacity;
        uint64_t loss_seed;
        enum loss_type loss_type;
        uint64_t loss;
        uint64_t loss_model_parameters[8];
    };

    int applyLoss_export(uint16_t rx, struct rte_mbuf** bufs, struct rte_mbuf** bufs_send, uint64_t* loss_state, struct moonem_config config);
]]

local loss_model = {}
mod.loss_model = loss_model
loss_model.__index = loss_model

function scale_to_uint64(val)
	if val == 1 then
		return ffi.new("uint64_t", 0xFFFFFFFFFFFFFFFFULL)
	else
		return ffi.new("uint64_t", 2^64 * val)
	end
end

function mod.new_uniform(seed, loss)
    local loss_scaled = scale_to_uint64(loss / 100)

    local moonem_config = ffi.new("struct moonem_config", {
        delay = 0,
        rate = 0,
        capacity = 0,
        seed = seed,
        loss_type = ffi.C.UNIFORM,
        loss = loss_scaled
    })

    return setmetatable({
        moonem_config = moonem_config,
        state = ffi.new("uint64_t[2]")
	}, loss_model)
end

function mod.new_ge(seed, parameters)
    local moonem_config = ffi.new("struct moonem_config", {
        delay = 0,
        rate = 0,
        capacity = 0,
        seed = seed,
        loss_type = ffi.C.GE,
        loss = 0
    })

    local parameter_count = #parameters
    if parameter_count < 1 then
        parameters[1] = 0;
    end
    if parameter_count < 2 then
        parameters[2] = 100 - parameters[1];
    end
    if parameter_count < 3 then
        parameters[3] = 100;
    end
    if parameter_count < 4 then
        parameters[4] = 0;
    end

    for i = 1,#parameters do
        moonem_config.loss_model_parameters[i-1] = scale_to_uint64(parameters[i] / 100)
    end

    return setmetatable({
        moonem_config = moonem_config,
        state = ffi.new("uint64_t[2]")
	}, loss_model)
end

function mod.new_netem(seed, parameters)
    local moonem_config = ffi.new("struct moonem_config", {
        delay = 0,
        rate = 0,
        capacity = 0,
        seed = seed,
        loss_type = ffi.C.NETEM,
        loss = 0,
    })

    if #parameters ~= 5 then
        log:fatal("All five netem loss model parameters are required!")
    end

    for i = 1,#parameters do
        if parameters[i] < 0 or parameters[i] > 100 then
            log:fatal("All netem loss model parameters need to be in [0, 100]")
        end
    end

    local p13 = 1
    local p31 = 2
    local p32 = 3
    local p23 = 4
    local p14 = 5

    local new_args = {}
    new_args[1] = 100 - parameters[p13] - parameters[p14]
    new_args[2] = 100 - parameters[p14]
    
    new_args[3] = 100 - parameters[p23];
    new_args[4] = parameters[p23];
    
    new_args[5] = 100 - parameters[p31] - parameters[p32];
    new_args[6] = parameters[p32];

    new_args[7] = 0;
    new_args[8] = 100;

    for i = 1,#new_args do
        moonem_config.loss_model_parameters[i-1] = scale_to_uint64(new_args[i]/100)
    end

    return setmetatable({
        moonem_config = moonem_config,
        state = ffi.new("uint64_t[2]")
	}, loss_model)
end

function loss_model:apply_loss(packets_in, packets_in_count, packets_out)
    return ffi.C.applyLoss_export(packets_in_count, packets_in.array, packets_out.array, self.state, self.moonem_config)
end

return mod