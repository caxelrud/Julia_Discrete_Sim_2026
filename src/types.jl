# =============================================================================
# types.jl -- the data structures of the engine.
#
# All the structs of the core live in one file, in dependency order, because the
# two central types reference each other: a `Sim` owns its `Process`es and a
# `Process` schedules itself on its `Sim`. Declaring the types together (and all
# the behaviour afterwards, in `clock.jl`, `process.jl`, `resources.jl`, ...)
# lets every field carry its concrete type, which keeps the event loop free of
# dynamic dispatch.
# =============================================================================

## ---- statistics ---------------------------------------------------------------

"""
    Tally(metric; unit = :minutes, keep = 0)

Ordinary sample statistics of a series of observations (waiting times, service
times, sojourn times): count, mean, variance, minimum, maximum, and quantiles
when `keep > 0` holds the last `keep` samples.
"""
mutable struct Tally
    metric::Symbol
    unit::Symbol
    count::Int
    total::Float64
    sumsq::Float64
    lowest::Float64
    highest::Float64
    history::Vector{Float64}
    keep::Int
    since::Float64
end

"""
    TimeWeighted(metric; unit = :minutes)
    TimeWeighted(metric, initial)

Time-weighted statistics of a quantity that is only piecewise constant (queue
lengths, work in progress, inventory, the number of busy servers). The mean is
`∫ x dt / T`, so a queue that holds 5 jobs for one hour contributes five times as
much as a queue that holds 1 job for one hour.
"""
mutable struct TimeWeighted
    metric::Symbol
    unit::Symbol
    area::Float64
    area_sq::Float64
    duration::Float64
    value::Float64
    lowest::Float64
    highest::Float64
    observations::Int
    last::Float64
    since::Float64
    above::Dict{Float64,Float64}
end

"""
    Counter(metric; unit = :count)

Counts of discrete categories: how many jobs were completed, how many were
scrapped, how many units of each product were shipped.
"""
mutable struct Counter
    metric::Symbol
    unit::Symbol
    counts::Dict{Symbol,Int}
    order::Vector{Symbol}
end

"""
    Histogram(metric, edges; unit = :count)

Fixed-bin distribution of a series, with underflow/overflow buckets, so the
report can print a real distribution (and a P95) without keeping every sample.
"""
mutable struct Histogram
    metric::Symbol
    unit::Symbol
    edges::Vector{Float64}
    counts::Vector{Int}
    underflow::Int
    overflow::Int
end

"""
    Recorder(metric; unit = :count, limit = 20_000, decimation = 1)

A time series of a quantity at the moments it changes, decimated on the fly so a
long run stays printable: `times` and `values` always have the same length.
"""
mutable struct Recorder
    metric::Symbol
    unit::Symbol
    times::Vector{Float64}
    values::Vector{Float64}
    limit::Int
    decimation::Int
    added::Int
    last::Float64
end

## ---- trace --------------------------------------------------------------------

"""
    Trace(; limit = 200_000)

The event trace of a run: one row per recorded event, with the clock time, the
kind of event, the entity and the resource involved, the process that caused it,
a value and a note. It is what the Gantt chart, the throughput curve and the
"what happened to job 17" questions are answered from, and it plugs into
`Tables.jl`, so a table view of a run is one call away.
"""
mutable struct Trace
    times::Vector{Float64}
    kinds::Vector{Symbol}
    entities::Vector{Symbol}
    resources::Vector{Symbol}
    process_ids::Vector{Int}
    values::Vector{Float64}
    notes::Vector{Symbol}
    limit::Int
    dropped::Int
    enabled::Bool
end

## ---- process ------------------------------------------------------------------

"""
    Process

One coroutine of a model, as returned by [`spawn!`](@ref) / [`@process`](@ref).
A process is scheduled by its `sim` and is always in one of the `PROCESS_STATES`:
`:ready`, `:running`, `:waiting` (on the calendar), `:blocked` (on a resource),
`:passive` (until activated), `:finished`, `:failed` or `:cancelled`.

`attrs` is a `SymDict`, so a model can hang its own attributes on a process
(`p.attrs[:product] = :grade_a`) and a queue discipline can rank on them.
"""
mutable struct Process
    id::Int
    name::Symbol
    sim::Any
    task::Task
    go::Channel{Nothing}
    state::Symbol
    priority::Int
    parent::Int
    action::Symbol
    delay::Float64
    wake::Float64
    created::Float64
    finished::Float64
    activations::Int
    blocker::Any
    error::Any
    interruptions::Vector{Any}
    due::Float64
    service_estimate::Float64
    attrs::SymDict
    event::Any
end

## ---- simulation ----------------------------------------------------------------

"""
    SimConfig

Everything that governs a run: the `seed` of the random streams, `strict`
(rethrow a model error instead of recording it), the trace options, the safety
limits (`max_events`, `max_seconds`), the `time_unit` of the numbers the report
prints and the `horizon` of the run.
"""
Base.@kwdef mutable struct SimConfig
    seed::Int = 20260101
    strict::Bool = true
    trace_events::Bool = true
    trace_kinds::Vector{Symbol} = Symbol[]
    trace_limit::Int = 200_000
    max_events::Int = 20_000_000
    max_seconds::Float64 = 120.0
    time_unit::Symbol = :minutes
    horizon::Float64 = Inf
end

"""
    Sim

One simulation: the clock (`now`), the event calendar, the registry of
resources and statistics (both `SymDict`s), the named random streams, the trace
and the configuration. `σ[:queue]` reads a resource or a statistic by symbol,
and `σ.scenario` carries the scenario metadata of the run.

Processes are one-shot: a `Sim` is built by a model function, `run!` is called
on it, and a replication is simply a second `Sim`.
"""
mutable struct Sim
    name::Symbol
    now::Float64
    calendar::Calendar
    seq::Int
    config::SimConfig
    ready::Channel{Symbol}
    scheduler::Union{Nothing,Task}
    current::Any
    rngs::Dict{Symbol,Any}
    resources::SymDict
    stats::SymDict
    processes::Dict{Int,Process}
    trace::Trace
    hooks::Dict{Symbol,Vector{Any}}
    metrics::SymDict
    scenario::SymDict
    stop_reason::Symbol
    processed::Int
    created::Int
    resumed::Int
    warmup::Float64
    warmed::Bool
    forced::Bool
end

## ---- resources ----------------------------------------------------------------

"""
    Resource

A resource with `capacity` identical servers (machines, operators, berths,
tellers) and one queue per resource, served by the chosen `discipline`. All the
statistics that a queueing report needs are kept by the resource itself: the
waiting-time `Tally`, the service- and sojourn-time `Tally`s, the time-weighted
occupancy (`utilisation`) and queue length, the counters of grants,
preemptions, breakdowns and repairs, and the accumulated available and down time
(`availability`).
"""
mutable struct Resource
    name::Symbol
    kind::Symbol
    capacity::Int
    in_use::Int
    discipline::Symbol
    queue::Vector{Process}
    holders::Dict{Int,Float64}
    waiting_since::Dict{Int,Float64}
    wait::Tally
    service::Tally
    sojourn::Tally
    occupancy::TimeWeighted
    queue_length::TimeWeighted
    granted::Counter
    preemptions::Counter
    breakdowns::Counter
    repairs::Counter
    state::Symbol
    up_time::Float64
    down_time::Float64
    down_since::Float64
    last_change::Float64
end

"""
    Container

A bulk store with a continuous `level` (a tank, a silo, a buffer of coolant):
`fill!` blocks while the container would overflow, `drain!` blocks while it does
not hold enough, and the time-weighted level is recorded for the report.
"""
mutable struct Container
    name::Symbol
    unit::Symbol
    capacity::Float64
    level::Float64
    putters::Vector{Process}
    getters::Vector{Process}
    level_stat::TimeWeighted
    fills::Counter
    drains::Counter
    last_change::Float64
end

"""
    Store

A store of discrete items (pallets, orders, material handling units) with an
optional capacity and an optional matching `filter`: `store_item!` blocks while
the store is full, `retrieve!` blocks until a matching item arrives, so a store
is a Kanban buffer, a finished-goods yard or a parts supermarket.
"""
mutable struct Store
    name::Symbol
    capacity::Int
    items::Vector{Any}
    getters::Vector{Process}
    putters::Vector{Process}
    filter::Any
    count_stat::TimeWeighted
    stored::Counter
    retrieved::Counter
    last_change::Float64
end

## ---- random stream ------------------------------------------------------------

"""
    Stream

One named random stream of a simulation, backed by a `StableRNG` whose seed is
derived from the seed of the run and the name of the stream. Because the seed
depends on the *name*, two scenarios that use a stream called `:service` in the
same replication draw exactly the same variates: common random numbers are
structural, not an afterthought.
"""
mutable struct Stream
    name::Symbol
    rng::StableRNGs.StableRNG
    seed::Int
    draws::Int
    antithetic::Bool
end
