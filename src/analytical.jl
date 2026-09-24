# =============================================================================
# analytical.jl -- the formulas a simulation has to agree with.
#
# A discrete-event simulator is only credible when it reproduces the closed-form
# results of queueing theory, so the engine ships those results and compares them
# with the runs: M/M/1, M/M/c (Erlang C), M/D/1, M/G/1 (Pollaczek--Khinchine),
# the Kingman approximation for G/G/1, the finite-capacity systems M/M/1/K and
# M/M/c/K, and the loss system M/M/c/c (Erlang B).
#
# `theory(:mmc; λ = 0.8, μ = 1.0, c = 2)` returns a symbol-keyed record
# (`:rho`, `:Lq`, `:Wq`, `:W`, `:L`, `:pw`, ...) and `validate_against_theory`
# turns that record and a simulation summary into a verdict:
# `:validated`, `:marginal` or `:failed`.
# =============================================================================

"""`n!` as a float (kept separate so the formulas read like the textbooks)."""
_factorial(n::Integer) = Float64(factorial(n))

"""
    erlang_b(a, c) -> Float64

Erlang's loss formula: the probability that all `c` servers of a loss system with
offered load `a = λ/μ` are busy. Evaluated with the stable recursion
`B_0 = 1`, `B_i = a B_(i-1) / (i + a B_(i-1))`.
"""
function erlang_b(a::Real, c::Integer)
    a <= 0 && return 0.0
    b = 1.0
    for i in 1:Int(c)
        b = a * b / (i + a * b)
    end
    return b
end

"""
    erlang_c(a, c) -> Float64

Erlang's delay formula: the probability that an arrival has to wait with `c`
servers and offered load `a` (`ρ = a/c < 1`). Derived from `erlang_b`, which
keeps it numerically stable for hundreds of servers.
"""
function erlang_c(a::Real, c::Integer)
    ρ = a / c
    ρ >= 1 && return 1.0
    b = erlang_b(a, c)
    return b / (1 - ρ * (1 - b))
end

"""Empty result record with the keys every `theory` call fills in."""
function _theory_record(kind::Symbol, λ::Real, μ::Real, c::Integer)
    d = SymDict()
    d[:kind] = Sym(kind)
    d[:λ] = Float64(λ)
    d[:μ] = Float64(μ)
    d[:c] = Int(c)
    d[:a] = Float64(λ) / Float64(μ)
    d[:rho] = Float64(λ) / (Float64(μ) * Int(c))
    d[:servers] = Int(c)
    d[:approximate] = false
    return d
end

"""Fill the derived statistics of a single station (`L = λW` included)."""
function _fill_station!(d::SymDict; λ_eff = nothing)
    λ = something(λ_eff, d[:λ])
    d[:utilisation] = min(d[:rho], 1.0)
    d[:W] = d[:Wq] + 1 / d[:μ]
    d[:L] = λ * d[:W]
    return d
end

"""
    theory(kind; λ, μ, c = 1, cs2 = 1.0, ca2 = 1.0, K = 0) -> SymDict

Closed-form performance of the standard single-station systems. `λ` is the
arrival rate, `μ` the service rate of one server, `c` the number of servers,
`ca2`/`cs2` the squared coefficients of variation of the interarrival and service
time distributions and `K` the capacity of a finite system.

```julia
theory(:mmc; λ = 0.8, μ = 1.0, c = 2)     # the Erlang C queue
theory(:md1; λ = 0.8, μ = 1.0)            # deterministic service
theory(:gg1_approx; λ = 0.8, μ = 1.0, ca2 = 0.5, cs2 = 2.0)
```
"""
function theory(kind::Symbol; λ::Real = 0.0, μ::Real = 1.0, c::Integer = 1,
    cs2::Real = 1.0, ca2::Real = 1.0, K::Integer = 0)
    k = Sym(kind)
    k in THEORY_KINDS || throw(ArgumentError(string("unknown theory :", k, "; known: ",
        join(code_string.(THEORY_KINDS), ", "))))
    μ > 0 || throw(ArgumentError("the service rate must be positive"))
    d = _theory_record(k, λ, μ, c)
    ρ = d[:rho]

    if k === :mm1
        ρ >= 1 && throw(ArgumentError("M/M/1 with ρ = $ρ >= 1 has no steady state"))
        d[:P0] = 1 - ρ
        d[:pw] = ρ
        d[:Lq] = ρ^2 / (1 - ρ)
        d[:Wq] = d[:Lq] / λ
        return _fill_station!(d)
    elseif k === :mmc || k === :erlang_c
        ρ >= 1 && throw(ArgumentError("M/M/c with ρ = $ρ >= 1 has no steady state"))
        a = d[:a]
        p0 = 1 / (sum(a^n / _factorial(n) for n in 0:(c - 1)) +
                  a^c / (_factorial(c) * (1 - ρ)))
        d[:P0] = p0
        d[:pw] = erlang_c(a, c)
        d[:Lq] = d[:pw] * ρ / (1 - ρ)
        d[:Wq] = d[:Lq] / λ
        return _fill_station!(d)
    elseif k === :md1
        d[:pw] = ρ
        d[:Wq] = ρ / (2μ * (1 - ρ))
        d[:Lq] = λ * d[:Wq]
        return _fill_station!(d)
    elseif k === :mg1
        d[:pw] = ρ
        d[:Wq] = ρ * (1 + cs2) / (2μ * (1 - ρ))
        d[:Lq] = λ * d[:Wq]
        return _fill_station!(d)
    elseif k === :gg1_approx
        d[:approximate] = true
        d[:pw] = ρ
        d[:Wq] = (ca2 + cs2) / 2 * ρ / (μ * (1 - ρ))
        d[:Lq] = λ * d[:Wq]
        return _fill_station!(d)
    elseif k === :mm1k
        K >= 1 || throw(ArgumentError("M/M/1/K needs a capacity K >= 1"))
        p0 = isapprox(ρ, 1.0) ? 1 / (K + 1) : (1 - ρ) / (1 - ρ^(K + 1))
        probs = [p0 * ρ^n for n in 0:K]
        d[:P0] = p0
        d[:loss] = probs[end]
        d[:λ_eff] = λ * (1 - probs[end])
        d[:L] = sum(n * probs[n + 1] for n in 0:K)
        d[:Lq] = sum(max(n - 1, 0) * probs[n + 1] for n in 0:K)
        d[:W] = d[:L] / d[:λ_eff]
        d[:Wq] = d[:Lq] / d[:λ_eff]
        return _fill_station!(d; λ_eff = d[:λ_eff])
    elseif k === :mmcc
        d[:blocking] = erlang_b(d[:a], c)
        d[:loss] = d[:blocking]
        d[:λ_eff] = λ * (1 - d[:blocking])
        d[:L] = d[:a] * (1 - d[:blocking])
        d[:Lq] = 0.0
        d[:Wq] = 0.0
        d[:W] = 1 / μ
        d[:utilisation] = d[:L] / c
        d[:pw] = 0.0
        return d
    elseif k === :mmck || k === :erlang_b
        K >= c || throw(ArgumentError("M/M/c/K needs a capacity K >= c"))
        a = d[:a]
        ## `Float64(c)` matters: an integer power overflows long before K is large
        weights = [n <= c ? a^n / _factorial(n) :
                   a^n / (_factorial(c) * Float64(c)^(n - c)) for n in 0:K]
        probs = weights ./ sum(weights)
        d[:P0] = probs[1]
        d[:loss] = probs[end]
        d[:blocking] = probs[end]
        d[:λ_eff] = λ * (1 - probs[end])
        d[:λ_eff] > 0 || throw(ArgumentError("M/M/c/K with these parameters blocks everything"))
        d[:L] = sum(n * probs[n + 1] for n in 0:K)
        d[:Lq] = sum(max(n - c, 0) * probs[n + 1] for n in 0:K)
        d[:pw] = c <= K ? sum(probs[(c + 1):end]) : 0.0
        d[:W] = d[:L] / d[:λ_eff]
        d[:Wq] = d[:Lq] / d[:λ_eff]
        return _fill_station!(d; λ_eff = d[:λ_eff])
    end
    throw(ArgumentError("unimplemented theory :$k"))
end

## ---- comparing a run with the formulas -----------------------------------------

"""
    validate_against_theory(observed, theoretical; key_map, tolerance = 0.05,
                            marginal = 0.10, label = :simulation) -> SymDict

Compare the numbers a run produced (`observed`, a symbol-keyed record) with a
[`theory`](@ref) record. `key_map` says which observed key answers which
theoretical key, e.g. `[:wait => :Wq, :queue_length => :Lq]`. Every comparison
carries its relative error, and the record gets an overall verdict:
`:validated` (all within `tolerance`), `:marginal` (within `marginal`) or
`:failed`.
"""
function validate_against_theory(observed::AbstractDict, theoretical::AbstractDict;
    key_map::Vector{Pair{Symbol,Symbol}} = Pair{Symbol,Symbol}[],
    tolerance::Real = 0.05, marginal::Real = 0.10, label::Symbol = :simulation)
    rows = SymDict[]
    worst = 0.0
    for (obs_key, theo_key) in key_map
        (haskey(observed, obs_key) && haskey(theoretical, theo_key)) || continue
        got, want = observed[obs_key], theoretical[theo_key]
        (got isa Real && want isa Real) || continue
        (isfinite(Float64(got)) && isfinite(Float64(want))) || continue
        rel = relative_error(Float64(got), Float64(want))
        push!(rows, SymDict(:observed_key => Sym(obs_key), :theory_key => Sym(theo_key),
            :observed => Float64(got), :theory => Float64(want), :relative_error => rel,
            :within_tolerance => rel <= tolerance))
        worst = max(worst, rel)
    end
    verdict = isempty(rows) ? :not_applicable :
              worst <= tolerance ? :validated :
              worst <= marginal ? :marginal : :failed
    d = SymDict()
    d[:label] = Sym(label)
    d[:system] = get(theoretical, :kind, :unknown)
    d[:approximate_theory] = get(theoretical, :approximate, false)
    d[:comparisons] = rows
    d[:n_comparisons] = length(rows)
    d[:worst_relative_error] = worst
    d[:tolerance] = Float64(tolerance)
    d[:verdict] = verdict
    return d
end

"""Relative error of two numbers (`0.0` when the reference is zero)."""
function relative_error(got::Real, want::Real)
    iszero(want) && return 0.0
    return abs(got - want) / abs(want)
end

"""The `observed` record of a run: the queueing numbers of one resource."""
function observed_summary(σ::Sim, name::Symbol)
    r = σ.resources[Sym(name)]::Resource
    span = σ.now - σ.warmup
    d = SymDict()
    d[:wait] = mean_wait(r)
    d[:service] = mean_service(r)
    d[:queue_length] = mean_queue_length(r)
    d[:utilisation] = utilisation(r)
    d[:in_use] = mean_in_use(r)
    d[:in_system] = d[:queue_length] + d[:in_use]
    d[:requests] = r.wait.count
    d[:served] = count_of(r.granted, :release)
    d[:span] = span
    d[:throughput] = span > 0 ? d[:requests] / span : NaN
    d[:departures] = span > 0 ? d[:served] / span : NaN
    d[:sojourn] = d[:wait] + d[:service]
    return d
end

"""
    little_law(σ, name) -> SymDict

Check Little's law for one resource of a run: `L = λW`, with `L` the mean number
in the resource system, `λ` the measured *departure* rate (the rate at which the
resource actually let work through, which is what makes the identity hold even
when the backlog is still growing) and `W` the mean wait plus service time. The
result carries both sides and their relative difference, which is the quickest
sanity check of a queueing model.
"""
function little_law(σ::Sim, name::Symbol)
    obs = observed_summary(σ, name)
    λ_eff = obs[:departures]
    l = obs[:in_system]
    w = obs[:sojourn]
    d = SymDict()
    d[:resource] = Sym(name)
    d[:L] = l
    d[:λ] = λ_eff
    d[:W] = w
    d[:λW] = λ_eff * w
    d[:relative_error] = iszero(l) ? 0.0 : abs(l - λ_eff * w) / abs(l)
    d[:holds] = d[:relative_error] <= 0.05
    return d
end

"""Theoretical utilisation of a resource of a run (`NaN` when undefined)."""
theoretical_utilisation(λ::Real, μ::Real, c::Integer) = λ / (μ * c)