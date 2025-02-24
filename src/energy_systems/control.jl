"""Convenience type alias for requirements of components."""
const EnSysRequirements = Dict{String,Tuple{Type,Union{Nothing,Symbol}}}

"""
Prototype for Condition, from which instances of the latter are derived.

See Condition for how they are used. The prototype defines which components a
condition requires to calculate its truth value, as well parameters for this calculation.
The selection of component for the condition is considered an input to the simulation
as it cannot be derived from other inputs. It is up to the user to decide which components are
required for operational strategies (and therefore conditions) to work.
"""
struct ConditionPrototype
    """An identifiable name."""
    name::String

    """Parameters the condition requires."""
    parameters::Dict{String,Any}

    """Defines which components the condition requires, indexed by an internal name.

    For some components a medium is required as they can take varying values.
    """
    required_components::EnSysRequirements

    """Implementation of the boolean expression the condition represents."""
    check_function::Function
end

CONDITION_PROTOTYPES = Dict{String,ConditionPrototype}()

include("conditions/base.jl")

"""
A boolean decision variable for a transition in a state machine.

A Condition instance is constructed from its corresponding prototype, which invokes certain
required parameters and components.
"""
struct Condition
    """From which prototype the condition is derived."""
    prototype::ConditionPrototype

    """Hold parameters the condition requires."""
    parameters::Dict{String,Any}

    """The components linked to the condition indexed by an internal name."""
    linked_components::Grouping
end

"""
    rel(condition, name)

Get the linked component of the given name for a condition.
"""
function rel(condition::Condition, name::String)::ControlledComponent
    return condition.linked_components[name]
end

"""
Constructor for Condition.

# Arguments
- `name::String`: The name of the condition
- `parameters::Dict{String, Any]`: Parameters for the condition. Not to be confused with
    the project-wide parameters for the entire simulation.

# Returns
- `Condition`: A Condition instance with default parameter values and information on which
    components are required, but components have not been linked yet
"""
function Condition(
    name::String,
    parameters::Dict{String,Any}
)::Condition
    prototype = CONDITION_PROTOTYPES[name]
    return Condition(
        prototype,
        merge(prototype.parameters, parameters),
        Grouping()
    )
end

"""
    link(condition, components)

Look for the condition's required components in the given set and link the condition to them.

For example, if a condition required a component "grid_out" of type GridConnection and medium
m_e_ac_230v, it will look through the set of given components and link to the first match.
"""
function link(condition::Condition, components::Grouping)
    for (name, req_unit) in pairs(condition.prototype.required_components)
        found_link = false
        for unit in each(components)
            if isa(unit, req_unit[1])
                if (req_unit[2] !== nothing
                    && hasfield(typeof(unit), Symbol("medium"))
                    && unit.medium == req_unit[2]
                )
                    condition.linked_components[name] = unit
                    found_link = true
                elseif req_unit[2] === nothing
                    condition.linked_components[name] = unit
                    found_link = true
                end
            end
        end

        if !found_link
            throw(KeyError(
                    "Could not find match for required component $name "
                    * "for condition $(condition.prototype.name)"
            ))
        end
    end
end

"""
    link_control_with(unit, components)

Link the given components with the control mechanisms of the given unit.

The components are the same as the control_refs project config entry, meaning this is user
input, but correction configuration should have been checked beforehand by automated
mechanisms. See also [`link`](@ref) for how linking conditions works.
"""
function link_control_with(unit::ControlledComponent, components::Grouping)
    for table in values(unit.controller.state_machine.transitions)
        for condition in table.conditions
            link(condition, components)
        end
    end

    # @TODO: if a strategy requires multiple components of general description, the first
    # component in the grouping will be matched multiple times, instead of each being matched
    # only once
    strategy_type = OP_STRATS[unit.controller.strategy]
    for (req_type, medium) in values(strategy_type.required_components)
        for other_unit in values(components)
            if typeof(other_unit) <: req_type
                if medium === nothing || (
                    hasfield(typeof(other_unit), Symbol("medium"))
                    &&
                    other_unit.medium == medium
                )
                    unit.controller.linked_components[other_unit.uac] = other_unit
                end
            end
        end
    end

    for table in values(unit.controller.state_machine.transitions)
        for condition in table.conditions
            for other_unit in values(condition.linked_components)
                unit.controller.linked_components[other_unit.uac] = other_unit
            end
        end
    end
end

"""
Maps a vector of boolean values to integers.

This is used to define the transitions of a StateMachine by defining which values of
conditions lead to which state.

# Examples
```
table = TruthTable(
    conditions=[Condition("foo is big"), Condition("bar is small")],
    table_data=Dict{Tuple, UInt}(
        (false, false) => 1,
        (false, true) => 1,
        (true, false) => 2,
        (true, true) => 1,
    )
)
```
This example defines a transitions for a state machine with two states. If the condition
"foo is big" is true and the condition "bar is small" is false, the new state should be the
second state, otherwise the first.
"""
Base.@kwdef struct TruthTable
    conditions::Vector{Condition}
    table_data::Dict{Tuple,UInt}
end

"""
Implementation of state machines with generalized conditions instead of an input alphabet.

Similar to the state machines used in regular languages, a state machine is always in one
of its states and certain conditions define how transitions between states occurs. Instead
of checking against characters in an input alphabet, these state machines are typically
checked once every time step of a simulation and the conditions can have arbitrary
implementations that require the simulation state as input.
"""
mutable struct StateMachine
    """The current state of the state machine."""
    state::UInt

    """A map of state names indexes by their ID."""
    state_names::Dict{UInt,String}

    """Maps states to a TruthTable that define the transitions in that state."""
    transitions::Dict{UInt,TruthTable}

    """
    The number of steps the state machine has been in the current state.

    Starts counting at 1.
    """
    time_in_state::UInt
end

"""
Constructor for non-default fields.
"""
StateMachine(
    state::UInt,
    state_names::Dict{UInt,String},
    transitions::Dict{UInt,TruthTable}
) = StateMachine(
    state,
    state_names,
    transitions,
    UInt(0)
)

"""
Default constructor that creates a state machine with only one state called "Default".
"""
StateMachine() = StateMachine(
    UInt(1),
    Dict(UInt(1) => "Default"),
    Dict(UInt(1) => TruthTable(
        conditions=Vector(),
        table_data=Dict()
    ))
)

"""
Wraps around the mechanism of control for the operation strategy of a Component.
"""
Base.@kwdef mutable struct Controller
    strategy::String
    parameter::Dict{String,Any}
    state_machine::StateMachine
    linked_components::Grouping
end

"""
    move_state(unit, components, parameters)

Checks the controller of the given unit and moves the state machine to its new state.
"""
function move_state(
    unit::ControlledComponent,
    components::Grouping,
    parameters::Dict{String,Any}
)
    machine = unit.controller.state_machine
    old_state = machine.state
    table = machine.transitions[machine.state]

    if length(table.conditions) > 0
        evaluations = Tuple(
            condition.prototype.check_function(condition, unit, parameters)
            for condition in table.conditions
        )
        new_state = table.table_data[evaluations]
        machine.state = new_state
    else
        new_state = old_state
    end

    if old_state == new_state
        machine.time_in_state += 1
    else
        machine.time_in_state = 1
    end
end

"""
A type of operational strategy that defines which parameters and components a strategy requires.
"""
Base.@kwdef struct OperationalStrategyType
    """Machine-readable name of the strategy."""
    name::String

    """Human-readable description that explains how to use the strategy."""
    description::String

    """Constructor method for the state machine used by the strategy."""
    sm_constructor::Function

    """A list of condition names that the strategy uses."""
    conditions::Vector{String}

    """Required parameters for the strategy including those for the conditions."""
    strategy_parameters::Dict{String,Any}

    """Components that the strategy requires for the correct order of execution.

    This differs from the component the conditions of the strategy require.
    """
    required_components::EnSysRequirements
end

OP_STRATS = Dict{String,OperationalStrategyType}()

include("strategies/economical_discharge.jl")
include("strategies/storage_driven.jl")
include("strategies/demand_driven.jl")
include("strategies/supply_driven.jl")
include("strategies/extended_storage_control.jl")

"""
    controller_for_strategy(strategy, parameters)

Construct the controller for the strategy of the given name using the given parameters.

# Arguments
- `strategy::String`: Must be an exact match to the name defined in the strategy's code file.
- `parameters::Dict{String, Any}`: Parameters for the configuration of the strategy. The
    names must match those in the default parameter values dictionary defined in the
    strategy's code file. Given values override default values.
# Returns
- `Controller`: The constructed controller for the given strategy.
"""
function controller_for_strategy(strategy::String, parameters::Dict{String,Any})::Controller
    if lowercase(strategy) == "default"
        return Controller("default", parameters, StateMachine(), Grouping())
    end

    if !(strategy in keys(OP_STRATS))
        throw(ArgumentError("Unknown strategy $strategy"))
    end

    # check if parameters given in input file for strategy are valid parameters:
    for key in keys(parameters)
        if !(key in keys(OP_STRATS[strategy].strategy_parameters)) && !(startswith(key, "_"))
            throw(ArgumentError("Unknown parameter in $strategy: $(key). Must be one of $(keys(OP_STRATS[strategy].strategy_parameters))"))
        end
    end

    params = merge(OP_STRATS[strategy].strategy_parameters, parameters)

    # load operation profile if path is given in input file
    if haskey(params, "operation_profile_path")
        if params["operation_profile_path"]  !== nothing
            params["operation_profile"] = Profile(params["operation_profile_path"])
        end
    end
    
    machine = OP_STRATS[strategy].sm_constructor(params)
    return Controller(strategy, params, machine, Grouping())
end

export Condition, TruthTable, StateMachine, link_control_with, controller_for_strategy