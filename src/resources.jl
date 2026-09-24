# =============================================================================
# resources.jl -- what the entities compete for.
#
# Three objects cover the whole of discrete-event modelling practice:
#
# | object | what it models | blocking calls |
# |---|---|---|
# | `Resource` | `capacity` identical servers, one queue | `request!`, `release!`, `use!`, `with!` |
# | `Container` | a bulk level (tank, silo, buffer) | `fill!`, `drain!` |
# | `Store` | discrete items (pallets, orders, Kanban) | `store_item!`, `retrieve!` |
#
# Each of them keeps its own statistics -- waiting times, service times, sojourn
# times, time-weighted occupancy and queue length, and counters of grants,
# preemptions, breakdowns and repairs -- so a report can print a queueing
# analysis of a model without the model having recorded anything itself.
#
# The queue of a `Resource` is served by a discipline: `:fifo` (default),
# `:lifo`, `:priority` (smaller `priority` first), `:spt` (shortest processing
# time first, using the requesting process' service estimate), `:srpt`, `:edd`
# (earliest due date) and `:random`.
# =============================================================================

## ---- construction --------------------------------------------------------------

"""
    Resource(name; capacity = 1, kind = :server, discipline = :fifo) -> Resource

A resource with `capacity` identical servers. `kind` is a vocabulary symbol used
by the report (`:machine`, `:operator`, `:berth`, ...) and `discipline` is the
queue discipline (see the header of this file). Register it with
`resource!(σ, r)` or let a model builder do it.
"""
function Resource(name::Symbol; capacity::Integer = 1, kind::Symbol = :server,
    discipline::Symbol = :fifo)
    capacity >= 1 || throw(ArgumentError("a resource needs capacity >= 1"))
    is_discipline(discipline) || throw(ArgumentError(string("unknown queue discipline :",
        Sym(discipline), "; known: ", join(code_string.(DISCIPLINES), ", "))))
    return Resource(Sym(name), Sym(kind), Int(capacity), 0, Sym(discipline), Process[],
        Dict{Int,Float64}(), Dict{Int,Float64}(), Tally(:wait; unit = :minutes),
        Tally(:service; unit = :minutes), Tally(:sojourn; unit = :minutes),
        TimeWeighted(:utilisation; unit = :ratio), TimeWeighted(:queue_length),
        Counter(:granted; unit = :count), Counter(:preemptions; unit = :count),
        Counter(:breakdowns; unit = :count), Counter(:repairs; unit = :count), :idle,
        0.0, 0.0, 0.0, 0.0)
end

Resource(name::AbstractString; kwargs...) = Resource(Sym(name); kwargs...)

"""
    Container(name; capacity = Inf, level = 0.0, unit = :count) -> Container

A bulk store: `fill!` blocks while the container would overflow, `drain!` blocks
while it does not hold enough. Its time-weighted level is recorded, so
`σ[:tank].level_stat` answers "what was the average stock?".
"""
function Container(name::Symbol; capacity::Real = Inf, level::Real = 0.0,
    unit::Symbol = :count)
    capacity > 0 || throw(ArgumentError("a container needs a positive capacity"))
    0 <= level <= capacity || throw(ArgumentError("the initial level must fit the capacity"))
    return Container(Sym(name), Sym(unit), Float64(capacity), Float64(level), Process[],
        Process[], TimeWeighted(:level; unit = Sym(unit)), Counter(:fills; unit = :count),
        Counter(:drains; unit = :count), 0.0)
end

Container(name::AbstractString; kwargs...) = Container(Sym(name); kwargs...)

"""
    Store(name; capacity = typemax(Int), filter = nothing) -> Store

A store of discrete items. `store_item!` blocks while the store is full,
`retrieve!` blocks until a matching item is there; with a `filter` (a predicate on
the item) the store becomes a parts supermarket with class-based retrieval.
"""
function Store(name::Symbol; capacity::Integer = typemax(Int), filter = nothing)
    return Store(Sym(name), Int(capacity), Any[], Process[], Process[],
        filter === nothing ? :all : filter, TimeWeighted(:count),
        Counter(:stored; unit = :count), Counter(:retrieved; unit = :count), 0.0)
end

Store(name::AbstractString; kwargs...) = Store(Sym(name); kwargs...)

## ---- bookkeeping ---------------------------------------------------------------

"""Update the time-weighted statistics of a resource up to `σ.now`."""
function _touch!(σ::Sim, r::Resource)
    dt = σ.now - r.last_change
    dt <= 0 && return r
    observe!(r.occupancy, r.in_use / max(r.capacity, 1), dt)
    observe!(r.queue_length, length(r.queue), dt)
    if r.state === :maintenance || r.state === :offline
        r.down_time += dt
    else
        r.up_time += dt
    end
    r.last_change = σ.now
    return r
end

function _touch!(σ::Sim, c::Container)
    dt = σ.now - c.last_change
    dt <= 0 && return c
    observe!(c.level_stat, c.level, dt)
    c.last_change = σ.now
    return c
end

function _touch!(σ::Sim, s::Store)
    dt = σ.now - s.last_change
    dt <= 0 && return s
    observe!(s.count_stat, length(s.items), dt)
    s.last_change = σ.now
    return s
end

"""`true` while the resource can serve (not in maintenance and not offline)."""
is_available(r::Resource) = r.state ∉ (:maintenance, :offline)

"""Fraction of the elapsed time the resource was available."""
availability(r::Resource) = (r.up_time + r.down_time) == 0 ? 1.0 :
                            r.up_time / (r.up_time + r.down_time)

"""Mean number of servers in use."""
mean_in_use(r::Resource) = mean(r.occupancy) * r.capacity

"""Time-weighted mean queue length of a resource."""
mean_queue_length(r::Resource) = mean(r.queue_length)

"""Time-weighted utilisation (fraction of the servers that are busy)."""
utilisation(r::Resource) = mean(r.occupancy)

"""Mean waiting time of the processes that requested the resource."""
mean_wait(r::Resource) = mean(r.wait)

"""Mean service time of the resource."""
mean_service(r::Resource) = mean(r.service)

"""Mean sojourn time (wait plus service) of the resource."""
mean_sojourn(r::Resource) = mean(r.sojourn)

"""How many processes are waiting right now."""
queue_length(r::Resource) = length(r.queue)

"""How many servers are busy right now."""
in_use(r::Resource) = r.in_use

"""State of the resource as a vocabulary symbol."""
state_of(r::Resource) = r.state

"""The `SymDict` the report renders for a resource."""
function summary_of(r::Resource)
    d = SymDict()
    d[:kind] = :resource
    d[:metric] = r.name
    d[:unit] = :ratio
    d[:name] = r.name
    d[:resource_kind] = r.kind
    d[:capacity] = r.capacity
    d[:discipline] = r.discipline
    d[:in_use] = r.in_use
    d[:queue_length] = length(r.queue)
    d[:utilisation] = utilisation(r)
    d[:availability] = availability(r)
    d[:mean_queue_length] = mean_queue_length(r)
    d[:mean_wait] = mean_wait(r)
    d[:mean_service] = mean_service(r)
    d[:mean_sojourn] = mean_sojourn(r)
    d[:mean_in_use] = mean_in_use(r)
    d[:granted] = total_of(r.granted)
    d[:preemptions] = total_of(r.preemptions)
    d[:breakdowns] = total_of(r.breakdowns)
    d[:repairs] = total_of(r.repairs)
    d[:state] = r.state
    d[:adequate] = true
    return d
end

"""Forget the statistics of a resource (used by `warmup!`)."""
function reset_resource_statistics!(r::Resource, t0::Real)
    reset_statistic!(r.wait, t0)
    reset_statistic!(r.service, t0)
    reset_statistic!(r.sojourn, t0)
    reset_statistic!(r.occupancy, t0)
    reset_statistic!(r.queue_length, t0)
    reset_statistic!(r.granted, t0)
    reset_statistic!(r.preemptions, t0)
    reset_statistic!(r.breakdowns, t0)
    reset_statistic!(r.repairs, t0)
    r.up_time = 0.0
    r.down_time = 0.0
    r.last_change = t0
    return r
end

reset_resource_statistics!(c::Container, t0::Real) =
    (reset_statistic!(c.level_stat, t0); reset_statistic!(c.fills, t0);
     reset_statistic!(c.drains, t0); c.last_change = t0; c)

reset_resource_statistics!(s::Store, t0::Real) =
    (reset_statistic!(s.count_stat, t0); reset_statistic!(s.stored, t0);
     reset_statistic!(s.retrieved, t0); s.last_change = t0; s)

## ---- Resource: acquire and release ---------------------------------------------

"""Free capacity of a resource right now."""
free_capacity(r::Resource) = r.capacity - r.in_use

"""`true` when the given process holds the resource."""
holds(r::Resource, p::Process) = haskey(r.holders, p.id)

"""Index of the waiter the discipline picks next (0 when the queue is empty)."""
function next_waiter_index(σ::Sim, r::Resource)
    isempty(r.queue) && return 0
    d = r.discipline
    d === :fifo && return 1
    d === :lifo && return length(r.queue)
    d === :priority && return argmin([p.priority for p in r.queue])
    d === :spt && return argmin([p.service_estimate for p in r.queue])
    d === :srpt && return argmin([p.service_estimate for p in r.queue])
    d === :edd && return argmin([p.due for p in r.queue])
    d === :random && return rand_index(σ, Symbol(:discipline, :_, r.name), length(r.queue))
    return 1
end

"""Remove and return the waiter the discipline selects."""
function pop_waiter!(σ::Sim, r::Resource)
    i = next_waiter_index(σ, r)
    i == 0 && return nothing
    p = r.queue[i]
    deleteat!(r.queue, i)
    return p
end

"""Book a grant of one server to `p` and record the waiting time."""
function _grant!(σ::Sim, r::Resource, p::Process, waited::Real)
    _touch!(σ, r)
    r.in_use += 1
    r.holders[p.id] = σ.now
    tally_record!(r.wait, max(waited, 0.0))
    count!(r.granted, :total)
    r.state === :idle && (r.state = :busy)
    return p
end

"""Hand the free servers to the waiting processes the discipline selects."""
function _dispatch!(σ::Sim, r::Resource)
    _touch!(σ, r)
    is_available(r) || return r                 # nothing is served in maintenance
    while r.in_use < r.capacity && !isempty(r.queue)
        p = pop_waiter!(σ, r)
        p === nothing && break
        waited = σ.now - get(r.waiting_since, p.id, σ.now)
        delete!(r.waiting_since, p.id)
        _grant!(σ, r, p, waited)
        p.blocker = nothing
        trace!(σ, :start_service, entity_of(p), r.name; value = waited, process_id = p.id)
        activate!(σ, p; priority = p.priority)
    end
    return r
end

"""
    request!(σ, r; priority = 0, due = Inf, service_estimate = Inf) -> Bool

Ask for one server of `r`: returns at once when capacity is free, otherwise the
call *blocks* (suspends the process) until [`_dispatch!`](@ref) hands it a server.
`priority`, `due` and `service_estimate` are what the `:priority`, `:edd`, `:spt`
and `:srpt` disciplines rank on.
"""
function request!(σ::Sim, r::Resource; priority::Integer = 0, due::Real = Inf,
    service_estimate::Real = Inf)
    _touch!(σ, r)
    p = current_process(σ)
    p.priority = Int(priority)
    p.due = Float64(due)
    p.service_estimate = Float64(service_estimate)
    if r.in_use < r.capacity && is_available(r)
        _grant!(σ, r, p, 0.0)
        trace!(σ, :acquire, entity_of(p), r.name; process_id = p.id)
        return true
    end
    count!(statistic(σ, :blocked_requests; kind = :counter), r.name)
    r.waiting_since[p.id] = σ.now
    push!(r.queue, p)
    _touch!(σ, r)
    trace!(σ, :start_queue, entity_of(p), r.name; process_id = p.id)
    block!(σ, r)
    check_interrupt!(p)
    holds(r, p) || _grant!(σ, r, p, σ.now - get(r.waiting_since, p.id, σ.now))
    delete!(r.waiting_since, p.id)
    return true
end

"""Ask for one server; an alias of [`request!`](@ref) that reads like the report."""
acquire!(σ::Sim, r::Resource; kwargs...) = request!(σ, r; kwargs...)

"""
    release!(σ, r) -> Float64

Return the server the current process holds and give it to the next waiter.
Returns the service time that ended.
"""
function release!(σ::Sim, r::Resource)
    _touch!(σ, r)
    p = current_process(σ)
    held_at = get(r.holders, p.id, nothing)
    held_at === nothing && throw(SimulationError(:not_holder,
        string("process :", p.name, " released :", r.name, " without holding it"), p.name, 0))
    delete!(r.holders, p.id)
    r.in_use -= 1
    ## never overwrite a failure: only a healthy resource is busy or idle
    is_available(r) && (r.state = r.in_use > 0 ? :busy : :idle)
    service = σ.now - held_at
    tally_record!(r.service, service)
    count!(r.granted, :release)
    trace!(σ, :release, entity_of(p), r.name; value = service, process_id = p.id)
    _dispatch!(σ, r)
    return service
end

"""
    use!(σ, r, duration; kwargs...) -> Float64

Request one server, hold it for `duration`, release it -- even when the hold is
interrupted, so a shift change can never leak a machine. Returns the sojourn time.
"""
function use!(σ::Sim, r::Resource, duration::Real; kwargs...)
    t0 = σ.now
    request!(σ, r; kwargs...)
    try
        hold!(σ, duration)
    finally
        release!(σ, r)
        tally_record!(r.sojourn, σ.now - t0)
    end
    return σ.now - t0
end

"""
    with!(σ, r) do ... end

Request a server, run the block, release it -- the do-block form of `use!` for
arbitrary work:

```julia
with!(σ, σ[:cnc]) do
    hold!(σ, 4.0)
end
```
"""
function with!(f::Base.Callable, σ::Sim, r::Resource; kwargs...)
    t0 = σ.now
    request!(σ, r; kwargs...)
    try
        return f()
    finally
        release!(σ, r)
        tally_record!(r.sojourn, σ.now - t0)
    end
end

"""
    preempt!(σ, r, holder; message = :preempted) -> Bool

Take a server away from `holder` (which is interrupted, see
[`interrupt!`](@ref)) and hand it to the next waiter. Returns `false` when the
process does not hold the resource.
"""
function preempt!(σ::Sim, r::Resource, holder::Process; message = :preempted)
    holds(r, holder) || return false
    _touch!(σ, r)
    tally_record!(r.service, σ.now - r.holders[holder.id])
    delete!(r.holders, holder.id)
    r.in_use -= 1
    count!(r.preemptions, :total)
    trace!(σ, :preempt, entity_of(holder), r.name; process_id = holder.id, note = :preempted)
    interrupt!(σ, holder, message)
    _dispatch!(σ, r)
    return true
end

## ---- Resource: failures and shifts ---------------------------------------------

"""
    breakdown!(σ, r, repair_time; kind = :breakdown) -> Resource

Take a resource out of service for `repair_time` time units. The state becomes
`:maintenance`, the down time is accumulated (so `availability` drops) and, unless
`repair_time` is zero, a callback puts the resource back in service.
"""
function breakdown!(σ::Sim, r::Resource, repair_time::Real = 0.0; kind::Symbol = :breakdown)
    _touch!(σ, r)
    r.state = :maintenance
    r.down_since = σ.now
    count!(r.breakdowns, kind)
    trace!(σ, :breakdown, :resource, r.name; note = Sym(kind))
    repair_time > 0 &&
        callback!(σ, repair_time, _finish_repair!, r.name; kind = :repair, priority = -1000)
    return r
end

"""Alias of [`breakdown!`](@ref) for planned stops."""
maintenance!(σ::Sim, r::Resource, duration::Real; kwargs...) =
    breakdown!(σ, r, duration; kind = :maintenance, kwargs...)

function _finish_repair!(σ::Sim, name::Symbol)
    r = σ.resources[name]::Resource
    _touch!(σ, r)
    r.state = r.in_use > 0 ? :busy : :idle
    count!(r.repairs, :total)
    trace!(σ, :repair, :resource, r.name)
    _dispatch!(σ, r)                            # the queue was held up by the repair
    return r
end

"""Put a resource back in service (the manual counterpart of `breakdown!`)."""
repair!(σ::Sim, r::Resource) = _finish_repair!(σ, r.name)

## ---- Container -----------------------------------------------------------------

"""Level of a container right now."""
level_of(c::Container) = c.level

"""Fraction of the capacity that is used."""
fill_ratio(c::Container) = isfinite(c.capacity) ? c.level / c.capacity : 0.0

"""Time-weighted mean level of a container."""
mean_level(c::Container) = mean(c.level_stat)

"""
    fill!(σ, c, amount) -> Float64

Add `amount` to the container, blocking while it would overflow. Returns the level
after the fill. (Defined as a method of `Base.fill!`, which is what a bulk store
naturally is.)
"""
function Base.fill!(σ::Sim, c::Container, amount::Real)
    amount > 0 || throw(ArgumentError("fill! needs a positive amount"))
    _touch!(σ, c)
    p = current_process(σ)
    while c.level + amount > c.capacity
        push!(c.putters, p)
        p.blocker = c
        block!(σ, c)
        check_interrupt!(p)
        _touch!(σ, c)
    end
    c.level += amount
    count!(c.fills, p.name)
    _touch!(σ, c)
    trace!(σ, :custom, entity_of(p), c.name; value = amount, note = :fill)
    _wake_getter!(σ, c)
    return c.level
end

"""
    drain!(σ, c, amount) -> Float64

Remove `amount` from the container, blocking while it does not hold that much.
Returns the level after the drain.
"""
function drain!(σ::Sim, c::Container, amount::Real)
    amount > 0 || throw(ArgumentError("drain! needs a positive amount"))
    _touch!(σ, c)
    p = current_process(σ)
    while c.level < amount
        push!(c.getters, p)
        p.blocker = c
        block!(σ, c)
        check_interrupt!(p)
        _touch!(σ, c)
    end
    c.level -= amount
    count!(c.drains, p.name)
    _touch!(σ, c)
    trace!(σ, :custom, entity_of(p), c.name; value = amount, note = :drain)
    _wake_putter!(σ, c)
    return c.level
end

function _wake_getter!(σ::Sim, c::Container)
    while !isempty(c.getters) && !is_alive(c.getters[1])
        popfirst!(c.getters)
    end
    isempty(c.getters) && return c
    p = popfirst!(c.getters)
    p.blocker = nothing
    return activate!(σ, p)
end

function _wake_putter!(σ::Sim, c::Container)
    while !isempty(c.putters) && !is_alive(c.putters[1])
        popfirst!(c.putters)
    end
    isempty(c.putters) && return c
    p = popfirst!(c.putters)
    p.blocker = nothing
    return activate!(σ, p)
end

## ---- Store ---------------------------------------------------------------------

"""Number of items in a store right now."""
count_of(s::Store) = length(s.items)

"""Time-weighted mean number of items in a store."""
mean_count(s::Store) = mean(s.count_stat)

"""`true` when the item matches the filter of the store."""
matches(s::Store, item) = s.filter === :all ? true :
                          s.filter isa Function ? s.filter(item) : true

"""Name carried by an item, used by the trace (`:item` when it has none)."""
function item_name(item)
    item isa AbstractDict && haskey(item, :name) && return Sym(item[:name])
    item isa NamedTuple && haskey(item, :name) && return Sym(item.name)
    item isa Symbol && return item
    return :item
end

"""
    store_item!(σ, s, item) -> Int

Put an item in a store, blocking while the store is full. Returns the number of
items stored.
"""
function store_item!(σ::Sim, s::Store, item)
    _touch!(σ, s)
    p = current_process(σ)
    while length(s.items) >= s.capacity
        push!(s.putters, p)
        p.blocker = s
        block!(σ, s)
        check_interrupt!(p)
        _touch!(σ, s)
    end
    push!(s.items, item)
    count!(s.stored, item_name(item))
    _touch!(σ, s)
    trace!(σ, :custom, item_name(item), s.name; note = :store)
    _wake_getter!(σ, s)
    return length(s.items)
end

"""
    retrieve!(σ, s; filter = nothing) -> Any

Take the first matching item out of the store, blocking until one arrives. A
`filter` given here overrides the filter of the store.
"""
function retrieve!(σ::Sim, s::Store; filter = nothing)
    _touch!(σ, s)
    p = current_process(σ)
    while true
        idx = findfirst(item -> filter === nothing ? matches(s, item) : filter(item), s.items)
        if idx !== nothing
            item = s.items[idx]
            deleteat!(s.items, idx)
            count!(s.retrieved, item_name(item))
            _touch!(σ, s)
            trace!(σ, :custom, item_name(item), s.name; note = :retrieve)
            _wake_putter!(σ, s)
            return item
        end
        push!(s.getters, p)
        p.blocker = s
        block!(σ, s)
        check_interrupt!(p)
        _touch!(σ, s)
    end
end

function _wake_getter!(σ::Sim, s::Store)
    while !isempty(s.getters) && !is_alive(s.getters[1])
        popfirst!(s.getters)
    end
    isempty(s.getters) && return s
    p = popfirst!(s.getters)
    p.blocker = nothing
    return activate!(σ, p)
end

function _wake_putter!(σ::Sim, s::Store)
    while !isempty(s.putters) && !is_alive(s.putters[1])
        popfirst!(s.putters)
    end
    isempty(s.putters) && return s
    p = popfirst!(s.putters)
    p.blocker = nothing
    return activate!(σ, p)
end

## ---- detaching a waiting process -----------------------------------------------

"""
    release_blocker!(σ, p)

Detach `p` from the resource, container or store it is queued on; called when a
process is interrupted or cancelled while waiting.
"""
function release_blocker!(σ::Sim, p::Process)
    b = p.blocker
    b === nothing && return nothing
    if b isa Resource
        _touch!(σ, b)
        i = findfirst(q -> q === p, b.queue)
        i === nothing || deleteat!(b.queue, i)
        delete!(b.waiting_since, p.id)
        _touch!(σ, b)
    elseif b isa Container
        _touch!(σ, b)
        filter!(q -> q !== p, b.putters)
        filter!(q -> q !== p, b.getters)
        _touch!(σ, b)
    elseif b isa Store
        _touch!(σ, b)
        filter!(q -> q !== p, b.putters)
        filter!(q -> q !== p, b.getters)
        _touch!(σ, b)
    end
    p.blocker = nothing
    return nothing
end

"""Name of the object a process waits on."""
describe_blocker(c::Container) = c.name
describe_blocker(s::Store) = s.name