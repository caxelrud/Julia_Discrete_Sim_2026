# =============================================================================
# calendar.jl -- the event calendar of the simulation.
#
# The calendar is a binary min-heap of `Event`s ordered by the triple
# `(time, priority, seq)`: the earliest event first, ties broken by the priority
# of the event (a *smaller* number runs first, so `priority = 0` outranks
# `priority = 10`) and then by insertion order, which is what makes a run
# reproducible. Only the top of the heap is ever touched, so scheduling a
# process and taking the next event are both O(log n).
# =============================================================================

"""
    Event

One entry of the calendar: when it happens (`time`), how it ranks against other
events at the same instant (`priority`, smaller runs first), its insertion
`seq`, its `kind`, the id of the process it belongs to (`owner`, `0` when the
event runs a plain callback) and a free `payload`.

`cancelled` marks an event that was superseded (a process that was activated
before its timeout, an interrupted wait); `live` is `true` exactly while the
event sits in the calendar, which is what keeps the cancelled-event accounting
of the heap honest.
"""
mutable struct Event
    time::Float64
    priority::Int
    seq::Int
    kind::Symbol
    owner::Int
    payload::Any
    cancelled::Bool
    live::Bool
end

Event(time::Real, priority::Integer, seq::Integer, kind::Symbol, owner::Integer,
    payload = nothing) =
    Event(Float64(time), Int(priority), Int(seq), Sym(kind), Int(owner), payload, false, false)

"""`true` when `a` must be taken out of the calendar before `b`."""
function event_less(a::Event, b::Event)
    a.time == b.time || return a.time < b.time
    a.priority == b.priority || return a.priority < b.priority
    return a.seq < b.seq
end

Base.isless(a::Event, b::Event) = event_less(a, b)

function Base.show(io::IO, e::Event)
    print(io, "Event(:", e.kind, ", t=", round(e.time, digits = 6), ", prio=", e.priority,
        ", #", e.seq, ", owner=", e.owner, e.cancelled ? ", cancelled" : "", ")")
end

"""
    Calendar

Binary min-heap of pending [`Event`](@ref)s. `length(cal)` counts the live
events; cancelled events are dropped when they bubble to the top.
"""
mutable struct Calendar
    events::Vector{Event}
    cancelled::Int
end

Calendar() = Calendar(Event[], 0)

Base.isempty(cal::Calendar) = length(cal.events) - cal.cancelled == 0
Base.length(cal::Calendar) = length(cal.events) - cal.cancelled
Base.sizehint!(cal::Calendar, n::Integer) = (sizehint!(cal.events, n); cal)

@inline function _sift_up!(v::Vector{Event})
    i = length(v)
    @inbounds while i > 1
        parent = i >> 1
        event_less(v[i], v[parent]) || break
        v[i], v[parent] = v[parent], v[i]
        i = parent
    end
    return v
end

@inline function _sift_down!(v::Vector{Event}, i::Int = 1)
    n = length(v)
    @inbounds while true
        l = 2i
        r = l + 1
        best = i
        l <= n && event_less(v[l], v[best]) && (best = l)
        r <= n && event_less(v[r], v[best]) && (best = r)
        best == i && break
        v[i], v[best] = v[best], v[i]
        i = best
    end
    return v
end

"""Add an event to the calendar."""
function push_event!(cal::Calendar, ev::Event)
    push!(cal.events, ev)
    ev.live = true
    _sift_up!(cal.events)
    return ev
end

"""Drop cancelled events from the top of the heap until a live one surfaces."""
function _clean_top!(cal::Calendar)
    while !isempty(cal.events) && cal.events[1].cancelled
        _pop_root!(cal)
    end
    return cal
end

"""Pop the root of the heap, restore the heap property and fix the counters."""
function _pop_root!(cal::Calendar)
    v = cal.events
    root = v[1]
    last_index = length(v)
    if last_index == 1
        pop!(v)
    else
        v[1] = v[last_index]
        pop!(v)
        _sift_down!(v, 1)
    end
    root.live = false
    root.cancelled && (cal.cancelled -= 1)
    return root
end

"""The next live event, without removing it (`nothing` when the calendar is empty)."""
function peek_event(cal::Calendar)
    _clean_top!(cal)
    return isempty(cal.events) ? nothing : cal.events[1]
end

"""Remove and return the next live event (`nothing` when the calendar is empty)."""
function pop_event!(cal::Calendar)
    _clean_top!(cal)
    isempty(cal.events) && return nothing
    return _pop_root!(cal)
end

"""
    cancel_event!(cal, ev) -> Event

Cancel an event. Only an event that is still in the calendar counts, so calling
this on an event that has already been processed is harmless -- which matters
because a process keeps a reference to its last event.
"""
function cancel_event!(cal::Calendar, ev::Event)
    if ev.live && !ev.cancelled
        ev.cancelled = true
        cal.cancelled += 1
    end
    return ev
end

"""Time of the next event, or `Inf` when the calendar is empty."""
function next_time(cal::Calendar)
    ev = peek_event(cal)
    return ev === nothing ? Inf : ev.time
end

"""All pending events, in scheduling order (used by the trace and by the tests)."""
function calendar_snapshot(cal::Calendar)
    live = Event[e for e in cal.events if !e.cancelled]
    return sort!(live; lt = event_less)
end

"""Empty the calendar."""
function reset_calendar!(cal::Calendar)
    empty!(cal.events)
    cal.cancelled = 0
    return cal
end
