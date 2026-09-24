# =============================================================================
# process.jl -- processes, the coroutine layer of the engine.
#
# A process is an ordinary Julia `Task` that yields control back to the
# scheduler every time it has to wait. The hand-off uses two channels per
# process (`go` for "you may run", the shared `ready` for "I am done or
# waiting"), which is the classic coroutine protocol and needs no macros, no
# rewritable stacks and no `yieldto`:
#
#     scheduler: put!(p.go, nothing)  ->  take!(σ.ready)      # run p until it yields
#     process:   put!(σ.ready, state) ->  take!(p.go)         # yield until resumed
#
# Only one process runs at a time, so a model reads like sequential code while
# the engine keeps a single event loop:
#
#     @process σ worker(σ, :cnc_1)
#
#     function worker(σ, machine)
#         while true
#             job = take!(σ, :inbox)                 # blocks until a job arrives
#             hold!(σ, service_time(σ, machine))     # occupies simulated time
#             release!(σ, machine)                   # and frees the machine
#         end
#     end
# =============================================================================

## ---- identity and state --------------------------------------------------------

"""Id of a process (unique within a run)."""
process_id(p::Process) = p.id

"""Name of a process (the function it was spawned from, by default)."""
process_name(p::Process) = p.name

"""Current state of a process (see `PROCESS_STATES`)."""
state_of(p::Process) = p.state

"""`true` once the process has returned normally."""
is_finished(p::Process) = p.state === :finished

"""`true` while the process can still be resumed."""
is_alive(p::Process) = p.state ∉ (:finished, :failed, :cancelled)

"""`true` while the process sits on the calendar."""
is_waiting(p::Process) = p.state === :waiting

"""`true` while the process waits for something other than the clock."""
is_blocked(p::Process) = p.state === :blocked

"""Time the process spent in the system (`Inf` while it still runs)."""
sojourn_of(p::Process) = p.state === :finished ? p.finished - p.created : Inf

"""Read an attribute of a process (`nothing` when it was never set)."""
attribute(p::Process, key, default = nothing) = get(p.attrs, Sym(key), default)

"""Set an attribute of a process; the queue disciplines and the report read it."""
function set_attribute!(p::Process, key, value)
    p.attrs[Sym(key)] = value
    return p
end

"""The process that is running right now; throws outside a process."""
function current_process(σ::Sim)
    p = σ.current
    p === nothing && throw(SimulationError(:not_in_process,
        "this operation needs a process; call it inside @process or spawn!", :none, 0))
    return p::Process
end

"""`true` when a process of `σ` is running right now."""
inside_process(σ::Sim) = σ.current !== nothing

## ---- spawning ------------------------------------------------------------------

"""
    spawn!(σ, f; name = :process, priority = 0, delay = 0.0, attrs = nothing) -> Process

Start `f()` as a process. `f` is a zero-argument function (usually a closure over
the model's parameters) that uses [`hold!`](@ref), [`request!`](@ref),
[`take!`](@ref) and friends to advance simulated time. `delay` postpones the
first statement by that many time units, and `attrs` seeds the symbol-keyed
attributes the process carries.
"""
function spawn!(σ::Sim, f::Base.Callable; name::Symbol = :process, priority::Integer = 0,
    delay::Real = 0.0, attrs = nothing, parent::Integer = 0)
    σ.created += 1
    id = σ.created
    p = Process(id, Sym(name), σ, Task(() -> nothing), Channel{Nothing}(1), :ready,
        Int(priority), Int(parent), :hold, Float64(delay), σ.now + Float64(delay), σ.now,
        0.0, 0, nothing, nothing, Any[], Inf, Inf,
        attrs === nothing ? SymDict() : SymDict(attrs), nothing)
    σ.processes[id] = p
    p.task = Task(() -> _process_body!(p, f))
    p.event = schedule_at!(σ, p.wake; kind = :create, owner = id, priority = Int(priority))
    schedule(p.task)
    return p
end

"""
    @process σ f(args...)

Spawn `spawn!(σ, () -> f(args...); name = :f)`: the readable form of
[`spawn!`](@ref), with the process named after the function it runs.

```julia
@process σ arrivals(σ, 0.8, 1.0)
@process σ server(σ, :cnc_1)
```
"""
macro process(σ, call)
    (call isa Expr && call.head === :call) || throw(ArgumentError(
        "@process expects a call, e.g. @process σ server(σ, :cnc_1)"))
    fname = call.args[1]
    name = fname isa Symbol ? QuoteNode(fname) : QuoteNode(:process)
    return :(spawn!($(esc(σ)), () -> $(esc(call)); name = $name))
end

"""Body of a process: waits for the first grant, runs `f`, reports back once."""
function _process_body!(p::Process, f::Base.Callable)
    σ = p.sim::Sim
    take!(p.go)                       # wait for the scheduler to let us start
    p.state = :running
    try
        f()
        p.action = :finish
    catch err
        p.error = err
        p.state = :failed
    finally
        p.finished = σ.now
        p.state === :failed || (p.state = :finished)
        put!(σ.ready, p.state)        # hand control back to the scheduler for good
    end
    return nothing
end

"""Suspend the current process until the scheduler resumes it."""
function suspend!(p::Process)
    put!(p.sim.ready, p.state)
    take!(p.go)
    return nothing
end

"""
    resume!(σ, p) -> Process

Let `p` run until it yields again, and book whatever it asked for: a `hold!` puts
it back on the calendar, a `block!` leaves it waiting for an activation, and a
`passivate!` parks it. Called by the scheduler; a model never calls it.
"""
function resume!(σ::Sim, p::Process)
    σ.resumed += 1
    σ.current = p
    p.state = :running
    p.activations += 1
    put!(p.go, nothing)
    signal = take!(σ.ready)
    σ.current = nothing

    if signal === :failed
        err = p.error
        if σ.config.strict
            detail = err isa SimInterrupt ?
                     string("an uncaught SimInterrupt(", repr(err.message), ") escaped the ",
                         "process; catch it where the model interrupts") :
                     string(typeof(err), ": ",
                         first(replace(sprint(showerror, err), "\n" => " "), 400))
            throw(SimulationError(:user_error, detail, p.name, 0))
        end
        return p
    end
    p.state === :finished && return p

    if p.action === :hold
        p.wake = σ.now + p.delay
        p.state = :waiting
        p.event = schedule_at!(σ, p.wake; kind = :resume, owner = p.id, priority = p.priority)
    elseif p.action === :block
        p.state = :blocked
    elseif p.action === :passivate
        p.state = :passive
    end
    return p
end

## ---- the waiting API -----------------------------------------------------------

"""Throw the oldest pending interruption, if any (called after every suspension)."""
function check_interrupt!(p::Process)
    isempty(p.interruptions) && return nothing
    throw(SimInterrupt(popfirst!(p.interruptions)))
end

"""
    hold!(σ, delay; priority = 0) -> nothing

Let simulated time pass for the *current* process: it is put back on the calendar
`delay` time units from now. `hold!(σ, 0.0)` yields the processor without moving
the clock, which is how a model gives the other processes a chance at the same
instant.
"""
function hold!(σ::Sim, delay::Real; priority::Integer = 0)
    p = current_process(σ)
    p.action = :hold
    p.delay = Float64(delay)
    p.priority = Int(priority)
    suspend!(p)
    check_interrupt!(p)
    return nothing
end

"""Wait until the absolute time `t` (`hold!(σ, t - now(σ))`)."""
hold_until!(σ::Sim, t::Real; priority::Integer = 0) =
    hold!(σ, Float64(t) - σ.now; priority = priority)

"""
    block!(σ, blocker = nothing) -> nothing

Suspend the current process until someone calls [`activate!`](@ref) on it.
`blocker` is kept in `p.blocker`, which is how `interrupt!` and `cancel!` know
what to detach the process from.
"""
function block!(σ::Sim, blocker = nothing)
    p = current_process(σ)
    p.action = :block
    p.blocker = blocker
    suspend!(p)
    return nothing
end

"""
    passivate!(σ) -> nothing

Park the current process indefinitely; it only runs again through
[`activate!`](@ref). Used for the hours a machine is off shift.
"""
function passivate!(σ::Sim)
    p = current_process(σ)
    p.action = :passivate
    p.blocker = nothing
    suspend!(p)
    return nothing
end

"""
    activate!(σ, p; priority = p.priority, delay = 0.0) -> Process

Resume a blocked or passive process, optionally after `delay` time units and with
a new scheduling priority. Activating the running process is a no-op.
"""
function activate!(σ::Sim, p::Process; priority::Integer = p.priority, delay::Real = 0.0)
    (p.state === :finished || p.state === :cancelled) && return p
    p === σ.current && return p
    p.event isa Event && cancel_event!(σ.calendar, p.event)
    p.action = :hold
    p.delay = 0.0
    p.priority = Int(priority)
    p.blocker = nothing
    p.wake = σ.now + Float64(delay)
    p.event = schedule_at!(σ, p.wake; kind = :activate, owner = p.id, priority = Int(priority))
    p.state = :ready
    return p
end

"""Activate every process of a collection and return how many were activated."""
function activate_all!(σ::Sim, ps; delay::Real = 0.0)
    n = 0
    for p in ps
        is_alive(p) || continue
        activate!(σ, p; delay = delay)
        n += 1
    end
    return n
end

"""
    interrupt!(σ, p, message = :interrupt; delay = 0.0) -> Process

Interrupt `p`: if it was waiting on the clock it is resumed at once (after
`delay`), and the `hold!`, `request!` or other blocking call it was in throws a
[`SimInterrupt`](@ref) carrying `message`. A model uses this for the things that
really do cut into an operation: a shift change, a breakdown, a priority order.
"""
function interrupt!(σ::Sim, p::Process, message = :interrupt; delay::Real = 0.0)
    is_alive(p) || return p
    push!(p.interruptions, message)
    if p.state === :waiting || p.state === :ready
        p.event isa Event && cancel_event!(σ.calendar, p.event)
        p.action = :hold
        p.delay = 0.0
        p.wake = σ.now + Float64(delay)
        p.event = schedule_at!(σ, p.wake; kind = :interrupt, owner = p.id, priority = -10_000)
        p.state = :ready
    elseif p.state === :blocked || p.state === :passive
        release_blocker!(σ, p)
        activate!(σ, p; priority = -10_000, delay = delay)
    end
    return p
end

"""
    cancel!(σ, p; reason = :cancelled) -> Process

Abandon a process: its calendar entry is dropped, it is detached from whatever it
was waiting for, and it will never run again. The task that backs it stays
suspended, so prefer [`interrupt!`](@ref) when the model must clean up.
"""
function cancel!(σ::Sim, p::Process; reason::Symbol = :cancelled)
    (p.state === :finished || p.state === :cancelled) && return p
    p.event isa Event && cancel_event!(σ.calendar, p.event)
    release_blocker!(σ, p)
    p.state = :cancelled
    p.finished = σ.now
    p.attrs[Sym(:cancel_reason)] = Sym(reason)
    return p
end

"""
    release_blocker!(σ, p) -> nothing

Detach `p` from the resource, container or store it is queued on. It is defined
in `resources.jl`; the process layer calls it whenever a waiting process is
interrupted or cancelled.
"""
function release_blocker! end

## ---- statistics of the process layer -------------------------------------------

"""Counters of the process states of a finished run (a `SymDict`)."""
function process_states(σ::Sim)
    counts = SymDict()
    for state in PROCESS_STATES
        counts[state] = 0
    end
    for (_, p) in σ.processes
        haskey(counts, p.state) || (counts[p.state] = 0)
        counts[p.state] += 1
    end
    return counts
end

"""Live processes of a run, in creation order."""
function live_processes(σ::Sim)
    ps = Process[p for (_, p) in σ.processes if is_alive(p)]
    return sort!(ps; by = p -> p.id)
end

"""Processes still waiting for a resource at the end of a run."""
function blocked_processes(σ::Sim)
    ps = Process[p for (_, p) in σ.processes if p.state === :blocked]
    return sort!(ps; by = p -> p.id)
end

"""One-line description of a process (used by the report)."""
function describe_process(p::Process)
    body = string(":", p.name, " #", p.id, " ", code_string(p.state))
    p.state === :blocked && p.blocker !== nothing &&
        (body *= string(" on ", code_string(describe_blocker(p.blocker))))
    isinf(p.due) || (body *= string(", due ", round(p.due, digits = 2)))
    return body
end

"""Name of whatever a process waits on (`:none` when it waits for the clock)."""
describe_blocker(x) = :none
describe_blocker(r::Resource) = r.name

function Base.show(io::IO, p::Process)
    return print(io, "Process(:", p.name, ", #", p.id, ", ", code_string(p.state),
        ", activations=", p.activations, ")")
end
