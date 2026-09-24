# =============================================================================
# clock.jl -- the simulation clock, the scheduler and the run loop.
#
# The engine is a standard next-event simulator: `run!` repeatedly takes the
# earliest event from the calendar, moves the clock to its time and lets the
# owner of the event act. An event either belongs to a process (which is then
# *resumed* on the Julia task that backs it, see `process.jl`) or carries a plain
# callback, which is how the fast event-based models and the warmup reset are
# implemented.
#
# Two features of this file are worth pointing out:
#
# * **Determinism.** A run is a pure function of its seed: the calendar orders
#   ties by insertion (`seq`), and every stream is named, so the same seed gives
#   the same numbers on any machine.
# * **Safety limits.** A model bug (a process that never finishes) cannot hang a
#   pipeline: `max_events` and `max_seconds` stop the run and set `stop_reason`.
# =============================================================================

"""
    Sim(name = :simulation; scenario = nothing, kwargs...)

Build a simulation. Every other keyword goes to [`SimConfig`](@ref), so
`Sim(:shop; seed = 7, horizon = 2000.0)` is the usual call. `scenario` is a
symbol-keyed record of the scenario metadata (`:name`, `:label`, parameter
overrides) which travels with the run into the report.
"""
function Sim(name::Symbol = :simulation; scenario = nothing, kwargs...)
    known = Set{Symbol}(fieldnames(SimConfig))
    cfg = Dict{Symbol,Any}()
    for (k, v) in kwargs
        key = Sym(k)
        key ∈ known || throw(ArgumentError(string("Sim does not know the keyword :", key,
            "; known keywords are ", join(sort(code_string.(collect(known))), ", "))))
        cfg[key] = v
    end
    σ = Sim(Sym(name), 0.0, Calendar(), 0, SimConfig(; cfg...), Channel{Symbol}(0), nothing,
        nothing, Dict{Symbol,Any}(), SymDict(), SymDict(), Dict{Int,Process}(),
        Trace(; limit = get(cfg, :trace_limit, 200_000),
            enabled = get(cfg, :trace_events, true)),
        Dict{Symbol,Vector{Any}}(), SymDict(),
        scenario === nothing ? SymDict() : SymDict(scenario), :none, 0, 0, 0, 0.0, false, false)
    sizehint!(σ.calendar, 1024)
    return σ
end

Sim(name::AbstractString; kwargs...) = Sim(Sym(name); kwargs...)

"""The current simulation time (`clock_time(σ) === σ.now`)."""
clock_time(σ::Sim) = σ.now

"""Number of events still scheduled."""
pending(σ::Sim) = length(σ.calendar)

"""Number of events processed so far."""
events_processed(σ::Sim) = σ.processed

"""The time unit the model counts in (`:minutes` by default)."""
time_unit(σ::Sim) = σ.config.time_unit

"""The seed of the run."""
seed_of(σ::Sim) = σ.config.seed

"""Why the last `run!` stopped (`:empty_calendar`, `:horizon`, `:stop`, ...)."""
stop_reason(σ::Sim) = σ.stop_reason

"""`true` once the simulation has been stopped explicitly."""
is_stopped(σ::Sim) = σ.stop_reason !== :none

"""
    σ[symbol] -> Any

Read a resource, a statistic or a metric by symbol: `σ[:line]` is the resource
named `:line`, `σ[:wait]` the statistic named `:wait`. Resources, statistics and
metrics share one namespace, so the report can read a key without knowing which
of the three produced it.
"""
function Base.getindex(σ::Sim, key)
    k = Sym(key)
    haskey(σ.resources, k) && return σ.resources[k]
    haskey(σ.stats, k) && return σ.stats[k]
    haskey(σ.metrics, k) && return σ.metrics[k]
    throw(KeyError(k))
end

Base.haskey(σ::Sim, key) = haskey(σ.resources, key) || haskey(σ.stats, key) ||
                           haskey(σ.metrics, key)

"""Register a resource under its own name and return it."""
function resource!(σ::Sim, r::Resource)
    σ.resources[r.name] = r
    return r
end

resource!(σ::Sim, c::Container) = (σ.resources[c.name] = c; c)
resource!(σ::Sim, s::Store) = (σ.resources[s.name] = s; s)

"""Register a statistic under a name and return it."""
function statistic!(σ::Sim, name, stat)
    σ.stats[Sym(name)] = stat
    return stat
end

"""Register a resource or a statistic under a symbol (dispatch on the type)."""
register!(σ::Sim, name, x) = statistic!(σ, name, x)

"""Set a system metric of the run (`metric!(σ, :fill_rate, 0.97)`)."""
function metric!(σ::Sim, name, value)
    σ.metrics[Sym(name)] = value
    return value
end

"""Read a system metric, a statistic or a resource by symbol."""
function metric(σ::Sim, name)
    k = Sym(name)
    haskey(σ.metrics, k) && return σ.metrics[k]
    haskey(σ.stats, k) && return σ.stats[k]
    haskey(σ.resources, k) && return σ.resources[k]
    throw(KeyError(k))
end

## ---- scheduling ----------------------------------------------------------------

"""
    schedule_at!(σ, time; kind = :custom, owner = 0, priority = 0, payload = nothing)

Put an event in the calendar at an absolute `time`. `owner = 0` means the payload
is a callback `(σ, event)`; any other value is the id of the process to resume.
Smaller `priority` numbers run first among events at the same instant.
"""
function schedule_at!(σ::Sim, time::Real; kind::Symbol = :custom, owner::Integer = 0,
    priority::Integer = 0, payload = nothing)
    σ.seq += 1
    ev = Event(Float64(time), priority, σ.seq, Sym(kind), owner, payload)
    push_event!(σ.calendar, ev)
    return ev
end

"""
    schedule!(σ, delay = 0.0; kwargs...)

Put an event in the calendar `delay` time units from now (see
[`schedule_at!`](@ref)).
"""
schedule!(σ::Sim, delay::Real = 0.0; kwargs...) = schedule_at!(σ, σ.now + delay; kwargs...)

"""
    callback!(σ, delay, f, args...; kind = :custom, priority = 0)

Run `f(σ, args...)` `delay` time units from now, without a process. This is the
event-based alternative to [`@process`](@ref): one heap entry and one function
call, which is how the very large models stay fast.
"""
function callback!(σ::Sim, delay::Real, f::Base.Callable, args...; kind::Symbol = :custom,
    priority::Integer = 0)
    return schedule!(σ, delay; kind = kind, owner = 0, priority = priority, payload = (f, args))
end

"""Time of the next scheduled event (`Inf` when nothing is pending)."""
next_time(σ::Sim) = next_time(σ.calendar)

## ---- the run loop --------------------------------------------------------------

"""
    step!(σ) -> Event | nothing

Process exactly one event: move the clock to its time and either resume the
process that owns it or run the callback it carries.
"""
function step!(σ::Sim)
    ev = pop_event!(σ.calendar)
    ev === nothing && return nothing
    σ.now = ev.time
    σ.processed += 1
    if ev.owner == 0
        payload = ev.payload
        if payload isa Tuple && length(payload) == 2 && payload[1] isa Function
            payload[1](σ, payload[2]...)
        elseif payload isa Function
            payload(σ)
        end
    else
        p = get(σ.processes, ev.owner, nothing)
        if p !== nothing && p.event === ev
            p.event = nothing                     # the event has been consumed
            if p.state !== :cancelled && p.state !== :finished
                resume!(σ, p)
            end
        end
    end
    return ev
end

"""
    run!(σ; until = σ.config.horizon, max_events, max_seconds) -> Sim

Run the simulation. Events are processed in time order until the calendar is
empty, the horizon `until` is passed, the run is stopped with `stop!` or one of
the safety limits is reached; `stop_reason` says which of those happened.
"""
function run!(σ::Sim; until::Real = σ.config.horizon,
    max_events::Int = σ.config.max_events, max_seconds::Real = σ.config.max_seconds)
    σ.scheduler = current_task()
    t0 = time()
    target = Float64(until)
    while true
        σ.forced && break
        σ.processed >= max_events && (σ.stop_reason = :max_events; break)
        (time() - t0) >= max_seconds && (σ.stop_reason = :wall_clock; break)
        isempty(σ.calendar) && (σ.stop_reason = :empty_calendar; break)
        peek_event(σ.calendar).time > target && (σ.stop_reason = :horizon; break)
        step!(σ)
    end
    return σ
end

run!(σ::Sim, horizon::Real; kwargs...) = run!(σ; until = horizon, kwargs...)

"""
    advance!(σ, delay) -> Sim

Move the clock forward by `delay`, processing every event that falls in the
interval. The building block of an interactive notebook: advance, look at the
system, advance again.
"""
function advance!(σ::Sim, delay::Real)
    target = σ.now + delay
    while true
        ev = peek_event(σ.calendar)
        (ev === nothing || ev.time > target) && break
        step!(σ)
    end
    σ.now = max(σ.now, target)
    return σ
end

"""Stop the run at the next chance, with a reason recorded in `stop_reason`."""
function stop!(σ::Sim, reason::Symbol = :stop)
    σ.forced = true
    σ.stop_reason = Sym(reason)
    return σ
end

"""Forget the calendar, the clock and the statistics of a run (keep the resources)."""
function reset!(σ::Sim; clock::Bool = true)
    reset_calendar!(σ.calendar)
    empty!(σ.processes)
    σ.seq = 0
    σ.processed = 0
    σ.created = 0
    σ.resumed = 0
    σ.stop_reason = :none
    σ.forced = false
    σ.warmed = false
    clock && (σ.now = 0.0)
    return σ
end

## ---- warmup --------------------------------------------------------------------

"""
    warmup!(σ, t0) -> Sim

Reset every statistic at time `t0`, so the transient part of a run does not
pollute the steady-state numbers. Implemented as an ordinary callback, which is
why it composes with everything else.

```julia
σ = Sim(:queue; horizon = 5000.0)
warmup!(σ, 500.0)                  # the first 500 time units are discarded
```
"""
function warmup!(σ::Sim, t0::Real)
    σ.warmup = Float64(t0)
    t0 > 0 && callback!(σ, t0, _do_warmup!, t0; kind = :warmup_end, priority = -1)
    return σ
end

function _do_warmup!(σ::Sim, t0)
    σ.warmed = true
    reset_statistics!(σ)
    emit!(σ, :warmup_end, t0)
    return nothing
end

"""The span of the run that the statistics actually cover."""
measured_span(σ::Sim) = max(σ.now - σ.warmup, eps())

function Base.show(io::IO, σ::Sim)
    return print(io, "Sim(:", σ.name, ", t=", round(σ.now, digits = 4), " ",
        code_string(σ.config.time_unit), ", events=", σ.processed, ", pending=",
        pending(σ), ", processes=", length(σ.processes), ", stop=:", σ.stop_reason, ")")
end


"""Register a callback to run whenever `kind` is emitted (see [`emit!`](@ref))."""
function on!(σ::Sim, kind::Symbol, f::Base.Callable)
    push!(get!(σ.hooks, Sym(kind), Any[]), f)
    return f
end

"""Emit an event of a kind: every callback registered with `on!` runs right away."""
function emit!(σ::Sim, kind::Symbol, payload = nothing)
    hooks = get(σ.hooks, Sym(kind), nothing)
    hooks === nothing && return 0
    for f in hooks
        f(σ, payload)
    end
    return length(hooks)
end