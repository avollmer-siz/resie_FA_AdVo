using Debugger
using Test
using Resie
using Resie.EnergySystems
using Resie.Profiles

EnergySystems.set_timestep(900)

function test_heat_pump_demand_driven_correct_order()
    components_config = Dict{String,Any}(
        "TST_DEM_01" => Dict{String,Any}(
            "type" => "Demand",
            "medium" => "m_h_w_ht1",
            "control_refs" => [],
            "output_refs" => [],
            "energy_profile_file_path" => "./profiles/tests/demand_heating_energy.prf",
            "temperature_profile_file_path" => "./profiles/tests/demand_heating_temperature.prf",
            "scale" => 1500
        ),
        "TST_SRC_01" => Dict{String,Any}(
            "type" => "BoundedSupply",
            "medium" => "m_h_w_lt1",
            "control_refs" => [],
            "output_refs" => ["TST_HP_01"],
            "max_power_profile_file_path" => "./profiles/tests/demand_heating_energy.prf",
            "temperature_profile_file_path" => "./profiles/tests/demand_heating_temperature.prf",
            "scale" => 6000
        ),
        "TST_GRI_01" => Dict{String,Any}(
            "type" => "GridConnection",
            "medium" => "m_e_ac_230v",
            "control_refs" => [],
            "output_refs" => ["TST_HP_01"],
            "is_source" => true,
        ),
        "TST_HP_01" => Dict{String,Any}(
            "type" => "HeatPump",
            "control_refs" => ["TST_DEM_01"],
            "output_refs" => ["TST_DEM_01"],
            "strategy" => Dict{String,Any}(
                "name" => "demand_driven",
            ),
            "power" => 12000
        ),
    )
    components = Resie.load_components(components_config)
    heat_pump = components["TST_HP_01"]
    source = components["TST_SRC_01"]
    demand = components["TST_DEM_01"]
    grid = components["TST_GRI_01"]

    simulation_parameters = Dict{String,Any}(
        "time_step_seconds" => 900,
        "time" => 0,
        "epsilon" => 1e-9
    )

    @test heat_pump.controller.state_machine.state == 1

    # first time step: demand is below max power of source (adjusted for additional input
    # of electricity), small delta T leads to high COP = 12.725999999999999

    for unit in values(components)
        EnergySystems.reset(unit)
    end

    EnergySystems.control(demand, components, simulation_parameters)

    demand.load = 900
    demand.temperature = 45
    demand.input_interfaces[demand.medium].temperature = 45

    @test heat_pump.input_interfaces[heat_pump.m_heat_in].temperature === nothing
    EnergySystems.control(source, components, simulation_parameters)

    source.max_energy = 5000/4
    source.temperature = 35
    source.output_interfaces[source.medium].temperature = 35
    source.output_interfaces[source.medium].max_energy = 5000/4

    EnergySystems.control(heat_pump, components, simulation_parameters)
    EnergySystems.control(grid, components, simulation_parameters)

    EnergySystems.process(demand, simulation_parameters)
    @test demand.input_interfaces[demand.medium].balance ≈ -900
    @test demand.input_interfaces[demand.medium].temperature == 45

    EnergySystems.process(heat_pump, simulation_parameters)
    @test heat_pump.output_interfaces[heat_pump.m_heat_out].balance ≈ 0
    @test heat_pump.output_interfaces[heat_pump.m_heat_out].sum_abs_change ≈ 1800
    @test heat_pump.output_interfaces[heat_pump.m_heat_out].temperature == 45
    @test heat_pump.input_interfaces[heat_pump.m_el_in].balance ≈ -70.7213578500708
    @test heat_pump.input_interfaces[heat_pump.m_el_in].temperature === nothing
    @test heat_pump.input_interfaces[heat_pump.m_heat_in].balance ≈ -829.2786421499292
    @test heat_pump.input_interfaces[heat_pump.m_heat_in].temperature == 35

    EnergySystems.process(source, simulation_parameters)
    @test source.output_interfaces[source.medium].balance ≈ 0
    @test source.output_interfaces[source.medium].sum_abs_change ≈ 1658.5572842998583
    @test source.output_interfaces[source.medium].temperature == 35

    EnergySystems.process(grid, simulation_parameters)
    @test grid.output_interfaces[grid.medium].balance ≈ 0
    @test grid.output_interfaces[grid.medium].sum_abs_change ≈ 141.4427157001416 
    @test grid.output_interfaces[grid.medium].temperature === nothing

    # second step: demand is above max power of source, big delta T leads to low COP = 3.4814999999999996

    for unit in values(components)
        EnergySystems.reset(unit)
    end

    EnergySystems.control(demand, components, simulation_parameters)

    demand.load = 2100
    demand.temperature = 75
    demand.input_interfaces[demand.medium].temperature = 75

    @test heat_pump.input_interfaces[heat_pump.m_heat_in].temperature === nothing
    EnergySystems.control(source, components, simulation_parameters)

    source.max_energy = 500
    source.temperature = 35
    source.output_interfaces[source.medium].temperature = 35
    source.output_interfaces[source.medium].max_energy = 500

    EnergySystems.control(heat_pump, components, simulation_parameters)
    EnergySystems.control(grid, components, simulation_parameters)

    EnergySystems.process(demand, simulation_parameters)
    @test demand.input_interfaces[demand.medium].balance ≈ -2100
    @test demand.input_interfaces[demand.medium].temperature == 75

    EnergySystems.process(heat_pump, simulation_parameters)
    @test heat_pump.output_interfaces[heat_pump.m_heat_out].balance ≈ -2100 + 500*(3.4814999999999996/(3.4814999999999996-1))
    @test heat_pump.output_interfaces[heat_pump.m_heat_out].sum_abs_change ≈ 2100 + 500*(3.4814999999999996/(3.4814999999999996-1))
    @test heat_pump.output_interfaces[heat_pump.m_heat_out].temperature == 75
    @test heat_pump.input_interfaces[heat_pump.m_el_in].balance ≈ -(500*(3.4814999999999996/(3.4814999999999996-1)) - 500)
    @test heat_pump.input_interfaces[heat_pump.m_el_in].temperature === nothing
    @test heat_pump.input_interfaces[heat_pump.m_heat_in].balance ≈ -500
    @test heat_pump.input_interfaces[heat_pump.m_heat_in].temperature == 35

    EnergySystems.process(source, simulation_parameters)
    @test source.output_interfaces[source.medium].balance ≈ 0
    @test source.output_interfaces[source.medium].sum_abs_change ≈ 1000
    @test source.output_interfaces[source.medium].temperature == 35

    EnergySystems.process(grid, simulation_parameters)
    @test grid.output_interfaces[grid.medium].balance ≈ 0
    @test grid.output_interfaces[grid.medium].sum_abs_change ≈ 2*(500*(3.4814999999999996/(3.4814999999999996-1)) - 500)
    @test grid.output_interfaces[grid.medium].temperature === nothing
end

@testset "heat_pump_demand_driven_correct_order" begin
    test_heat_pump_demand_driven_correct_order()
end