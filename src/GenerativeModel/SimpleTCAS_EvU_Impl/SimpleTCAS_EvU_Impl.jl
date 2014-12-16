# Author: Ritchie Lee, ritchie.lee@sv.cmu.@schedule
# Date: 12/11/2014


module SimpleTCAS_EvU_Impl

using Base.Test
using Encounter
using EncounterDBN
using PilotResponse
using DynamicModel
using WorldModel
using Sensor
using CollisionAvoidanceSystem
using Simulator

using RNGTools

import Base.convert

export SimpleTCAS_EvU_params, SimpleTCAS_EvU, initialize, step, get

type SimpleTCAS_EvU_params
  #global params: remains constant per sim
  encounter_number::Int64 #encounter number in file
  nmac_r::Float64 #NMAC radius in feet
  nmac_h::Float64 #NMAC vertical separation, in feet
  maxsteps::Int64 #maximum number of steps in sim
  nmac_reward::Float64 #reward bonus for achieving an NMAC
  number_of_aircraft::Int64 #number of aircraft  #FIXME: This scenario will break if number_of_aircraft != 2
  encounter_seed::Uint64 #Seed for generating encounters
  action_seed::Union(Nothing,Uint32) #Seed for generating actions, nothing=don't reset
  pilotResponseModel::Symbol #{:SimplePR, :StochasticLinear}

  #Defines behavior of CorrAEMDBN.  Read from file or generate samples on-the-fly
  command_method::Symbol #:DBN=sampled from DBN or :ENC=from encounter file

  #these are to define CorrAEM:
  encounter_file::String #Path to encounter file
  initial_sample_file::String #Path to initial sample file
  transition_sample_file::String #Path to transition sample file
end

type SimpleTCAS_EvU
  params::SimpleTCAS_EvU_params

  #sim objects: contains state that changes throughout sim run
  em::CorrAEMDBN
  pr::Vector{Union(SimplePilotResponse,StochasticLinearPR)}
  dm::Vector{SimpleADM}
  wm::AirSpace
  sr::Vector{Union(SimpleTCASSensor,Nothing)}
  cas::Vector{Union(SimpleTCAS,Nothing)}

  #sim states: changes throughout simulation run
  action_counter::Uint32 #global for new random seed
  t::Int64 #current time in the simulation
  vmd::Float64 #minimum vertical distance so far
  hmd::Float64 #minimum horizontal distance so far
  md::Float64 #combined miss distance metric

  #empty constructor
  function SimpleTCAS_EvU(p::SimpleTCAS_EvU_params)
    @test p.number_of_aircraft == 2 #Only supports 2 aircraft for now

    sim = new()
    sim.params = p

    srand(p.encounter_seed) #There's a rand inside generateEncounter, need to control it
    sim.em = CorrAEMDBN(p.number_of_aircraft, p.encounter_file, p.initial_sample_file,
                    p.transition_sample_file,
                    p.encounter_number,p.command_method)

    if p.pilotResponseModel == :SimplePR
      sim.pr = SimplePilotResponse[ SimplePilotResponse() for i=1:p.number_of_aircraft ]
    elseif p.pilotResponseModel == :StochasticLinear
      sim.pr = StochasticLinearPR[ StochasticLinearPR() for i=1:p.number_of_aircraft ]
    else
      error("SimpleTCAS_EvU_Impl: No such pilot response model")
    end

    sim.dm = SimpleADM[ SimpleADM(number_of_substeps=1) for i=1:p.number_of_aircraft ]
    sim.wm = AirSpace(p.number_of_aircraft)
    sim.sr = Union(SimpleTCASSensor,Nothing)[ SimpleTCASSensor(1), nothing ]
    sim.cas = Union(SimpleTCAS,Nothing)[ SimpleTCAS(), nothing ]

    sim.action_counter = uint32(0)
    sim.t = 0
    sim.vmd = typemax(Float64)
    sim.hmd = typemax(Float64)
    sim.md = typemax(Float64)

    return sim
  end
end

convert(::Type{StochasticLinearPRCommand}, command::Union(CorrAEMCommand, LLAEMCommand)) = StochasticLinearPRCommand(command.t, command.v_d, command.h_d, command.psi_d, 1.0)
convert(::Type{SimpleADMCommand}, command::StochasticLinearPRCommand) = SimpleADMCommand(command.t, command.v_d, command.h_d, command.psi_d)

function getvhdist(wm::AbstractWorldModel)
  states_1,states_2 = WorldModel.getAll(wm) #states::Vector{ASWMState}
  x1, y1, h1 = states_1.x, states_1.y, states_1.h
  x2, y2, h2 = states_2.x, states_2.y, states_2.h

  vdist = abs(h2-h1)
  hdist = norm([(x2-x1),(y2-y1)])

  return vdist,hdist
end

function isNMAC(sim::SimpleTCAS_EvU)
  vdist,hdist = getvhdist(sim.wm,s)
  return  hdist <= sim.params.nmac_r && vdist <= sim.params.nmac_h
end

function isTerminal(sim::SimpleTCAS_EvU)
  states_1,states_2 = WorldModel.getAll(sim.wm) #states::Vector{ASWMState}
  t = states_1.t

  return t >= sim.params.maxsteps
end

isEndState(sim::SimpleTCAS_EvU) = isNMAC(sim) || isTerminal(sim)

function initialize(sim::SimpleTCAS_EvU)

  if sim.params.action_seed != nothing #reset if specified
    sim.action_counter = sim.params.action_seed
  else #otherwise, randomize
    sim.action_counter = uint32(hash(time()))
  end

  aem = sim.em
  wm, pr, adm, cas, sr = sim.wm, sim.pr, sim.dm, sim.cas, sim.sr

  EncounterDBN.initialize(aem)

  for i = 1:sim.params.number_of_aircraft
    initial = EncounterDBN.getInitialSample(aem, i)
    state = DynamicModel.initialize(adm[i], convert(SimpleADMInitialState, initial))
    WorldModel.initialize(wm, i, convert(ASWMState, state))

    # If aircraft has a CAS
    if sr[i] != nothing && cas[i] != nothing
      Sensor.initialize(sr[i])
      CollisionAvoidanceSystem.initialize(cas[i])
    end

    PilotResponse.initialize(pr[i])
  end

  sim.t = 0
  EncounterDBN.initialize(aem)

  sim.vmd, sim.hmd = getvhdist(wm)
  sim.md = getMissDistance(sim.params.nmac_h,sim.params.nmac_r,sim.vmd,sim.hmd)

  return
end

function step(sim::SimpleTCAS_EvU)
  wm, pr, adm, cas, sr = sim.wm, sim.pr, sim.dm, sim.cas, sim.sr

  logProb = 0.0 #track the probabilities in this update

  cmdLogProb = EncounterDBN.step(aem)
  logProb += cmdLogProb #TODO? distribute this by aircraft?

  states = WorldModel.getAll(wm)

  for i = 1:sim.params.number_of_aircraft

    #intended command
    command = EncounterDBN.get(aem,i)

    #If aircraft is equipped with a CAS
    if sr[i] != nothing && cas[i] != nothing
      output = Sensor.step(sr[i], convert(SimpleTCASSensorInput, states))
      RA = CollisionAvoidanceSystem.step(cas[i], convert(SimpleTCASInput, output))
    else
      RA = nothing
    end

    response = PilotResponse.step(pr[i], convert(StochasticLinearPRCommand, command), convert(SimplePRResolutionAdvisory, RA))
    logProb += log(response.prob) #this will break if response is not SimplePRCommand
    state = DynamicModel.step(adm[i], convert(SimpleADMCommand, response))
    WorldModel.step(wm, i, convert(ASWMState, state))
  end

  WorldModel.updateAll(wm)

  sim.t += 1

  return logProb
end

getMissDistance(nmac_h,nmac_r,vmd,hmd) = max(hmd*(nmac_h/nmac_r),vmd)

end #module



