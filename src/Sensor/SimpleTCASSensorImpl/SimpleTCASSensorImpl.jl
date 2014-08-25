# Author: Youngjun Kim, youngjun@stanford.edu
# Date: 06/16/2014


module SimpleTCASSensorImpl

export
    initialize,
    step,

    updateSensor,

    SimpleTCASSensor,
    SimpleTCASSRState,
    SimpleTCASSensorInput,
    SimpleTCASSensorOutput


using AbstractSensorImpl
using AbstractSensorInterfaces
using CommonInterfaces

using Base.Test

import CommonInterfaces.initialize
import CommonInterfaces.step
import AbstractSensorInterfaces.updateSensor


type SimpleTCASSRState

    t::Float64
    x::Float64
    y::Float64
    h::Float64
    vx::Float64
    vy::Float64
    vh::Float64
end

type SimpleTCASSensorInput

    states::Vector{SimpleTCASSRState}
end

type SimpleTCASSensorOutput

    t::Float64

    r::Float64
    r_d::Float64

    a::Float64
    a_d::Float64

    h::Vector{Float64}
    h_d::Vector{Float64}
end

type SimpleTCASSensor <: AbstractSensor

    aircraft_number::Int

    states::Vector{SimpleTCASSRState}


    function SimpleTCASSensor(aircraft_number::Int)

        obj = new()

        obj.aircraft_number = aircraft_number

        return obj
    end
end


function updateSensor(sr::SimpleTCASSensor, input::SimpleTCASSensorInput)

    sr.states = input.states

    if sr.aircraft_number == 1
        intruder_number = 2
    else
        intruder_number = 1
    end

    t1, x1, y1, h1, vx1, vy1, vh1 = sr.states[sr.aircraft_number].t, sr.states[sr.aircraft_number].x, sr.states[sr.aircraft_number].y, sr.states[sr.aircraft_number].h, sr.states[sr.aircraft_number].vx, sr.states[sr.aircraft_number].vy, sr.states[sr.aircraft_number].vh

    t2, x2, y2, h2, vx2, vy2, vh2 = sr.states[intruder_number].t, sr.states[intruder_number].x, sr.states[intruder_number].y, sr.states[intruder_number].h, sr.states[intruder_number].vx, sr.states[intruder_number].vy, sr.states[intruder_number].vh

    #@test t1 == t2

    t = t1

    # assume delta t = 1 second
    # cross in the path in delta t is a corner case

    r = norm([(x1 - x2), (y1 - y2)])
    r_prev = norm([(x1 - vx1) - (x2 - vx2), (y1 - vy1) - (y2 - vy2)])
    r_d = r - r_prev

    a = abs(h1 - h2)
    a_prev = abs((h1 - vh1) - (h2 - vh2))
    a_d = a - a_prev

    h = [h1, h2]
    h_d = [vh1, vh2]

    return SimpleTCASSensorOutput(t, r, r_d, a, a_d, h, h_d)
end

step(sr::SimpleTCASSensor, input::SimpleTCASSensorInput) = updateSensor(sr, input)

function initialize(sr::SimpleTCASSensor)

end

end


