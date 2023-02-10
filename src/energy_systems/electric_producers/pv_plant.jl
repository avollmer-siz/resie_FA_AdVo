"""
Implementation of a photovoltaic (PV) power plant.

For the moment this remains a simple implementation approximating a PV plant with a sinoid
function. As the calculation of potential PV power is done outside the simulation by a
seperate tool, a proper implemention would mostly just load a profile and consider only
some system losses. The amplitude parameter is a scaling factor, but is not an average
power value.
"""
mutable struct PVPlant <: ControlledSystem
    uac :: String
    controller :: Controller
    sys_function :: SystemFunction

    input_interfaces :: InterfaceMap
    output_interfaces :: InterfaceMap

    energy_profile :: Profile
    scaling_factor :: Float64

    supply :: Float64

    function PVPlant(uac :: String, config :: Dict{String, Any})

        # load energy profile from path
        energy_profile = Profile(config["energy_profile_file_path"])

        return new(
            uac, # uac
            controller_for_strategy( # controller
                config["strategy"]["name"], config["strategy"]
            ),
            sf_fixed_source, # sys_function
            InterfaceMap(), # input_interfaces
            InterfaceMap( # output_interfaces
                m_e_ac_230v => nothing
            ),
            energy_profile, # energy_profile
            config["scale"], # scaling_factor
            0.0 # supply
        )
    end
end

function output_values(unit :: PVPlant) :: Vector{String}
    return ["OUT", "Supply"]
end

function output_value(unit :: PVPlant, key :: OutputKey) :: Float64
    if key.value_key == "OUT"
        return unit.output_interfaces[key.medium].sum_abs_change * 0.5
    elseif key.value_key == "Supply"
        return unit.supply
    end
    throw(KeyError(key.value_key))
end

function control(
    unit :: PVPlant,
    systems :: Grouping,
    parameters :: Dict{String, Any}
)
    move_state(unit, systems, parameters)
    unit.supply = unit.scaling_factor * Profiles.work_at_time(unit.energy_profile, parameters["time"])
   
end


function produce(unit :: PVPlant, parameters :: Dict{String, Any}, watt_to_wh :: Function)
    outface = unit.output_interfaces[m_e_ac_230v]
    add!(outface, unit.supply)
end

export PVPlant