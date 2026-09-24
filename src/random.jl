# =============================================================================
# random.jl -- named streams and the distribution vocabulary.
#
# Two decisions make the randomness of this engine reproducible, which is what
# turns a simulation into an experiment:
#
# * **Every stream has a name.** The seed of a stream is derived from the seed of
#   the run *and the name of the stream*, so `:arrivals` and `:service` never
#   interfere, and two scenarios that use a stream of the same name in the same
#   replication draw exactly the same variates. Common random numbers -- the
#   technique that makes a comparison of two designs statistically sharp -- are
#   therefore structural here, not an add-on.
# * **Variates are drawn by inversion.** `sample_rv` evaluates `quantile(d, u)`
#   with `u` uniform, which makes antithetic variates a one-line option
#   (`u -> 1 - u`) and keeps a stream comparable across distribution families.
#
# A distribution is described by a `Symbol` and its parameters, so a distribution
# fitted from plant data (see `data.jl`) is the same kind of object as one a
# human typed: a `:kind` plus `:params`, ready for the report and for JSON.
# =============================================================================

## ---- a deterministic "distribution" --------------------------------------------

"""
    Deterministic(value)

The degenerate distribution that always returns `value`: the processing time of a
machine whose cycle time is exactly known, or the lead time of a contract.
"""
struct Deterministic <: Distributions.Distribution{Distributions.Univariate,
    Distributions.Continuous}
    value::Float64
end

Deterministic(value::Real) = Deterministic(Float64(value))

Distributions.mean(d::Deterministic) = d.value
Distributions.var(d::Deterministic) = 0.0
Distributions.std(d::Deterministic) = 0.0
Distributions.minimum(d::Deterministic) = d.value
Distributions.maximum(d::Deterministic) = d.value
Distributions.quantile(d::Deterministic, p::Real) = d.value
Distributions.pdf(d::Deterministic, x::Real) = x == d.value ? Inf : 0.0
Distributions.cdf(d::Deterministic, x::Real) = x >= d.value ? 1.0 : 0.0
Base.rand(::AbstractRNG, d::Deterministic) = d.value
Base.rand(d::Deterministic) = d.value

## ---- seeds of the streams ------------------------------------------------------

"""
    stream_seed(base, name, salt = 0) -> Int

Deterministic seed of a named stream: an FNV-1a hash of the name mixed with the
seed of the run and an optional salt. Stable across sessions and machines, which
is what makes a run reproducible from its seed alone.
"""
function stream_seed(base::Integer, name::Symbol, salt::Integer = 0)
    h = 0xcbf29ce484222325
    for b in codeunits(code_string(name))
        h = (h ⊻ UInt64(b)) * 0x100000001b3
    end
    h ⊻= UInt64(base % 2^62) * 0x9e3779b97f4a7c15
    h ⊻= UInt64(salt % 2^62)
    h = (h ⊻ (h >> 33)) * 0xff51afd7ed558ccd
    h = (h ⊻ (h >> 33)) * 0xc4ceb9fe1a85ec53
    h = h ⊻ (h >> 33)
    return Int(h & 0x1fffffffffffff)          # 53 bits: fits an Int64 and a Float64
end

"""
    stream!(σ, name; antithetic = false) -> Stream

The named random stream of `σ`, created on first use. Because the seed depends on
the name, `stream!(σ, :service)` is the same stream everywhere in a run.
"""
function stream!(σ::Sim, name::Symbol; antithetic::Bool = false)
    k = Sym(name)
    st = get(σ.rngs, k, nothing)
    if st isa Stream
        antithetic && (st.antithetic = true)
        return st
    end
    seed = stream_seed(σ.config.seed, k)
    st = Stream(k, StableRNGs.StableRNG(seed), seed, 0, antithetic)
    σ.rngs[k] = st
    return st
end

stream!(σ::Sim, name::AbstractString; kwargs...) = stream!(σ, Sym(name); kwargs...)

"""Every stream of a run, as one record (used by the report)."""
function streams_table(σ::Sim)
    rows = SymDict[]
    for (name, st) in σ.rngs
        st isa Stream || continue
        row = SymDict()
        row[:stream] = name
        row[:seed] = st.seed
        row[:draws] = st.draws
        row[:antithetic] = st.antithetic
        push!(rows, row)
    end
    return rows
end

"""
    antithetic!(σ, names = nothing) -> Sim

Make the named streams antithetic (every draw `u` becomes `1 - u`), which is what
turns a pair of runs into a variance-reduced pair. With no names, every stream of
the run -- including the ones created later -- becomes antithetic.
"""
function antithetic!(σ::Sim, names = nothing)
    if names === nothing
        for (_, st) in σ.rngs
            st isa Stream && (st.antithetic = true)
        end
    else
        for n in names
            stream!(σ, Sym(n); antithetic = true)
        end
    end
    return σ
end

"""Draw a uniform variate from a named stream (honours `antithetic`)."""
function rand_stream(σ::Sim, name::Symbol)
    st = stream!(σ, name)
    st.draws += 1
    u = rand(st.rng)
    return st.antithetic ? 1 - u : u
end

"""Uniform integer in `1:n` from a named stream."""
function rand_index(σ::Sim, name::Symbol, n::Integer)
    n <= 1 && return 1
    return min(Int(n), floor(Int, rand_stream(σ, name) * n) + 1)
end

"""`true` with probability `p`, drawn from a named stream."""
rand_bool(σ::Sim, name::Symbol, p::Real) = rand_stream(σ, name) < p

## ---- the distribution vocabulary -----------------------------------------------

"""
    dist(kind::Symbol, params...) -> Distribution
    dist(spec) -> Distribution

Build a distribution from the symbol vocabulary. The positional form uses the
canonical parameterisation of queueing and reliability practice:

| `kind` | parameters | notes |
|---|---|---|
| `:deterministic`, `:constant` | `value` | always the same number |
| `:exponential` | `rate` | mean is `1 / rate` |
| `:normal` | `μ`, `σ` | |
| `:lognormal` | `μ`, `σ` | parameters of the logarithm |
| `:uniform` | `a`, `b` | |
| `:triangular` | `a`, `b`, `c` | minimum, maximum, mode |
| `:gamma` | `shape`, `scale` | |
| `:weibull` | `shape`, `scale` | |
| `:erlang` | `shape`, `rate` | sum of `shape` exponentials |
| `:beta` | `α`, `β` | |
| `:poisson` | `λ` | mean count |
| `:geometric` | `p` | |
| `:empirical` | `values` (`, weights`) | resampling of observations |
| `:discrete` | `values`, `weights` | arbitrary discrete values |
| `:categorical` | `probabilities` | returns the index |

```julia
dist(:exponential, 1.5)                       # rate 1.5, mean 0.667
dist(:lognormal, 1.2, 0.5)
dist(:triangular, 0.5, 3.0, 1.0)
dist(SymDict(:kind => :weibull, :params => (2.0, 5.0)))   # fitted from data
```
"""
function dist(kind::Symbol, params::Real...)
    k = Sym(kind)
    n = length(params)
    k === :deterministic && return Deterministic(params[1])
    k === :constant && return Deterministic(params[1])
    k === :exponential && return Exponential(1 / params[1])
    k === :normal && n >= 2 && return Normal(params[1], params[2])
    k === :lognormal && n >= 2 && return LogNormal(params[1], params[2])
    k === :uniform && n >= 2 && return Uniform(params[1], params[2])
    k === :triangular && n >= 3 && return TriangularDist(params[1], params[2], params[3])
    k === :gamma && n >= 2 && return Gamma(params[1], params[2])
    k === :weibull && n >= 2 && return Weibull(params[1], params[2])
    k === :erlang && n >= 2 && return Erlang(params[1], 1 / params[2])
    k === :beta && n >= 2 && return Beta(params[1], params[2])
    k === :poisson && return Poisson(params[1])
    k === :geometric && return Geometric(params[1])
    throw(ArgumentError(string("dist(:", k, ") does not take ", n,
        " numeric parameters; see the table in the docstring of `dist`")))
end

## `Empirical` was removed from `Distributions`, so the empirical family is a
## `DiscreteNonParametric` with equal weights: sampling from it resamples the
## observations, and its `cdf` is the step function the data implies.
_dist(kind::Symbol, values::AbstractVector{<:Real}, weights::AbstractVector{<:Real}) =
    Sym(kind) in (:empirical, :empirical_continuous) ?
        Distributions.DiscreteNonParametric(collect(Float64, values),
            collect(Float64, weights)) :
    Sym(kind) === :discrete ?
        Distributions.DiscreteNonParametric(collect(Float64, values),
            collect(Float64, weights)) :
    Sym(kind) === :categorical ? Distributions.Categorical(collect(Float64, weights)) :
    throw(ArgumentError("dist(:$(Sym(kind)), values, weights) is only defined for " *
                        ":empirical, :discrete and :categorical"))

"""The empirical distribution of a sample: equal weights on every observation."""
_dist(kind::Symbol, values::AbstractVector{<:Real}) =
    Sym(kind) in (:empirical, :empirical_continuous) ?
        Distributions.DiscreteNonParametric(collect(Float64, values),
            fill(1 / length(values), length(values))) :
    Sym(kind) === :categorical ? Distributions.Categorical(collect(Float64, values)) :
    throw(ArgumentError("dist(:$(Sym(kind)), values) is only defined for :empirical " *
                        "and :categorical"))

## the two public vector forms of `dist` (the implementation lives in `_dist`)
dist(kind::Symbol, values::AbstractVector{<:Real}) = _dist(kind, values)

dist(kind::Symbol, values::AbstractVector, weights::AbstractVector{<:Real}) =
    _dist(kind, values, weights)

"""Build a distribution from a `:kind` / `:params` record (as fitted from data)."""
function dist(spec::Union{AbstractDict,NamedTuple})
    kind = Sym(spec isa NamedTuple ? spec.kind : spec[:kind])
    raw = spec isa NamedTuple ? spec.params : spec[:params]
    params = raw isa Tuple ? collect(raw) :
             raw isa AbstractVector ? collect(raw) :
             raw isa Real ? Any[raw] : Any[]
    isempty(params) && throw(ArgumentError("a distribution spec needs :params"))
    if kind === :empirical || kind === :empirical_continuous
        length(params) == 1 && return dist(kind, Float64.(collect(params[1])))
        return dist(kind, Float64.(collect(params[1])), Float64.(collect(params[2])))
    elseif kind === :discrete && length(params) == 2 && params[1] isa AbstractVector
        return dist(kind, Float64.(collect(params[1])), Float64.(collect(params[2])))
    end
    return dist(kind, Float64.(params)...)
end

"""`kind => params` shorthand, e.g. `dist(:exponential => (0.8,))`."""
function dist(spec::Pair)
    kind = Sym(spec.first)
    raw = spec.second
    raw isa Tuple || raw isa AbstractVector || (raw = (raw,))
    return dist(SymDict(:kind => kind, :params => raw))
end

"""A `:kind`/`:params` record, the JSON-able form of a distribution."""
dist_spec(kind::Symbol, params...) = SymDict(:kind => Sym(kind), :params => Tuple(params))

"""Mean of a distribution described by a spec."""
mean_of(spec) = mean(dist(spec))

"""Standard deviation of a distribution described by a spec."""
sd_of(spec) = std(dist(spec))

"""Coefficient of variation of a distribution described by a spec."""
cv_of(spec) = _cv(mean(dist(spec)), std(dist(spec)))

function _cv(m, s)
    iszero(m) && return Inf
    return s / abs(m)
end

"""The `SymDict` the report renders for a distribution: family, parameters, moments."""
function describe_dist(spec)
    d = dist(spec)
    rec = SymDict()
    rec[:kind] = spec isa Symbol ? spec : Sym(spec isa NamedTuple ? spec.kind : spec[:kind])
    rec[:params] = spec isa Symbol ? () : (spec isa NamedTuple ? spec.params : spec[:params])
    rec[:mean] = mean(d)
    rec[:sd] = std(d)
    rec[:cv] = _cv(mean(d), std(d))
    rec[:min] = try
        minimum(d)
    catch
        NaN
    end
    rec[:max] = try
        maximum(d)
    catch
        NaN
    end
    return rec
end

## ---- sampling ------------------------------------------------------------------

"""
    sample_rv(σ, name, spec) -> Float64

Draw one variate of the distribution `spec` from the named stream `name`, by
inversion (`quantile(d, u)`), so antithetic variates and common random numbers
work for every family.
"""
function sample_rv(σ::Sim, name::Symbol, spec)
    st = stream!(σ, name)
    st.draws += 1
    u = rand(st.rng)
    st.antithetic && (u = 1 - u)
    d = spec isa Number ? Deterministic(spec) : dist(spec)
    return Float64(quantile(d, min(max(u, 1e-12), 1 - 1e-12)))
end

sample_rv(σ::Sim, name::AbstractString, spec) = sample_rv(σ, Sym(name), spec)

"""Short alias of [`sample_rv`](@ref), for the models."""
rv(σ::Sim, name, spec) = sample_rv(σ, name, spec)

"""Draw `n` variates of a spec from a named stream."""
sample_n(σ::Sim, name::Symbol, spec, n::Integer) =
    Float64[sample_rv(σ, name, spec) for _ in 1:Int(n)]

"""Sample a value from a distribution described by a fitted record."""
sample_fitted(σ::Sim, name::Symbol, fit::AbstractDict) =
    sample_rv(σ, name, fit[:kind] => fit[:params])

"""Exponential variate with the given rate."""
exp_rv(σ::Sim, name, rate::Real) = sample_rv(σ, name, :exponential => (rate,))

"""Constant variate."""
det_rv(σ::Sim, name, value::Real) = Float64(value)

"""Normal variate."""
norm_rv(σ::Sim, name, μ::Real, σd::Real) = sample_rv(σ, name, :normal => (μ, σd))

"""Lognormal variate (parameters of the logarithm)."""
log_normal_rv(σ::Sim, name, μ::Real, σd::Real) = sample_rv(σ, name, :lognormal => (μ, σd))

"""Uniform variate on `[a, b]`."""
unif_rv(σ::Sim, name, a::Real, b::Real) = sample_rv(σ, name, :uniform => (a, b))

"""Triangular variate (minimum, maximum, mode)."""
tri_rv(σ::Sim, name, a::Real, b::Real, c::Real) =
    sample_rv(σ, name, :triangular => (a, b, c))

"""Weibull variate (shape, scale) -- the reliability workhorse."""
weibull_rv(σ::Sim, name, shape::Real, scale::Real) =
    sample_rv(σ, name, :weibull => (shape, scale))

"""Gamma variate (shape, scale)."""
gamma_rv(σ::Sim, name, shape::Real, scale::Real) =
    sample_rv(σ, name, :gamma => (shape, scale))

"""Poisson variate with mean `λ`."""
poisson_rv(σ::Sim, name, λ::Real) = sample_rv(σ, name, :poisson => (λ,))

"""Resample one of the observed values (the bootstrap sampler)."""
empirical_rv(σ::Sim, name, values::AbstractVector{<:Real}) =
    sample_rv(σ, name, :empirical => (collect(Float64, values),))

"""Draw an index from a discrete distribution given by weights."""
discrete_rv(σ::Sim, name, weights::AbstractVector{<:Real}) =
    sample_rv(σ, name, :categorical => (collect(Float64, weights),))

"""Mean interarrival time implied by a rate."""
mean_of_rate(rate::Real) = 1 / rate