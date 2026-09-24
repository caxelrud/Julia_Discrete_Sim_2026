# =============================================================================
# trace.jl -- the event trace of a run.
#
# Every interesting moment of a model is recorded once (arrival, queue entry,
# service start, service end, fill, drain, breakdown, repair, shipment) with the
# clock time, the entity, the resource, the process that caused it and a value.
# The trace is the evidence behind every chart of the report -- the queue-length
# curve and the Gantt chart are both derived from it -- and it converts to a
# `Tables.jl` source in one call, so it can be written to CSV or shown as a table
# without any conversion code.
#
# The trace is bounded (`trace_limit`) so a ten-million-event run cannot exhaust
# memory; when the limit is reached the extra rows are counted in `dropped`.
# =============================================================================

"""`Trace(; limit = 200_000, enabled = true)` -- an empty trace."""
Trace(; limit::Integer = 200_000, enabled::Bool = true) =
    Trace(Float64[], Symbol[], Symbol[], Symbol[], Int[], Float64[], Symbol[], Int(limit), 0,
        enabled)

"""The entity a process carries (`:entity` attribute, its name by default)."""
entity_of(p::Process) = get(p.attrs, :entity, p.name)

"""
    trace!(σ, kind, entity = :none, resource = :none; value = 0.0, note = :none, process_id = 0)

Record one event. Does nothing when the trace is disabled, when the event kind is
filtered out (`config.trace_kinds`) or when the trace is full.
"""
function trace!(σ::Sim, kind::Symbol, entity::Symbol = :none, resource::Symbol = :none;
    value::Real = 0.0, note::Symbol = :none, process_id::Integer = 0)
    t = σ.trace
    t.enabled || return nothing
    kinds = σ.config.trace_kinds
    isempty(kinds) || Sym(kind) in kinds || return nothing
    if length(t.times) >= t.limit
        t.dropped += 1
        return nothing
    end
    push!(t.times, σ.now)
    push!(t.kinds, Sym(kind))
    push!(t.entities, Sym(entity))
    push!(t.resources, Sym(resource))
    push!(t.process_ids, Int(process_id))
    push!(t.values, Float64(value))
    push!(t.notes, Sym(note))
    return nothing
end

"""Record an event for a process."""
trace!(σ::Sim, kind::Symbol, p::Process, resource::Symbol = :none; kwargs...) =
    trace!(σ, kind, entity_of(p), resource; process_id = p.id, kwargs...)

"""Number of rows in the trace."""
n_of(t::Trace) = length(t.times)

"""`true` when the trace hit its limit and lost rows."""
is_truncated(t::Trace) = t.dropped > 0

"""Indices of the trace rows of one event kind."""
rows_of(t::Trace, kind::Symbol) = findall(==(Sym(kind)), t.kinds)

"""Indices of the trace rows of one entity."""
rows_of_entity(t::Trace, entity::Symbol) = findall(==(Sym(entity)), t.entities)

"""How many events of each kind the trace holds (a `SymDict`)."""
function trace_summary(t::Trace)
    d = SymDict()
    for k in t.kinds
        d[k] = get(d, k, 0) + 1
    end
    return d
end

"""The trace of a simulation as a `Tables.jl` source."""
trace_table(σ::Sim) = TraceTable(σ.trace)

"""The trace of a simulation as a vector of rows (ready for a CSV or a table)."""
function trace_rows(t::Trace; limit::Integer = typemax(Int))
    n = min(length(t.times), Int(limit))
    return [(time = t.times[i], kind = t.kinds[i], entity = t.entities[i],
        resource = t.resources[i], process = t.process_ids[i], value = t.values[i],
        note = t.notes[i]) for i in 1:n]
end

"""
    TraceTable

`Tables.jl` view of a [`Trace`](@ref): the columns `:time`, `:kind`, `:entity`,
`:resource`, `:process`, `:value` and `:note`.
"""
struct TraceTable
    trace::Trace
end

Tables.istable(::Type{TraceTable}) = true
Tables.columnaccess(::Type{TraceTable}) = true
Tables.columns(t::TraceTable) = t
Tables.schema(::TraceTable) = Tables.Schema(
    (:time, :kind, :entity, :resource, :process, :value, :note),
    (Float64, Symbol, Symbol, Symbol, Int, Float64, Symbol))
Tables.columnnames(::TraceTable) =
    (:time, :kind, :entity, :resource, :process, :value, :note)

Base.length(t::TraceTable) = length(t.trace.times)

function Tables.getcolumn(t::TraceTable, nm::Symbol)
    nm === :time && return t.trace.times
    nm === :kind && return t.trace.kinds
    nm === :entity && return t.trace.entities
    nm === :resource && return t.trace.resources
    nm === :process && return t.trace.process_ids
    nm === :value && return t.trace.values
    nm === :note && return t.trace.notes
    throw(ArgumentError("the trace has no column :$nm"))
end

Tables.getcolumn(t::TraceTable, i::Int) =
    Tables.getcolumn(t, Tables.columnnames(t)[i])

## ---- derived views -------------------------------------------------------------

"""Occupation segments of a resource: `(start, stop, entity)` triples.

Taken from the `:acquire`/`:release` pairs of the trace, which is what the Gantt
chart of the report draws.
"""
function occupation_segments(t::Trace, resource::Symbol; limit::Integer = 200)
    r = Sym(resource)
    open_segments = Dict{Int,Float64}()
    segments = Tuple{Float64,Float64,Symbol}[]
    for i in eachindex(t.times)
        t.resources[i] === r || continue
        if t.kinds[i] === :acquire
            open_segments[t.process_ids[i]] = t.times[i]
        elseif t.kinds[i] === :release
            start = pop!(open_segments, t.process_ids[i], t.times[i])
            push!(segments, (start, t.times[i], t.entities[i]))
            length(segments) >= limit && break
        end
    end
    return segments
end

"""
    completions(t, kind = :ship, dt = 1.0) -> (times, counts)

Number of events of a kind per `dt` time units: the throughput curve of the run.
"""
function completions(t::Trace, kind::Symbol = :ship, dt::Real = 1.0)
    idx = rows_of(t, kind)
    isempty(idx) && return (Float64[], Float64[])
    t_max = t.times[idx[end]]
    bins = floor(Int, t_max / dt) + 1
    counts = zeros(Float64, bins)
    for i in idx
        b = min(floor(Int, t.times[i] / dt) + 1, bins)
        counts[b] += 1.0
    end
    return (collect(0.0:dt:(dt * (bins - 1))), counts ./ dt)
end

"""Values recorded together with one event kind."""
values_of(t::Trace, kind::Symbol) = Float64[t.values[i] for i in rows_of(t, kind)]

"""Number of events recorded after time `t0` (used with a warmup)."""
events_after(t::Trace, t0::Real) = count(>=(Float64(t0)), t.times)

"""Time of the last recorded event (`0.0` for an empty trace)."""
last_time(t::Trace) = isempty(t.times) ? 0.0 : t.times[end]

"""Empty the trace (keeps its limit and its enabled flag)."""
function reset_trace!(t::Trace)
    empty!(t.times)
    empty!(t.kinds)
    empty!(t.entities)
    empty!(t.resources)
    empty!(t.process_ids)
    empty!(t.values)
    empty!(t.notes)
    t.dropped = 0
    return t
end