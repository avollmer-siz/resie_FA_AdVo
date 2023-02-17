"""
Implementation of an electrolyser, turning electricity and water into H2, O2 and heat.

For the moment this remains a simple implementation that converts electricity into
the gases and heat (as medium m_h_w_ht1) at a defined ratio of 1:0.6:0.4. Has a minimum
run time of 3600s taken into consideration in its control behaviour and a minimum power
fraction of 20%. The power is considered the maximum amount of electricity that the
electrolyser can consume.

At the moment there is no operation strategy is implemented and the production of the
electrolyser is controlled by the demand it is linked to requires.
"""
mutable struct Electrolyser <: ControlledSystem
    uac :: String
    controller :: Controller
    sys_function :: SystemFunction

    input_interfaces :: InterfaceMap
    output_interfaces :: InterfaceMap

    power :: Float64
    heat_fraction :: Float64
    min_power_fraction :: Float64
    min_run_time :: UInt
    output_temperature :: Temperature

    function Electrolyser(uac :: String, config :: Dict{String, Any})
        return new(
            uac, # uac
            controller_for_strategy( # controller
                config["strategy"]["name"], config["strategy"]
            ),
            sf_transformer, # sys_function
            InterfaceMap( # input_interfaces
                m_e_ac_230v => nothing
            ),
            InterfaceMap( # output_interfaces
                m_h_w_lt1 => nothing,
                m_c_g_h2 => nothing,
                m_c_g_o2 => nothing
            ),
            config["power"], # power
            "heat_fraction" in keys(config) # heat_fraction
                ? config["heat_fraction"]
                : 0.4,
            "min_power_fraction" in keys(config) # min_power_fraction
                ? config["min_power_fraction"]
                : 0.2,
            "min_run_time" in keys(config) # min_run_time
                ? config["min_run_time"]
                : 3600,
            "output_temperature" in keys(config) # output_temperature
                ? config["output_temperature"]
                : 55.0
        )
    end
end

function produce(unit :: Electrolyser, parameters :: Dict{String, Any}, watt_to_wh :: Function)
    max_produce_h = watt_to_wh(unit.power * unit.heat_fraction)
    max_produce_g = watt_to_wh(unit.power * (1.0 - unit.heat_fraction))
    max_available_e = unit.power

    # heat
    balance_h, potential_h, _ = balance_on(
        unit.output_interfaces[m_h_w_lt1],
        unit.output_interfaces[m_h_w_lt1].target
    )

    # hydrogen
    balance_g, potential_g, _ = balance_on(
        unit.output_interfaces[m_c_g_h2],
        unit.output_interfaces[m_c_g_h2].target
    )   

    # electricity 
    balance_e, potential_e, _ = balance_on(
        unit.input_interfaces[m_e_ac_230v],
        unit.input_interfaces[m_e_ac_230v].target
    )

    if balance_h + potential_h >= 0.0 
        return # don't add to a surplus of h2 
    end

    # --> currently not working as potential of unlimited sinks are not written into interface  @ToDo
    # if  balance_g + potential_g >= 0.0 
    #     return # don't add to a surplus of heat
    # end

    # --> currently not working as potential of unlimited sources are not written into interface @ToDo
    # if balance_e + potential_e <= 0.0
    #     return  # no elecricity available
    # end   

    # --> currently not working as balances are not calculated correctly for unlimited gas and electricity @ToDo
    #usage_fraction = min(1.0, abs(balance_h + potential_h) / max_produce_h, abs(balance_g + potential_g) / max_produce_g, abs(balance_e + potential_e) / max_available_e)
    # for now, use only heat balance and potential:
    usage_fraction = min(1.0, abs(balance_h + potential_h) / max_produce_h)

    if usage_fraction < unit.min_power_fraction
        return
    end

    # @TODO: handle O2 calculation if it ever becomes relevant. for now use molar ratio
    add!(unit.output_interfaces[m_c_g_h2], max_produce_g * usage_fraction)
    add!(unit.output_interfaces[m_c_g_o2], max_produce_g * usage_fraction * 0.5)
    add!(
        unit.output_interfaces[m_h_w_lt1],
        max_produce_h * usage_fraction,
        unit.output_temperature
    )
    sub!(unit.input_interfaces[m_e_ac_230v], watt_to_wh(unit.power * usage_fraction))

end

export Electrolyser