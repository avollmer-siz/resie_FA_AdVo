"""
Implementation of an energy system that models the demand consumers in a building require.

As the simulation does not encompass demand calculations, this is usually taken from other
tools that calculate the demand before a simulation of the energy systems is done. These
profiles usually are normalized to some degree, therefore Demand instances require a scaling
factor to turn the relative values to absolute values of required energy.
"""
mutable struct Demand <: ControlledSystem
    uac :: String
    controller :: Controller
    sys_function :: SystemFunction
    medium :: MediumCategory

    input_interfaces :: InterfaceMap
    output_interfaces :: InterfaceMap

    energy_profile :: Profile
    temperature_profile :: Union{Profile, Nothing}
    scaling_factor :: Float64

    last_load :: Float64
    last_temperature :: Temperature

    function Demand(uac :: String, config :: Dict{String, Any})
        energy_profile = Profile(config["energy_profile_file_path"])
        temperature_profile = "temperature_profile_file_path" in keys(config) ?
            Profile(config["temperature_profile_file_path"]) :
            nothing
        medium = getproperty(EnergySystems, Symbol(config["medium"]))

        return new(
            uac, # uac
            controller_for_strategy( # controller
                config["strategy"]["name"], config["strategy"]
            ),
            sf_fixed_sink, # sys_function
            medium, # medium
            InterfaceMap( # input_interfaces
                medium => nothing
            ),
            InterfaceMap( # output_interfaces
                medium => nothing
            ),
            energy_profile, # energy_profile
            temperature_profile, #temperature_profile
            config["scale"], # scaling_factor
            0.0, # last_load
            nothing, # last_temperature
        )
    end
end

function output_values(unit :: Demand) :: Vector{String}
    return ["IN", "Load"]
end

function output_value(unit :: Demand, key :: OutputKey) :: Float64
    if key.value_key == "IN"
        return unit.input_interfaces[key.medium].sum_abs_change * 0.5
    elseif key.value_key == "Load"
        return unit.last_load
    end
    raise(KeyError(key.value_key))
end

function control(
    unit :: Demand,
    systems :: Grouping,
    parameters :: Dict{String, Any}
)
    move_state(unit, systems, parameters)
    unit.last_load = unit.scaling_factor * Profiles.work_at_time(unit.energy_profile, parameters["time"])
    if unit.temperature_profile !== nothing
        unit.last_temperature = Profiles.power_at_time(unit.temperature_profile, parameters["time"])
    end
end

function produce(unit :: Demand, parameters :: Dict{String, Any}, watt_to_wh :: Function)
    inface = unit.input_interfaces[unit.medium]
    sub!(inface, unit.last_load, unit.last_temperature)
end

export Demand