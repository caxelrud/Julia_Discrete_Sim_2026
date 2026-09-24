# =============================================================================
# symdict.jl -- `SymDict`, the symbol-keyed container used everywhere.
#
# A `SymDict` is an ordered `AbstractDict{Symbol,Any}`: keys keep the order in
# which they were first assigned, values are read with `d[:wait]` *or* `d.wait`,
# and a whole record can be sliced with `d[[:throughput, :utilisation]]` to build
# a report table. Every parameter set, every metric bundle, every report record
# and every JSON payload of the package is a `SymDict`, so a model, a scenario,
# an experiment result and a notebook cell all speak symbols.
# =============================================================================

"""
    SymDict
    SymDict(:a => 1, :b => 2)
    SymDict((a = 1, b = 2))

Ordered dictionary keyed by `Symbol`. Reading a missing key throws a `KeyError`
naming the key, which turns a typo into an error instead of a `missing`.

```julia
params = SymDict(:arrival_rate => 0.8, :service_rate => 1.0)
params[:arrival_rate]           # 0.8
params.arrival_rate             # 0.8, same thing
params[:utilisation] = 0.8      # ordered keys: :arrival_rate, :service_rate, :utilisation
```
"""
mutable struct SymDict <: AbstractDict{Symbol,Any}
    order::Vector{Symbol}
    data::Dict{Symbol,Any}
end

SymDict() = SymDict(Symbol[], Dict{Symbol,Any}())
SymDict(p::Pair...) = SymDict(Any[p...])
SymDict(pairs::AbstractVector) = begin
    d = SymDict()
    for (k, v) in pairs
        d[k] = v
    end
    d
end
SymDict(d::AbstractDict) = SymDict(Any[Sym(k) => v for (k, v) in d])
SymDict(nt::NamedTuple) = SymDict(Any[Sym(k) => v for (k, v) in pairs(nt)])
SymDict(gen::Base.Generator) = SymDict(collect(gen))

## ---- dictionary interface -----------------------------------------------------

function Base.setindex!(d::SymDict, v, k)
    key = Sym(k)
    haskey(d.data, key) || push!(d.order, key)
    d.data[key] = v
    return d
end

function Base.getindex(d::SymDict, k)
    key = Sym(k)
    haskey(d.data, key) || throw(KeyError(key))
    return d.data[key]
end

"""Slice a record: `d[[:throughput, :utilisation]]` returns a new `SymDict` with
only the listed keys (missing keys are skipped)."""
function Base.getindex(d::SymDict, ks::AbstractVector)
    out = SymDict()
    for k in ks
        haskey(d, k) && (out[k] = d[k])
    end
    return out
end

Base.haskey(d::SymDict, k) = haskey(d.data, Sym(k))
Base.get(d::SymDict, k, default) = get(d.data, Sym(k), default)
Base.get(f::Base.Callable, d::SymDict, k) = get(f, d.data, Sym(k))
Base.length(d::SymDict) = length(d.order)
Base.isempty(d::SymDict) = isempty(d.order)
Base.keys(d::SymDict) = d.order
Base.values(d::SymDict) = Any[d.data[k] for k in d.order]
Base.pairs(d::SymDict) = [k => d.data[k] for k in d.order]
Base.copy(d::SymDict) = SymDict(copy(d.order), copy(d.data))
Base.sizehint!(d::SymDict, n::Integer) = (sizehint!(d.order, n); sizehint!(d.data, n); d)

function Base.iterate(d::SymDict, state::Int = 1)
    state > length(d.order) && return nothing
    k = d.order[state]
    return (k => d.data[k], state + 1)
end

function Base.delete!(d::SymDict, k)
    key = Sym(k)
    delete!(d.data, key)
    filter!(x -> x !== key, d.order)
    return d
end

Base.empty!(d::SymDict) = (empty!(d.order); empty!(d.data); d)

function Base.merge(a::SymDict, others::AbstractDict...)
    out = copy(a)
    for o in others, (k, v) in o
        out[k] = v
    end
    return out
end

Base.merge!(a::SymDict, others::AbstractDict...) = merge(a, others...)

## ---- symbol field access ------------------------------------------------------

function Base.getproperty(d::SymDict, k::Symbol)
    (k === :order || k === :data) && return getfield(d, k)
    return getindex(d, k)
end

function Base.setproperty!(d::SymDict, k::Symbol, v)
    (k === :order || k === :data) && return setfield!(d, k, v)
    return setindex!(d, v, k)
end

Base.propertynames(d::SymDict) = Tuple(d.order)

## ---- conversions and views ----------------------------------------------------

"""Convert a symbol-keyed dictionary to a `NamedTuple` (insertion order)."""
to_named_tuple(d::SymDict) = NamedTuple{Tuple(d.order)}(Tuple(d.data[k] for k in d.order))
to_named_tuple(nt::NamedTuple) = nt

"""Plain `Dict{Symbol,Any}` copy of a `SymDict` (or of any dictionary)."""
to_dict(d::SymDict) = copy(d.data)
to_dict(d::AbstractDict) = Dict{Symbol,Any}(Sym(k) => v for (k, v) in d)

"""Normalise any dictionary-like object into a `SymDict`."""
symbolize_keys(x) = SymDict(x)
symbolize_keys(x::SymDict) = x

"""
Field names that always hold a `Symbol` in the records of this package, so a
`Symbol` survives a round trip through JSON (where it becomes a string).
"""
const SYMBOL_FIELDS = Set{Symbol}([
    :model, :kind, :verdict, :reason, :source, :status, :freshness, :metric, :entity,
    :resource, :resource_kind, :discipline, :series, :term, :objective, :direction,
    :baseline, :best, :observed_key, :theory_key, :parameter, :check, :system, :scenario,
    :policy, :unit, :stop_reason, :time_unit, :class, :note, :title, :featured,
    :sweep_param, :family, :plan_source, :name, :theme, :time_unit, :label, :quantity,
    :stream, :generator, :dominant,
])

"""
    symbolize_deep(x)

Convert a nested structure read back from JSON into the symbol-keyed form the
package uses: dictionaries become `SymDict`s with their keys normalised, vectors
are mapped element by element, and the values of the fields listed in
`SYMBOL_FIELDS` become `Symbol`s again -- which is what `jsonable` threw away,
since JSON has no symbols. It is the inverse of `jsonable`, and it is what makes
`load_study` work.
"""
function symbolize_deep(x, fields::Set{Symbol} = SYMBOL_FIELDS)
    if x isa AbstractDict
        out = SymDict()
        for (k, v) in x
            key = Sym(k)
            out[key] = _symbolize_value(key, v, fields)
        end
        return out
    end
    x isa AbstractVector && return Any[symbolize_deep(v, fields) for v in x]
    x isa AbstractString && return String(x)
    return x
end

"""One value of a record: a string in a symbol field becomes a `Symbol` again."""
function _symbolize_value(key::Symbol, v, fields::Set{Symbol})
    v isa AbstractString && key in fields && return Sym(v)
    return symbolize_deep(v, fields)
end

"""String-keyed view, for JSON payloads and CSV headers."""
stringify_keys(d::AbstractDict) = Dict{String,Any}(code_string(k) => v for (k, v) in d)

"""Subset of a record, in the given key order (missing keys are skipped)."""
subset(d::SymDict, ks) = SymDict(Any[Sym(k) => d[k] for k in ks if haskey(d, k)])

"""Keys common to two records, in the order of the first."""
common_keys(a::AbstractDict, b::AbstractDict) = Symbol[k for k in keys(a) if haskey(b, k)]

"""Sort the keys of a record alphabetically, in place."""
sort_keys!(d::SymDict) = (sort!(d.order); d)

"""Numeric-only view of a record (used to aggregate experiment results)."""
numeric_keys(d::AbstractDict) = Symbol[k for k in keys(d) if d[k] isa Real && !(d[k] isa Bool)]

"""Merge two records recursively: nested `SymDict`s are merged key by key."""
function deep_merge(a::SymDict, b::AbstractDict)
    out = copy(a)
    for (k, v) in b
        key = Sym(k)
        if haskey(out, key) && out[key] isa SymDict && v isa AbstractDict
            out[key] = deep_merge(out[key], v)
        else
            out[key] = v
        end
    end
    return out
end

function Base.show(io::IO, d::SymDict)
    print(io, "SymDict(")
    for (i, k) in enumerate(d.order)
        i > 1 && print(io, ", ")
        print(io, ":", k, " => ", repr(d.data[k]))
    end
    return print(io, ")")
end

function Base.show(io::IO, ::MIME"text/plain", d::SymDict)
    n = length(d.order)
    println(io, "SymDict with ", n, " key", n == 1 ? "" : "s")
    for k in d.order
        v = d.data[k]
        print(io, "  :", k, " = ")
        if v isa AbstractString && length(v) > 200
            print(io, '"', first(v, 120), "…\" (", length(v), " characters)")
            println(io)
        elseif v isa AbstractVector && length(v) > 40
            print(io, first(v, 40), " … (", length(v), " elements)")
            println(io)
        else
            show(io, MIME"text/plain"(), v)
            println(io)
        end
    end
    return nothing
end
