"""
Implementation of an energy system modeling an abstract dispatchable supply of some medium.

This is particularly useful for testing, but can also be used to model any dispatchable
energy system or other equipment unit that produces energy in a given medium. The system
might still have a maximum power draw in a single time step, but can provide any fraction
of this to connected systems.
"""
mutable struct DispatchableSupply <: ControlledSystem
    uac::String
    controller::Controller
    sys_function::SystemFunction
    medium::Symbol

    input_interfaces::InterfaceMap
    output_interfaces::InterfaceMap

    max_power_profile::Profile
    temperature_profile::Union{Profile,Nothing}
    scaling_factor::Float64

    max_energy::Float64
    temperature::Temperature

    function DispatchableSupply(uac::String, config::Dict{String,Any})
        max_power_profile = Profile(config["max_power_profile_file_path"])
        temperature_profile = "temperature_profile_file_path" in keys(config) ?
                              Profile(config["temperature_profile_file_path"]) :
                              nothing
        medium = Symbol(config["medium"])
        register_media([medium])

        return new(
            uac, # uac
            controller_for_strategy( # controller
                config["strategy"]["name"], config["strategy"]
            ),
            sf_dispatchable_source, # sys_function
            medium, # medium
            InterfaceMap( # input_interfaces
                medium => nothing
            ),
            InterfaceMap( # output_interfaces
                medium => nothing
            ),
            max_power_profile, # max_power_profile
            temperature_profile, #temperature_profile
            config["scale"], # scaling_factor
            0.0, # max_energy
            nothing, # temperature
        )
    end
end

function output_values(unit::DispatchableSupply)::Vector{String}
    return ["OUT", "Max_Energy", "Temperature"]
end

function output_value(unit::DispatchableSupply, key::OutputKey)::Float64
    if key.value_key == "OUT"
        return unit.output_interfaces[key.medium].sum_abs_change * 0.5
    elseif key.value_key == "Max_Energy"
        return unit.max_energy
    elseif key.value_key == "Temperature"
        return unit.temperature
    end
    throw(KeyError(key.value_key))
end

function control(
    unit::DispatchableSupply,
    systems::Grouping,
    parameters::Dict{String,Any}
)
    move_state(unit, systems, parameters)
    unit.max_energy = unit.scaling_factor * Profiles.work_at_time(unit.max_power_profile, parameters["time"])
    set_max_energy!(unit.output_interfaces[unit.medium], unit.max_energy)
    if unit.temperature_profile !== nothing
        unit.temperature = Profiles.value_at_time(unit.temperature_profile, parameters["time"])
        unit.output_interfaces[unit.medium].temperature = unit.temperature
    end
end

function produce(unit::DispatchableSupply, parameters::Dict{String,Any}, watt_to_wh::Function)
    outface = unit.output_interfaces[unit.medium]
    # 1. @TODO: if disp. sources should be allowed to load storage systems, then the potential
    # must be handled here instead of being ignored
    # 2. we also ignore the temperature of the interface as the source defines that itself
    balance, _, _ = balance_on(outface, outface.target)
    if balance < 0.0
        add!(
            outface,
            min(abs(balance), unit.max_energy),
            unit.temperature
        )
    end
end

export DispatchableSupply