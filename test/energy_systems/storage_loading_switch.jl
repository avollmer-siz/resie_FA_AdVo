using Debugger
using Test
using Resie
using Resie.EnergySystems
using Resie.Profiles

EnergySystems.set_timestep(900)

function test_primary_producer_can_load_storage()
    components_config = Dict{String,Any}(
        "TST_GRI_01" => Dict{String,Any}(
            "type" => "GridConnection",
            "medium" => "m_c_g_natgas",
            "control_refs" => [],
            "output_refs" => ["TST_GBO_01"],
            "is_source" => true,
        ),
        "TST_GRI_02" => Dict{String,Any}(
            "type" => "GridConnection",
            "medium" => "m_c_g_natgas",
            "control_refs" => [],
            "output_refs" => ["TST_GBO_02"],
            "is_source" => true,
        ),
        "TST_GBO_01" => Dict{String,Any}(
            "type" => "GasBoiler",
            "control_refs" => ["TST_BFT_01"],
            "output_refs" => [
                "TST_BUS_01"
            ],
            "strategy" => Dict{String,Any}(
                "name" => "storage_driven",
                "high_threshold" => 0.5,
                "low_threshold" => 0.1
            ),
            "power" => 10000
        ),
        "TST_GBO_02" => Dict{String,Any}(
            "type" => "GasBoiler",
            "control_refs" => ["TST_BFT_01"],
            "output_refs" => [
                "TST_BUS_01"
            ],
            "strategy" => Dict{String,Any}(
                "name" => "demand_driven"
            ),
            "power" => 40000
        ),
        "TST_BUS_01" => Dict{String,Any}(
            "type" => "Bus",
            "medium" => "m_h_w_ht1",
            "control_refs" => [],
            "output_refs" => ["TST_DEM_01", "TST_BFT_01"],
            "connection_matrix" => Dict{String, Any}(
                "input_order" => [
                    "TST_GBO_01",
                    "TST_BFT_01",
                    "TST_GBO_02"
                ],
                "output_order" => [
                    "TST_DEM_01",
                    "TST_BFT_01"
                ],
                "storage_loading" => [
                    [1, 1],
                    [1, 0],
                    [1, 0]
                ]
            )
        ),
        "TST_BFT_01" => Dict{String,Any}(
            "type" => "BufferTank",
            "control_refs" => [],
            "output_refs" => [
                "TST_BUS_01"
            ],
            "capacity" => 40000,
            "load" => 0
        ),
        "TST_DEM_01" => Dict{String,Any}(
            "type" => "Demand",
            "medium" => "m_h_w_ht1",
            "control_refs" => [],
            "output_refs" => [],
            "energy_profile_file_path" => "./profiles/tests/demand_heating_energy.prf",
            "temperature_profile_file_path" => "./profiles/tests/demand_heating_temperature.prf",
            "scale" => 1,
            "static_load" => 5000,
            "static_temperature" => 60
        ),
    )
    components = Resie.load_components(components_config)
    demand = components["TST_DEM_01"]
    grid_1 = components["TST_GRI_01"]
    grid_2 = components["TST_GRI_02"]
    bus = components["TST_BUS_01"]
    tank = components["TST_BFT_01"]
    boiler_1 = components["TST_GBO_01"]
    boiler_2 = components["TST_GBO_02"]

    simulation_parameters = Dict{String,Any}(
        "time_step_seconds" => 900,
        "time" => 0,
        "epsilon" => 1e-9
    )

    # first timestep, demand is higher than primary producer can provide, so both should
    # operate. however as the secondary should not load the storage, it only covers the
    # remaining demand

    EnergySystems.reset(grid_1)
    EnergySystems.reset(grid_2)
    EnergySystems.reset(boiler_1)
    EnergySystems.reset(boiler_2)
    EnergySystems.reset(bus)
    EnergySystems.reset(tank)
    EnergySystems.reset(demand)

    EnergySystems.control(demand, components, simulation_parameters)
    EnergySystems.control(bus, components, simulation_parameters)
    EnergySystems.control(boiler_1, components, simulation_parameters)
    EnergySystems.control(tank, components, simulation_parameters)
    EnergySystems.control(boiler_2, components, simulation_parameters)
    EnergySystems.control(grid_1, components, simulation_parameters)
    EnergySystems.control(grid_2, components, simulation_parameters)

    @test boiler_1.controller.state_machine.state == 2
    @test boiler_2.controller.state_machine.state == 1

    EnergySystems.process(demand, simulation_parameters)
    EnergySystems.process(bus, simulation_parameters)

    EnergySystems.process(boiler_1, simulation_parameters)
    @test boiler_1.output_interfaces[boiler_1.m_heat_out].balance == 2500.0

    EnergySystems.process(tank, simulation_parameters)
    @test tank.output_interfaces[tank.medium].sum_abs_change == 0.0

    EnergySystems.process(boiler_2, simulation_parameters)
    @test boiler_2.output_interfaces[boiler_2.m_heat_out].balance == 2500.0

    EnergySystems.load(tank, simulation_parameters)
    @test tank.input_interfaces[tank.medium].sum_abs_change == 0.0

    EnergySystems.process(grid_2, simulation_parameters)
    EnergySystems.process(grid_1, simulation_parameters)
    EnergySystems.distribute!(bus)

    exchange = EnergySystems.balance_on(
        boiler_1.output_interfaces[boiler_1.m_heat_out], bus
    )
    @test exchange.balance == 0.0
    @test exchange.storage_potential == -40000.0

    exchange = EnergySystems.balance_on(
        boiler_2.output_interfaces[boiler_2.m_heat_out], bus
    )
    @test exchange.balance == 0.0
    @test exchange.storage_potential == 0.0

    # in the second timestep, demand is lower than primary producer can provide, so the
    # excess can go into storage. because the secondary should not load the storage, it
    # should be inactive during this time step

    EnergySystems.reset(grid_1)
    EnergySystems.reset(grid_2)
    EnergySystems.reset(boiler_1)
    EnergySystems.reset(boiler_2)
    EnergySystems.reset(bus)
    EnergySystems.reset(tank)
    EnergySystems.reset(demand)

    demand.static_load = 1500

    EnergySystems.control(demand, components, simulation_parameters)
    EnergySystems.control(bus, components, simulation_parameters)
    EnergySystems.control(boiler_1, components, simulation_parameters)
    EnergySystems.control(tank, components, simulation_parameters)
    EnergySystems.control(boiler_2, components, simulation_parameters)
    EnergySystems.control(grid_1, components, simulation_parameters)
    EnergySystems.control(grid_2, components, simulation_parameters)

    @test boiler_1.controller.state_machine.state == 2
    @test boiler_2.controller.state_machine.state == 1

    EnergySystems.process(demand, simulation_parameters)
    EnergySystems.process(bus, simulation_parameters)

    EnergySystems.process(boiler_1, simulation_parameters)
    @test boiler_1.output_interfaces[boiler_1.m_heat_out].balance == 2500.0

    EnergySystems.process(tank, simulation_parameters)
    @test tank.output_interfaces[tank.medium].sum_abs_change == 0.0

    EnergySystems.process(boiler_2, simulation_parameters)
    @test boiler_2.output_interfaces[boiler_2.m_heat_out].sum_abs_change == 0.0

    EnergySystems.load(tank, simulation_parameters)
    @test tank.load == 1000.0

    EnergySystems.process(grid_2, simulation_parameters)
    EnergySystems.process(grid_1, simulation_parameters)
    EnergySystems.distribute!(bus)

    @test tank.input_interfaces[tank.medium].sum_abs_change == 2000.0
    @test boiler_1.output_interfaces[boiler_2.m_heat_out].sum_abs_change == 5000.0

    exchange = EnergySystems.balance_on(
        boiler_1.output_interfaces[boiler_1.m_heat_out], bus
    )
    @test exchange.balance == 0.0
    @test exchange.storage_potential == -39000.0

    exchange = EnergySystems.balance_on(
        boiler_2.output_interfaces[boiler_2.m_heat_out], bus
    )
    @test exchange.balance == 0.0
    @test exchange.storage_potential == 0.0
end

@testset "primary_producer_can_load_storage" begin
    test_primary_producer_can_load_storage()
end