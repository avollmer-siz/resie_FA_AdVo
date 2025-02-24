"""
Implementation of a heat pump component.

For the moment this remains a simple implementation that requires a low temperature heat
and electricity input and produces high temperature heat. Has a fixed coefficient of
performance (COP) of 3 and a minimum power fraction of 20%. The power parameter is
considered the maximum power of heat output the heat pump can produce.

The only currently implemented operation strategy involves checking the load of a linked
buffer tank and en-/disabling the heat pump when a threshold is reached, in addition to an
overfill shutoff condition.
"""
mutable struct HeatPump <: ControlledComponent
    uac::String
    controller::Controller
    sys_function::SystemFunction

    input_interfaces::InterfaceMap
    output_interfaces::InterfaceMap

    m_el_in::Symbol
    m_heat_out::Symbol
    m_heat_in::Symbol

    power::Float64
    min_power_fraction::Float64
    min_run_time::UInt
    fixed_cop::Any
    output_temperature::Temperature
    input_temperature::Temperature
    cop::Float64

    function HeatPump(uac::String, config::Dict{String,Any})
        m_el_in = Symbol(default(config, "m_el_in", "m_e_ac_230v"))
        m_heat_out = Symbol(default(config, "m_heat_out", "m_h_w_ht1"))
        m_heat_in = Symbol(default(config, "m_heat_in", "m_h_w_lt1"))
        register_media([m_el_in, m_heat_out, m_heat_in])

        return new(
            uac, # uac
            controller_for_strategy( # controller
                config["strategy"]["name"], config["strategy"]
            ),
            sf_transformer, # sys_function
            InterfaceMap( # input_interfaces
                m_heat_in => nothing,
                m_el_in => nothing
            ),
            InterfaceMap( # output_interfaces
                m_heat_out => nothing
            ),
            m_el_in,
            m_heat_out,
            m_heat_in,
            config["power"], # power
            default(config, "min_power_fraction", 0.2),
            default(config, "min_run_time", 0),
            default(config, "fixed_cop", nothing),
            default(config, "output_temperature", nothing),
            default(config, "input_temperature", nothing),
            0.0, # cop
        )
    end
end

function control(
    unit::HeatPump,
    components::Grouping,
    parameters::Dict{String,Any}
)
    move_state(unit, components, parameters)
    unit.output_interfaces[unit.m_heat_out].temperature = highest_temperature(unit.output_temperature, unit.output_interfaces[unit.m_heat_out].temperature)
    unit.input_interfaces[unit.m_heat_in].temperature = highest_temperature(unit.input_temperature, unit.input_interfaces[unit.m_heat_in].temperature)

end

function output_values(unit::HeatPump)::Vector{String}
    return ["IN", "OUT", "COP"]
end

function output_value(unit::HeatPump, key::OutputKey)::Float64
    if key.value_key == "IN"
        return calculate_energy_flow(unit.input_interfaces[key.medium])
    elseif key.value_key == "OUT"
        return calculate_energy_flow(unit.output_interfaces[key.medium])
    elseif key.value_key == "COP"
        return unit.cop
    end
    throw(KeyError(key.value_key))
end

function set_max_energies!(
    unit::HeatPump, el_in::Float64,
    heat_in::Float64, heat_out::Float64
)
    set_max_energy!(unit.input_interfaces[unit.m_el_in], el_in)
    set_max_energy!(unit.input_interfaces[unit.m_heat_in], heat_in)
    set_max_energy!(unit.output_interfaces[unit.m_heat_out], heat_out)
end

function dynamic_cop(in_temp::Temperature, out_temp::Temperature)::Union{Nothing,Float64}
    if (in_temp === nothing || out_temp === nothing)
        return nothing
    end
    
    return 0.4 * (273.15 + out_temp) / (out_temp - in_temp) # Carnot-COP with 40 % efficiency
end

function check_el_in(
    unit::HeatPump,
    parameters::Dict{String,Any}
)
    if unit.controller.parameter["m_el_in"] == true
        if (
            unit.input_interfaces[unit.m_el_in].source.sys_function == sf_transformer
            &&
            unit.input_interfaces[unit.m_el_in].max_energy === nothing
        )
            return (Inf, Inf)
        else
            exchange = balance_on(
                unit.input_interfaces[unit.m_el_in],
                unit.input_interfaces[unit.m_el_in].source
            )
            potential_energy_el = exchange.balance + exchange.energy_potential
            potential_storage_el = exchange.storage_potential
            if (unit.controller.parameter["unload_storages"] ? potential_energy_el + potential_storage_el : potential_energy_el) <= parameters["epsilon"]
                return (nothing, nothing)
            end
            return (potential_energy_el, potential_storage_el)
        end
    else
        return (Inf, Inf)
    end
end

function check_heat_in(
    unit::HeatPump,
    parameters::Dict{String,Any}
)
    if unit.controller.parameter["m_heat_in"] == true
        if (
            unit.input_interfaces[unit.m_heat_in].source.sys_function == sf_transformer
            &&
            unit.input_interfaces[unit.m_heat_in].max_energy === nothing
        )
            return (Inf, Inf, unit.input_interfaces[unit.m_heat_in].temperature)
        else
            exchange = balance_on(
                unit.input_interfaces[unit.m_heat_in],
                unit.input_interfaces[unit.m_heat_in].source
            )
            potential_energy_heat_in = exchange.balance + exchange.energy_potential
            potential_storage_heat_in = exchange.storage_potential
            if (unit.controller.parameter["unload_storages"] ? potential_energy_heat_in + potential_storage_heat_in : potential_energy_heat_in) <= parameters["epsilon"]
                return (nothing, nothing, exchange.temperature)
            end
            return (potential_energy_heat_in, potential_storage_heat_in, exchange.temperature)
        end
    else
        return (Inf, Inf, unit.input_interfaces[unit.m_heat_in].temperature)
    end

end

function check_heat_out(
    unit::HeatPump,
    parameters::Dict{String,Any}
)
    if unit.controller.parameter["m_heat_out"] == true
        exchange = balance_on(
            unit.output_interfaces[unit.m_heat_out],
            unit.output_interfaces[unit.m_heat_out].target
        )
        potential_energy_heat_out = exchange.balance + exchange.energy_potential
        potential_storage_heat_out = exchange.storage_potential
        if (unit.controller.parameter["load_storages"] ? potential_energy_heat_out + potential_storage_heat_out : potential_energy_heat_out) >= -parameters["epsilon"]
            return (nothing, nothing, exchange.temperature)
        end
        return (potential_energy_heat_out, potential_storage_heat_out, exchange.temperature)
    else
        return (-Inf, -Inf, unit.output_interfaces[unit.m_heat_out].temperature)
    end
end

function calculate_energies(
    unit::HeatPump,
    parameters::Dict{String,Any},
    temperatures::Tuple{Temperature, Temperature},
    potentials::Vector{Float64}
)
    potential_energy_el = potentials[1]
    potential_storage_el = potentials[2]
    potential_energy_heat_in = potentials[3]
    potential_storage_heat_in = potentials[4]
    potential_energy_heat_out = potentials[5]
    potential_storage_heat_out = potentials[6]

    # get usage fraction of external profile (normalized from 0 to 1)
    usage_fraction_operation_profile = unit.controller.parameter["operation_profile_path"] === nothing ? 1.0 : value_at_time(unit.controller.parameter["operation_profile"], parameters["time"])
    if usage_fraction_operation_profile <= 0.0
        return (false, nothing, nothing, nothing)
    end

    # a fixed COP has priority. if it's not given the dynamic cop requires temperatures
    unit.cop = unit.fixed_cop === nothing ? dynamic_cop(temperatures[1], temperatures[2]) : unit.fixed_cop
    if unit.cop === nothing
        throw(ArgumentError("Input and/or output temperature for heatpump $(unit.uac) is not given. Provide temperatures or fixed cop."))
    end

    # maximum possible in and outputs of heat pump, not regarding any external limits!
    max_produce_heat = watt_to_wh(unit.power)
    max_consume_heat = max_produce_heat * (1.0 - 1.0 / unit.cop)
    max_consume_el = max_produce_heat - max_consume_heat

    # all three standard operating strategies behave the same, but it is better to be
    # explicit about the behaviour rather than grouping all together
    if unit.controller.strategy == "storage_driven" && unit.controller.state_machine.state == 2
        usage_fraction_heat_out = -((unit.controller.parameter["load_storages"] ? potential_energy_heat_out + potential_storage_heat_out : potential_energy_heat_out) / max_produce_heat)
        usage_fraction_heat_in = +((unit.controller.parameter["unload_storages"] ? potential_energy_heat_in + potential_storage_heat_in : potential_energy_heat_in) / max_consume_heat)
        usage_fraction_el = +((unit.controller.parameter["unload_storages"] ? potential_energy_el + potential_storage_el : potential_energy_el) / max_consume_el)

    elseif unit.controller.strategy == "storage_driven"
        return (false, nothing, nothing, nothing)

    elseif unit.controller.strategy == "supply_driven"
        usage_fraction_heat_out = -((unit.controller.parameter["load_storages"] ? potential_energy_heat_out + potential_storage_heat_out : potential_energy_heat_out) / max_produce_heat)
        usage_fraction_heat_in = +((unit.controller.parameter["unload_storages"] ? potential_energy_heat_in + potential_storage_heat_in : potential_energy_heat_in) / max_consume_heat)
        usage_fraction_el = +((unit.controller.parameter["unload_storages"] ? potential_energy_el + potential_storage_el : potential_energy_el) / max_consume_el)

    elseif unit.controller.strategy == "demand_driven"
        usage_fraction_heat_out = -((unit.controller.parameter["load_storages"] ? potential_energy_heat_out + potential_storage_heat_out : potential_energy_heat_out) / max_produce_heat)
        usage_fraction_heat_in = +((unit.controller.parameter["unload_storages"] ? potential_energy_heat_in + potential_storage_heat_in : potential_energy_heat_in) / max_consume_heat)
        usage_fraction_el = +((unit.controller.parameter["unload_storages"] ? potential_energy_el + potential_storage_el : potential_energy_el) / max_consume_el)
    end

    # limit actual usage by limits of inputs, outputs and profile
    usage_fraction = min(
        1.0,
        usage_fraction_heat_out,
        usage_fraction_heat_in,
        usage_fraction_el,
        usage_fraction_operation_profile
    )

    if usage_fraction < unit.min_power_fraction
        return (false, nothing, nothing, nothing)
    end

    return (
        true,
        max_consume_el * usage_fraction,
        max_consume_heat * usage_fraction,
        max_produce_heat * usage_fraction
    )
end

function potential(
    unit::HeatPump,
    parameters::Dict{String,Any}
)
    potential_energy_el, potential_storage_el = check_el_in(unit, parameters)
    if potential_energy_el === nothing && potential_storage_el === nothing
        set_max_energies!(unit, 0.0, 0.0, 0.0)
        return
    end

    potential_energy_heat_in, potential_storage_heat_in, in_temp = check_heat_in(unit, parameters)
    if potential_energy_heat_in === nothing && potential_storage_heat_in === nothing
        set_max_energies!(unit, 0.0, 0.0, 0.0)
        return
    end

    potential_energy_heat_out, potential_storage_heat_out, out_temp = check_heat_out(unit, parameters)
    if potential_energy_heat_out === nothing && potential_storage_heat_out === nothing
        set_max_energies!(unit, 0.0, 0.0, 0.0)
        return
    end

    # check if temperature has already been read from input and output interface, if not
    # check by balance_on
    if in_temp === nothing
        exchange = balance_on(
            unit.input_interfaces[unit.m_heat_in],
            unit
        )
        in_temp = exchange.temperature
    end

    if out_temp === nothing
        exchange = balance_on(
            unit.output_interfaces[unit.m_heat_out],
            unit.output_interfaces[unit.m_heat_out].target
        )
        out_temp = exchange.temperature
    end

    # quit if requested temperature is higher than optionally given output_temperature
    if unit.output_temperature !== nothing && out_temp > unit.output_temperature
        set_max_energies!(unit, 0.0, 0.0, 0.0)
        return
    end
        
    # quit if available temperature is lower than optionally given input_temperature
    if unit.input_temperature !== nothing && in_temp < unit.input_temperature
        set_max_energies!(unit, 0.0, 0.0, 0.0)
        return
    end

    if out_temp === nothing && unit.fixed_cop === nothing
        throw(ArgumentError("Heat pump $(unit.uac) has no requested output temperature. Please provide a temperature."))
    elseif in_temp === nothing && unit.fixed_cop === nothing
        throw(ArgumentError("Heat pump $(unit.uac) has no requested input temperature. Please provide a temperature."))
    end

    energies = calculate_energies(
        unit, parameters,
        (in_temp, out_temp),
        [
            potential_energy_el, potential_storage_el,
            potential_energy_heat_in, potential_storage_heat_in,
            potential_energy_heat_out, potential_storage_heat_out
        ]
    )

    if !energies[1]
        set_max_energies!(unit, 0.0, 0.0, 0.0)
    else
        set_max_energies!(unit, energies[2], energies[3], energies[4])
    end
end

function process(unit::HeatPump, parameters::Dict{String,Any})
    potential_energy_el, potential_storage_el = check_el_in(unit, parameters)
    if potential_energy_el === nothing && potential_storage_el === nothing
        set_max_energies!(unit, 0.0, 0.0, 0.0)
        return
    end

    potential_energy_heat_in, potential_storage_heat_in, in_temp = check_heat_in(unit, parameters)
    if potential_energy_heat_in === nothing && potential_storage_heat_in === nothing
        set_max_energies!(unit, 0.0, 0.0, 0.0)
        return
    end

    potential_energy_heat_out, potential_storage_heat_out, out_temp = check_heat_out(unit, parameters)
    if potential_energy_heat_out === nothing && potential_storage_heat_out === nothing
        set_max_energies!(unit, 0.0, 0.0, 0.0)
        return
    end

    # check if temperature has already been read from input and output interface, if not
    # check by balance_on
    if in_temp === nothing
        exchange = balance_on(
            unit.input_interfaces[unit.m_heat_in],
            unit
        )
        in_temp = exchange.temperature
    end

    if out_temp === nothing
        exchange = balance_on(
            unit.output_interfaces[unit.m_heat_out],
            unit.output_interfaces[unit.m_heat_out].target
        )
        out_temp = exchange.temperature
    end

    # quit if requested temperature is higher than optionally given output_temperature
    if unit.output_temperature !== nothing && out_temp > unit.output_temperature
        set_max_energies!(unit, 0.0, 0.0, 0.0)
        return
    end
        
    # quit if available temperature is higher than optionally given input_temperature
    if unit.input_temperature !== nothing && in_temp < unit.input_temperature
        set_max_energies!(unit, 0.0, 0.0, 0.0)
        return
    end

    if out_temp === nothing && unit.fixed_cop === nothing
        throw(ArgumentError("Heat pump $(unit.uac) has no requested output temperature. Please provide a temperature."))
    elseif in_temp === nothing && unit.fixed_cop === nothing
        throw(ArgumentError("Heat pump $(unit.uac) has no requested input temperature. Please provide a temperature."))
    end

    energies = calculate_energies(
        unit, parameters,
        (in_temp, out_temp),
        [
            potential_energy_el, potential_storage_el,
            potential_energy_heat_in, potential_storage_heat_in,
            potential_energy_heat_out, potential_storage_heat_out
        ]
    )

    if energies[1]
        sub!(unit.input_interfaces[unit.m_el_in], energies[2])
        sub!(unit.input_interfaces[unit.m_heat_in], energies[3])
        add!(unit.output_interfaces[unit.m_heat_out], energies[4], out_temp)
    end
end

export HeatPump