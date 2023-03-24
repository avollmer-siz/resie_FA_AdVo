using ResumableFunctions

"""
Utility struct to contain the connections, input/output priorities and other related data
for bus systems.
"""
Base.@kwdef mutable struct ConnectionMatrix
    input_order::Vector{String}
    output_order::Vector{String}
    storage_loading::Union{Nothing,Vector{Vector{Bool}}}

    function ConnectionMatrix(config::Dict{String,Any})
        input_order = []
        output_order = [String(u) for u in config["production_refs"]]
        storage_loading = nothing

        if "connection_matrix" in keys(config)
            if "input_order" in keys(config["connection_matrix"])
                input_order = [String(u) for u in config["connection_matrix"]["input_order"]]
            end

            if "output_order" in keys(config["connection_matrix"])
                output_order = [String(u) for u in config["connection_matrix"]["output_order"]]
            end

            if "storage_loading" in keys(config["connection_matrix"])
                storage_loading = []
                for row in config["connection_matrix"]["storage_loading"]
                    vec = [Bool(v) for v in row]
                    push!(storage_loading, vec)
                end
            end
        end

        return new(
            input_order,
            output_order,
            storage_loading,
        )
    end
end

"""
Imnplementation of a bus energy system for balancing multiple inputs and outputs.

This energy system is both a possible real system (mostly for electricity) as well as a
necessary abstraction of the model. The basic idea is that one or more energy systems feed
energy of the same medium into a bus and one or more energy systems draw that energy from
the bus. A bus with only one input and only one output can be replaced with a direct
connection between both systems.

The function and purpose is described in more detail in the accompanying documentation.
"""
Base.@kwdef mutable struct Bus <: ControlledSystem
    uac::String
    controller::Controller
    sys_function::SystemFunction
    medium::Symbol

    input_interfaces::Vector{SystemInterface}
    output_interfaces::Vector{SystemInterface}
    connectivity::ConnectionMatrix

    remainder::Float64

    function Bus(uac::String, config::Dict{String,Any})
        medium = Symbol(config["medium"])
        register_media([medium])

        return new(
            uac, # uac
            controller_for_strategy( # controller
                config["strategy"]["name"], config["strategy"]
            ),
            sf_bus, # sys_function
            medium, # medium
            [], # input_interfaces
            [], # output_interfaces,
            ConnectionMatrix(config),
            0.0 # remainder
        )
    end
end

function reset(unit::Bus)
    for inface in unit.input_interfaces
        reset!(inface)
    end
    for outface in unit.output_interfaces
        reset!(outface)
    end
    unit.remainder = 0.0
end

"""
    balance_nr(unit, caller)

Variant of [`balance`](@ref) that includes other connected bus systems and their energy
balance, but does so in a non-recursive manner such that any bus in the chain of connected
bus systems is only considered once.
"""
function balance_nr(unit::Bus, caller::Bus)::Float64
    balance = 0.0

    for inface in unit.input_interfaces   # supply
        if inface.source == caller
            continue
        end

        if isa(inface.source, Bus)  
            InterfaceInfo = balance_nr(inface.source, unit)
            balance_supply = max(InterfaceInfo, inface.balance)
            if balance_supply < 0.0
                continue
            end
        else
            balance_supply = balance_on(inface, inface.source).balance
        end
        balance += balance_supply
    end

    for outface in unit.output_interfaces  # demand
        if outface.target == caller
            continue
        end

        if isa(outface.target, Bus)
            InterfaceInfo = balance_nr(outface.target, unit)
            balance_demand = min(InterfaceInfo, outface.balance)
            if balance_demand > 0.0
                continue
            end
        else
            balance_demand = balance_on(outface, outface.target).balance
        end
        balance += balance_demand

    end

    return  balance + unit.remainder
end

"""
    balance_direct(unit)

Energy balance on a bus system without considering any other connected bus systems.
"""
function balance_direct(unit::Bus)::Float64
    balance = 0.0

    for inface in unit.input_interfaces  # supply
        if isa(inface.source, Bus)
            continue
        else
            balance += balance_on(inface, inface.source).balance
        end
    end

    for outface in unit.output_interfaces  # demand
        if isa(outface.target, Bus)
            continue
        else
            balance += balance_on(outface, outface.target).balance
        end
    end

    return balance + unit.remainder
end

function balance(unit::Bus)::Float64
    # we can use the non-recursive version of the method as a bus will never
    # be connected to itself... right?
    return balance_nr(unit, unit)
end

function balance_on(
    interface::SystemInterface,
    unit::Bus
)::NamedTuple{}
    highest_demand_temp = -1e9
    storage_space = 0.0
    input_index = nothing
    caller_is_input = false   # == true if interface is input of unit (caller puts energy in unit); 
                              # == false if interface is output of unit (caller gets energy from unit)
    energy_potential_outputs = 0.0
    energy_potential_inputs = 0.0

    # find the index of the input on the bus. if the method was called on an output,
    # the input index will remain as nothing
    # Attention: unit.connectivity.input_order is mandatory to have a list of all inputs! 
    #            Maybe change to unit.output_interfaces in future versions or set any order in 
    #            connectivity.input_order if nothing is given in the input file?
    for (idx, input_uac) in pairs(unit.connectivity.input_order)
        if input_uac == interface.source.uac
            input_index = idx
            caller_is_input = true
            break
        end
    end

    # helper function to get corresponding output index in connectivity matrix from index of output interface
    # ToDo: Maybe avoid this function and make shure that the order of output_interfaces in unit is the 
    #       same as specified in the connectivity matrix at the beginning of the simulation?
    function get_connectivity_output_index(unit, output_interface_index)::Int
        output_interface_uac = unit.output_interfaces[output_interface_index].target.uac
        for  (idx,connectivity_output_uac) in pairs(unit.connectivity.output_order)
            if connectivity_output_uac == output_interface_uac
                return idx
            end
        end
    end

    # iterate through outfaces to get storage loading potential
    for (idx, outface) in pairs(unit.output_interfaces)
        if outface.target.sys_function === sf_bus
            InterfaceInfo = balance_on(outface, outface.target)
            balance = InterfaceInfo.balance
            storage_potential = InterfaceInfo.storage_potential
            energy_potential = outface.sum_abs_change > 0.0 ? 0.0 : InterfaceInfo.energy_potential
            temperature = InterfaceInfo.temperature
        else
            balance = outface.balance
            temperature = outface.temperature
            energy_potential = (outface.max_energy === nothing || outface.sum_abs_change > 0.0 ) ? 0.0 : outface.max_energy
            if (
                outface.target.sys_function === sf_storage
                &&
                (
                    input_index === nothing
                    || unit.connectivity.storage_loading === nothing
                    || unit.connectivity.storage_loading[input_index][get_connectivity_output_index(unit, idx)]
                )
            )
                InterfaceInfo = balance_on(outface, outface.target)
                storage_potential = InterfaceInfo.storage_potential
            else
                storage_potential = 0.0
            end
        end

        if temperature !== nothing && balance < 0
            highest_demand_temp = (
                temperature > highest_demand_temp ? temperature : highest_demand_temp
            )
        end

        storage_space += storage_potential
        energy_potential_outputs += energy_potential
    end

    if caller_is_input == false && interface.sum_abs_change == 0.0 # also need to check inputs of unit in order to sum up potential_energy_inputs, but only if necessary
        for (idx, inface) in pairs(unit.input_interfaces)
            if inface.source.sys_function === sf_bus
                InterfaceInfo = balance_on(inface, inface.source)
                energy_potential = inface.sum_abs_change > 0.0 ? 0.0 : InterfaceInfo.energy_potential
            else
                energy_potential = (inface.max_energy === nothing || inface.sum_abs_change > 0.0 ) ? 0.0 : inface.max_energy
            end
            energy_potential_inputs += energy_potential
        end
    end
    # ToDo: consider connectivity matrix? For now, only the load and produce of storages are regulated 
    #       in the connectivity matrix. For storages, max_energy is set to 0.0 in their control step, so
    #       this needs not to be considered here for energy_potential.
    # Note: The balance is used for actual balance while energy_potential and storage_potential are potential
    #       energies that could be given or taken. For now, the potentials are only written in the control
    #       step of fixed or dispatchable sinks and sources (including grid and PV) but not for transformers. 
    #       If an energy system connected to the interface of balane_on() has already been produces, the 
    #       max_energy is ignored and set to zero by balance_on(). Then, only the balance can be used in the 
    #       calling energy system to avoid double counting.
    
    return (
            balance = balance(unit),
            storage_potential = storage_space,
            energy_potential = interface.sum_abs_change > 0.0 ? 0.0 : (caller_is_input ? energy_potential_outputs : energy_potential_inputs) ,
            temperature = (highest_demand_temp <= -1e9 ? nothing : highest_demand_temp)
            )
end

# """
#     for x in bus_infaces(bus)

# Iterator over the input interfaces that connect the given bus to other busses.
# """
@resumable function bus_infaces(unit::Bus)
    # for every input UAC (to ensure the correct order)...
    for input_uac in unit.connectivity.input_order
        # ...seach corresponding input inferface by...
        for inface in unit.input_interfaces
            # ...making sure the input interface is of type bus...
            if inface.source.sys_function === sf_bus
                # ...and the source's UAC matches the one in the input_priority.
                if inface.source.uac === input_uac
                    @yield inface
                    break # we found the match, so we can break out of the inner loop.
                end
            end
        end
    end
end

# """
#     for x in bus_outfaces(bus)

# Iterator over the output interfaces that connect the given bus to other busses.
# """
@resumable function bus_outfaces(unit::Bus)
    # for every output UAC (to ensure the correct order)...
    for output_uac in unit.connectivity.output_order
        # ...seach corresponding output inferface by...
        for outface in unit.output_interfaces
            # ...making sure the output interface is of type bus...
            if outface.target.sys_function === sf_bus
                # ...and the target's UAC matches the one in the output_priority.
                if outface.target.uac === output_uac
                    @yield outface
                    break # we found the match, so we can break out of the inner loop.
                end
            end
        end
    end
end

"""
    distribute!(unit)

Bus-specific implementation of distribute!.

This moves the energy from connected energy system from supply to demand systems both
on the bus directly as well as taking other bus systems into account. This allows busses
to be connected in chains (but not loops) and "communicate" the energy across. The method
implicitly requires that each bus on the chain is called with distribute!() in a specific
order, which is explained in more detail in the documentation. Essentially it starts from
the leaves of the chain and progresses to the roots.
"""
function distribute!(unit::Bus)
    balance = balance_direct(unit)

    # reset all non-bus input interfaces
    for inface in unit.input_interfaces
        if inface.source.sys_function !== sf_bus
            set!(inface, 0.0, inface.temperature)
        end
    end

    # reset all non-bus output interfaces
    for outface in unit.output_interfaces
        if outface.target.sys_function !== sf_bus
            set!(outface, 0.0, outface.temperature)
        end
    end

    # distribute to outgoing busses according to output priority
    if balance > 0.0
        for outface in bus_outfaces(unit)
            if balance > abs(outface.balance)
                balance += outface.balance
                set!(outface, 0.0, outface.temperature)
            else
                add!(outface, balance, outface.temperature)
                balance = 0.0
            end
        end
    end

    # write any remaining demand into input bus interfaces (if any) according to input
    # priority, however as available supply is not considered (as this happens implicitly
    # through output priorities of the input bus), this effectively writes all the
    # remaining demand into the first input according to the priority.
    if balance < 0.0
        for inface in bus_infaces(unit)
            add!(inface, balance)
            balance = 0.0
        end
    end

    # if there is a balance unequal zero remaining, this happens either because there is
    # no input bus or the balance was positive and is thus not communicated "backwards" to
    # the input bus. the balance is saved in the remainder so it is available for further
    # balance calculations
    unit.remainder = balance
end

function output_values(unit::Bus)::Vector{String}
    return ["Balance"]
end

function output_value(unit::Bus, key::OutputKey)::Float64
    if key.value_key == "Balance"
        return balance(unit)
    end
    throw(KeyError(key.value_key))
end

export Bus