# =============================================================================
# errors.jl -- the exceptions of the engine.
#
# A discrete-event model fails in two very different ways, and the engine keeps
# them apart: an *interruption* is part of the model (a shift change, a
# preemption, a machine failure) and is catchable inside the process that waits,
# while a *simulation error* is a bug in the model (a process that released a
# resource it never held, a run that hit its event limit) and aborts the run
# unless the configuration says otherwise.
# =============================================================================

"""
    SimInterrupt(msg = :interrupt)

Thrown inside a process when another part of the model interrupts it -- the
Julia counterpart of SimPy's `Interrupt`. It is an ordinary exception, so the
process can guard against it:

```julia
try
    hold!(σ, 8.0)                 # a long operation
catch err
    err isa SimInterrupt || rethrow()
    load!(σ, :other_job)          # the tool was taken away: switch to plan B
end
```
"""
struct SimInterrupt <: Exception
    message::Any
end

SimInterrupt() = SimInterrupt(:interrupt)

function Base.showerror(io::IO, e::SimInterrupt)
    return print(io, "SimInterrupt(", repr(e.message), ")")
end

"""
    SimulationError(kind, message)

A bug in the model or a limit of the run: `:double_release`, `:not_holder`,
`:bad_state`, `:user_error`, `:max_events`, `:wall_clock`, `:cancelled`. With
`strict = true` (the default) the engine rethrows at the point of the run, with
the offending process named, instead of silently producing numbers.
"""
struct SimulationError <: Exception
    kind::Symbol
    message::String
    process::Symbol
    replication::Int
end

SimulationError(kind, message) = SimulationError(Sym(kind), String(message), :none, 0)

function Base.showerror(io::IO, e::SimulationError)
    print(io, "SimulationError(:", e.kind, ")")
    e.process === :none || print(io, " in process :", e.process)
    e.replication == 0 || print(io, " (replication ", e.replication, ")")
    return print(io, ": ", e.message)
end

"""Exception raised when a model asks a resource for something impossible."""
argument_error(msg) = throw(ArgumentError(msg))

"""Keyword given to a symbol-keyed constructor that the type does not know."""
function check_keywords(what::AbstractString, kwargs, known)
    unknown = Symbol[k for k in keys(kwargs) if Sym(k) ∉ known]
    isempty(unknown) ||
        throw(ArgumentError(string(what, " does not know ", join(code_string.(unknown), ", "),
            "; known keywords are ", join(sort(code_string.(known)), ", "))))
    return nothing
end
