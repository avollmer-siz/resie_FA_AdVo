"""
Implementation of an energy system modeling the connection to a public grid of a certain medium.

Public grids are considered to have an unlimited amount of energy they can provide, but
might be limited in the power they can provide, although this behaviour is not yet
implemented. They exist to model real connections to a public grid that can provide any
remaining demand of energy or take in any excess of energy. To make it possible to model a
one-way connection they are split into two instances for providing or receiving energy and
must be handled as such in the input for constructing a project.
"""
Base.@kwdef mutable struct GridConnection <: ControlledSystem
    controller :: StateMachine
    sys_function :: SystemFunction
    medium :: MediumCategory

    input_interfaces :: InterfaceMap
    output_interfaces :: InterfaceMap

    draw_sum :: Float64
    load_sum :: Float64
end

function make_GridConnection(medium :: MediumCategory, is_source :: Bool) :: GridConnection
    return GridConnection(
        StateMachine(), # controller
        if is_source infinite_source else infinite_sink end, # sys_function
        medium, # medium
        InterfaceMap( # input_interfaces
            medium => nothing
        ),
        InterfaceMap( # output_interfaces
            medium => nothing
        ),
        0.0, # draw_sum,
        0.0, # load_sum
    )
end

function produce(unit :: GridConnection, parameters :: Dict{String, Any}, watt_to_wh :: Function)
    if unit.sys_function === infinite_source
        outface = unit.output_interfaces[unit.medium]
        # @TODO: if grids should be allowed to load storage systems, then the potential
        # must be handled here instead of being ignored
        balance, _ = balance_on(outface, outface.target)
        if balance < 0.0
            unit.draw_sum += balance
            add!(outface, abs(balance))
        end
    else
        inface = unit.input_interfaces[unit.medium]
        balance, _ = balance_on(inface, inface.source)
        if balance > 0.0
            unit.load_sum += balance
            sub!(inface, balance)
        end
    end
end

function specific_values(unit :: GridConnection, time :: Int) :: Vector{Tuple}
    return [
        ("Draw sum", "$(unit.draw_sum)"),
        ("Load sum", "$(unit.load_sum)")
    ]
end

export GridConnection, specific_values, make_GridConnection