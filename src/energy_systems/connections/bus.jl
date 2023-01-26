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
    uac :: String
    controller :: Controller
    sys_function :: SystemFunction
    medium :: MediumCategory

    input_interfaces :: Vector{SystemInterface}
    output_interfaces :: Vector{SystemInterface}

    input_priorities :: Vector{String}
    output_priorities :: Vector{String}

    storage_space :: Float64
    remainder :: Float64

    function Bus(uac :: String, config :: Dict{String, Any})
        medium = getproperty(EnergySystems, Symbol(config["medium"]))
        return new(
            uac, # uac
            controller_for_strategy( # controller
                config["strategy"]["name"], config["strategy"]
            ),
            sf_bus, # sys_function
            medium, # medium
            [], # input_interfaces
            [], # output_interfaces,
            config["input_priorities"],
            config["production_refs"],
            0.0, # storage_space
            0.0 # remainder
        )
    end
end

function reset(unit :: Bus)
    for inface in unit.input_interfaces
        reset!(inface)
    end
    for outface in unit.output_interfaces
        reset!(outface)
    end
    unit.storage_space = 0.0
    unit.remainder = 0.0
end

"""
    produce(unit, parameters, watt_to_wh)

Bus-specific implementation of produce.

The production of a bus does not generate or consume energy, but calculates the potential
of storage systems connected to the bus and saves that value, which is later required to
distinguish between the actual demand of consuming energy systems and the potential to load
storage with excess energy.

See also [`produce`](@ref)
"""
function produce(unit :: Bus, parameters :: Dict{String, Any}, watt_to_wh :: Function)
    for outface in unit.output_interfaces
        if outface.target.sys_function === sf_storage
            unit.storage_space += outface.target.capacity - outface.target.load
        end
    end
end

function balance(unit :: Bus) :: Float64
    balance = 0.0

    for inface in unit.input_interfaces
        balance += inface.balance
    end

    for outface in unit.output_interfaces
        balance += outface.balance
    end

    return balance + unit.remainder
end

function balance_on(
    interface :: SystemInterface,
    unit :: Bus
) :: Tuple{Float64, Float64, Temperature}
    highest_demand_temp = -1e9
    for interface in unit.output_interfaces
        if interface.temperature !== nothing && interface.balance < 0
            highest_demand_temp = (
                interface.temperature > highest_demand_temp
                ? interface.temperature
                : highest_demand_temp
            )
        end
    end

    return (
        balance(unit),
        -unit.storage_space,
        highest_demand_temp <= -1e9 ? nothing : highest_demand_temp
    )
end

"""
    distribute!(unit)

Bus-specific implementation of distribute!.

This implementation checks the balance of the bus (which includes the so-called remainder),
then sets all interfaces back to zero and saves the balance as the current remainder. This
has the intention that calling this method will distribute the energy without changing the
energy balance of the bus. That way the method can be called at any point after the balance
might have changed and should always consider the correct energy balance regardless of when
or how often it was called.
"""
function distribute!(unit :: Bus)
    remainder = balance(unit)

    for inface in unit.input_interfaces
        set!(inface, 0.0)
    end

    for outface in unit.output_interfaces
        set!(outface, 0.0)
    end

    unit.remainder = remainder
end

function output_values(unit :: Bus) :: Vector{String}
    return ["Balance"]
end

function output_value(unit :: Bus, key :: OutputKey) :: Float64
    if key.value_key == "Balance"
        return balance(unit)
    end
    throw(KeyError(key.value_key))
end

export Bus