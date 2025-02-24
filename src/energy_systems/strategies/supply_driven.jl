function strt_sm_supply_driven(parameters::Dict{String,Any})::StateMachine
    return StateMachine()
end

strt_desc_supply_driven = """Supply-driven
------------------------
Ensures that the processing of a component is done after the processing from components that
provide energy to the controlled component has been calculated. This also works if a bus acts as
intermediary between components. As this strategy does not implement any actual control, it is
mostly used for ensuring the components are calculated in the right order as well as
indicating to the process implementation that a given supply must be used (as opposed to
strategy "demand_driven").
"""

OP_STRATS["supply_driven"] = OperationalStrategyType(
    name="supply_driven",
    description=strt_desc_supply_driven,
    sm_constructor=strt_sm_supply_driven,
    conditions=[],
    strategy_parameters=Dict{String,Any}(
        "name" => "supply_driven",
        "load_storages" => true,
        "unload_storages" => true,
        "operation_profile_path" => nothing,
        "m_el_in" => true,
        "m_el_out" => true,
        "m_gas_in" => true,
        "m_h2_out" => true,
        "m_o2_out" => true,
        "m_heat_out" => true,
        "m_heat_in" => true
    ),
    required_components=EnSysRequirements(
        "supplier" => (Component, nothing)
    )
)
