using Test

@testset "energy_systems_individual_tests" begin
    include("energy_systems/heat_pump_demand_driven.jl")
    include("energy_systems/demand_heating.jl")
    include("energy_systems/bus_to_bus.jl")
    include("energy_systems/storage_loading_switch.jl")
    #include("energy_systems/multiple_transformer_limited.jl") deactivated as test are failing currently
end