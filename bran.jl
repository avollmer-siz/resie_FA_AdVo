"""
The time step, in seconds, used by the simulation.

@TODO: Move this into the input parameters to make it customizable at runtime.
"""
const TIME_STEP = UInt(900)

include("energy_systems/base.jl")

using .EnergySystems

"""
    print_system_state(system, time)

Pretty-print the state of the given systems at the given time to the console.
"""
function print_system_state(systems :: Grouping, time :: Int)
    println("Time is ", time)
    for unit in each(systems)
        pprint(unit, time)
        print(" | ")
    end
    print("\n")
end

"""
    reset_file(systems)

Reset the output file and add headers for the given systems
"""
function reset_file(systems :: Grouping)
    open("./out.csv", "w") do file_handle
        write(file_handle, "Time [s]")

        for (key, unit) in pairs(systems)
            for val in specific_values(unit, Int(0))
                write(file_handle, ";$key $(val[1])")
            end

            if isa(unit, Bus) continue end

            for (medium, inface) in pairs(unit.input_interfaces)
                if inface === nothing continue end
                write(file_handle, ";$key $medium IN")
            end

            for (medium, outface) in pairs(unit.output_interfaces)
                if outface === nothing continue end
                write(file_handle, ";$key $medium OUT")
            end
        end

        write(file_handle, "\n")
    end
end

"""
    write_to_file(systems, time)

Write the energy transfer values and additional state to the output file.
"""
function write_to_file(systems :: Grouping, time :: Int)
    open("./out.csv", "a") do file_handle
        write(file_handle, "$time")

        for unit in each(systems)

            for val in specific_values(unit, time)
                write(file_handle, replace(
                    replace(";$(val[2])", "/" => ";"),
                    "." => ","
                ))
            end

            if isa(unit, Bus) continue end

            for inface in values(unit.input_interfaces)
                if inface === nothing continue end
                write(file_handle, replace(
                    replace(";$(inface.sum_abs_change * 0.5)", "/" => ";"),
                    "." => ","
                ))
            end

            for outface in values(unit.output_interfaces)
                if outface === nothing continue end
                write(file_handle, replace(
                    replace(";$(outface.sum_abs_change * 0.5)", "/" => ";"),
                    "." => ","
                ))
            end
        end

        write(file_handle, "\n")
    end
end

"""
    run_simulation()

Read inputs, perform the simulation calculation and write outputs.

This is the entry point to the simulation engine. Due to the complexity of required inputs
and how the outputs are written (to file), this function doesn't take any arguments and
returns nothing.
"""
function run_simulation()
    systems = Grouping(
        "TST_01_HZG_01_GRI" => make_GridConnection(EnergySystems.m_c_g_natgas, true),
        "TST_01_ELT_01_GRI" => make_GridConnection(EnergySystems.m_e_ac_230v, true),
        "TST_01_ELT_01_GRO" => make_GridConnection(EnergySystems.m_e_ac_230v, false),
        "TST_01_HZG_01_BFT" => make_BufferTank(40000.0, 20000.0),
        "TST_01_ELT_01_BAT" => make_Battery("Economical discharge", 10000.0, 5000.0),
        "TST_01_HZG_01_CHP" => make_CHPP("Ensure storage", 12500.0),
        "TST_01_HZG_01_HTP" => make_HeatPump("Ensure storage", 20000.0, 3.0),
        "TST_01_ELT_01_PVP" => make_PVPlant(15000.0),
        "TST_01_ELT_01_BUS" => make_Bus(EnergySystems.m_e_ac_230v),
        "TST_01_HZG_01_BUS" => make_Bus(EnergySystems.m_h_w_60c),
        "TST_01_HZG_01_DEM" => make_Demand(EnergySystems.m_h_w_60c, 10000.0),
        "TST_01_ELT_01_DEM" => make_Demand(EnergySystems.m_e_ac_230v, 15000.0),
    )

    simulation_order = [
        ["TST_01_ELT_01_PVP", EnergySystems.s_reset], # limited_source
        ["TST_01_HZG_01_DEM", EnergySystems.s_reset], # limited_sink
        ["TST_01_ELT_01_DEM", EnergySystems.s_reset], # limited_sink
        ["TST_01_HZG_01_BUS", EnergySystems.s_reset], # bus
        ["TST_01_ELT_01_BUS", EnergySystems.s_reset], # bus
        ["TST_01_HZG_01_CHP", EnergySystems.s_reset], # transformer
        ["TST_01_HZG_01_HTP", EnergySystems.s_reset], # transformer
        ["TST_01_HZG_01_BFT", EnergySystems.s_reset], # storage
        ["TST_01_ELT_01_BAT", EnergySystems.s_reset], # storage
        ["TST_01_HZG_01_GRI", EnergySystems.s_reset], # infinite_source
        ["TST_01_ELT_01_GRI", EnergySystems.s_reset], # infinite_source
        ["TST_01_ELT_01_GRO", EnergySystems.s_reset], # infinite_sink
        ["TST_01_ELT_01_PVP", EnergySystems.s_control, EnergySystems.s_produce], # limited_source
        ["TST_01_HZG_01_DEM", EnergySystems.s_control, EnergySystems.s_produce], # limited_sink
        ["TST_01_ELT_01_DEM", EnergySystems.s_control, EnergySystems.s_produce], # limited_sink
        ["TST_01_HZG_01_BUS", EnergySystems.s_control, EnergySystems.s_produce], # bus
        ["TST_01_ELT_01_BUS", EnergySystems.s_control, EnergySystems.s_produce], # bus
        ["TST_01_HZG_01_CHP", EnergySystems.s_control, EnergySystems.s_produce], # transformer
        ["TST_01_HZG_01_HTP", EnergySystems.s_control, EnergySystems.s_produce], # transformer
        ["TST_01_HZG_01_BFT", EnergySystems.s_control, EnergySystems.s_produce], # storage
        ["TST_01_ELT_01_BAT", EnergySystems.s_control, EnergySystems.s_produce], # storage
        ["TST_01_HZG_01_BFT", EnergySystems.s_load], # storage
        ["TST_01_ELT_01_BAT", EnergySystems.s_load], # storage
        ["TST_01_HZG_01_GRI", EnergySystems.s_control, EnergySystems.s_produce], # infinite_source
        ["TST_01_ELT_01_GRI", EnergySystems.s_control, EnergySystems.s_produce], # infinite_source
        ["TST_01_ELT_01_GRO", EnergySystems.s_control, EnergySystems.s_produce], # infinite_sink
        ["TST_01_HZG_01_BUS", EnergySystems.s_distribute], # bus
        ["TST_01_ELT_01_BUS", EnergySystems.s_distribute], # bus
    ]

    link_control_with(
        systems["TST_01_HZG_01_CHP"],
        Grouping("TST_01_HZG_01_BFT" => systems["TST_01_HZG_01_BFT"])
    )
    link_control_with(
        systems["TST_01_HZG_01_HTP"],
        Grouping("TST_01_HZG_01_BFT" => systems["TST_01_HZG_01_BFT"])
    )
    link_control_with(
        systems["TST_01_ELT_01_BAT"],
        Grouping("TST_01_ELT_01_PVP" => systems["TST_01_ELT_01_PVP"])
    )

    link_production_with(
        systems["TST_01_HZG_01_GRI"],
        Grouping("TST_01_HZG_01_CHP" => systems["TST_01_HZG_01_CHP"])
    )
    link_production_with(
        systems["TST_01_ELT_01_GRI"],
        Grouping("TST_01_ELT_01_BUS" => systems["TST_01_ELT_01_BUS"])
    )
    link_production_with(
        systems["TST_01_HZG_01_BFT"],
        Grouping("TST_01_HZG_01_BUS" => systems["TST_01_HZG_01_BUS"])
    )
    link_production_with(
        systems["TST_01_ELT_01_BAT"],
        Grouping("TST_01_ELT_01_BUS" => systems["TST_01_ELT_01_BUS"])
    )
    link_production_with(
        systems["TST_01_HZG_01_CHP"],
        Grouping(
            "TST_01_HZG_01_BUS" => systems["TST_01_HZG_01_BUS"],
            "TST_01_ELT_01_BUS" => systems["TST_01_ELT_01_BUS"]
        )
    )
    link_production_with(
        systems["TST_01_HZG_01_HTP"],
        Grouping("TST_01_HZG_01_BUS" => systems["TST_01_HZG_01_BUS"])
    )
    link_production_with(
        systems["TST_01_ELT_01_PVP"],
        Grouping("TST_01_ELT_01_BUS" => systems["TST_01_ELT_01_BUS"])
    )
    link_production_with(
        systems["TST_01_HZG_01_BUS"],
        Grouping(
            "TST_01_HZG_01_DEM" => systems["TST_01_HZG_01_DEM"],
            "TST_01_HZG_01_BFT" => systems["TST_01_HZG_01_BFT"]
        )
    )
    link_production_with(
        systems["TST_01_ELT_01_BUS"],
        Grouping(
            "TST_01_ELT_01_DEM" => systems["TST_01_ELT_01_DEM"],
            "TST_01_HZG_01_HTP" => systems["TST_01_HZG_01_HTP"],
            "TST_01_ELT_01_BAT" => systems["TST_01_ELT_01_BAT"],
            "TST_01_ELT_01_GRO" => systems["TST_01_ELT_01_GRO"]
        )
    )

    parameters = Dict{String, Any}(
        "time" => 0,
        "time_step_seconds" => TIME_STEP,
        "epsilon" => 1e-9
    )

    print_system_state(systems, parameters["time"])
    reset_file(systems)

    for i = 1:(96*7)
        # perform the simulation
        perform_steps(systems, simulation_order, parameters)

        # check if any energy system was not balanced
        warnings = check_balances(systems, parameters["epsilon"])
        if length(warnings) > 0
            print("Time is $(parameters["time"])\n")
            for (key, balance) in warnings
                print("Warning: Balance for system $key was not zero: $balance\n")
            end
        end

        # output
        write_to_file(systems, parameters["time"])

        # simulation update
        parameters["time"] += Int(TIME_STEP)
    end
end

run_simulation()
