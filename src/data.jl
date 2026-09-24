# =============================================================================
# data.jl -- the plant data the models are calibrated from.
#
# A model is only as good as the numbers in it, so this file does the other half
# of the job: it generates a *plant history* (arrival gaps, service times,
# failure and repair times, demand sizes) that is deliberately not an exponential
# in disguise -- it drifts, it has a weekday pattern and a maintenance event that
# changes the service time -- and then it recovers the parameters from those
# observations the way a real project would:
#
# * maximum-likelihood fitting of several families (`fit_distribution`),
# * a Kolmogorov--Smirnov test of the fit, with the asymptotic p-value,
# * a bootstrap interval of every parameter (`bootstrap_ci`),
# * a model parameter record (`model_params_from_calibration`) that plugs straight
#   into `build_model`.
#
# Everything is seeded and deterministic, and every artefact is exportable as CSV
# or JSON, so a report can show the data, the fit, the uncertainty and the model
# that came out of it.
# =============================================================================

"""
    PlantHistory

The observations of a plant: one `series` per measured quantity (`:interarrival`,
`:service`, `:failure_interval`, `:repair`, `:demand_size`), the `counts` of the
events they came from, and a `meta` record (seed, window, drift, maintenance day).
"""
struct PlantHistory
    name::Symbol
    seed::Int
    days::Float64
    time_unit::Symbol
    series::SymDict
    counts::SymDict
    meta::SymDict
end

"""The observations of one series of a history (`Float64[]` when it has none)."""
function history_series(h::PlantHistory, key::Symbol)
    haskey(h.series, key) || return Float64[]
    return h.series[Sym(key)]
end

"""Every series of a history, as symbols."""
history_keys(h::PlantHistory) = Symbol[k for k in keys(h.series)]

"""A throw-away simulation used purely as a source of named random streams."""
_history_sim(seed::Integer, name::Symbol) = Sim(Symbol(:history, :_, name);
    seed = stream_seed(Int(seed), name, 7), strict = true, trace_events = false)

"""
    generate_history(; seed, days, drift, maintenance_day, service_improvement) -> PlantHistory

Build a deterministic plant history of `days` days (24 hours = 1440 minutes each):

* arrivals follow a rate that drifts linearly by `drift` over the window and
  carries a weekly pattern (weekends are 25% slower),
* service times are lognormal and improve by `service_improvement` after day
  `maintenance_day` -- the maintenance event a calibration has to notice,
* failures come with a Weibull interval and are repaired in a lognormal time,
* demand sizes are lognormal with an occasional large order.

The generator is intentionally *not* exponential: a calibration that assumed it
would fail its own Kolmogorov--Smirnov test, which is the point.
"""
function generate_history(; seed::Integer = 20_260_101, days::Real = 90.0,
    drift::Real = 0.25, maintenance_day::Real = 45.0, service_improvement::Real = 0.12,
    base_rate::Real = 0.8, service_mean::Real = 1.2, failure_mtbf::Real = 180.0,
    demand_rate::Real = 2.0, demand_mean::Real = 12.0)
    days = Float64(days)
    minutes = 1440.0 * days
    s = SymDict()

    ## ---- arrivals, with a drift and a weekly pattern ---------------------------
    σ_arr = _history_sim(seed, :arrivals)
    gaps = Float64[]
    t = 0.0
    while t < minutes
        day = floor(t / 1440.0)
        weekend = mod(day, 7.0) >= 5 ? 0.75 : 1.0
        rate = base_rate * (1 + drift * day / days) * weekend
        gap = exp_rv(σ_arr, :interarrival, rate)
        t += gap
        t < minutes || break
        push!(gaps, gap)
    end
    s[:interarrival] = gaps

    ## ---- service times, improved after the maintenance event -------------------
    σ_service = _history_sim(seed, :service)
    services = Float64[]
    while σ_service.now < minutes
        scale = floor(σ_service.now / 1440.0) >= maintenance_day ?
                (1 - service_improvement) : 1.0
        service = scale * log_normal_rv(σ_service, :service, log(service_mean), 0.45)
        push!(services, service)
        advance!(σ_service, service)
    end
    s[:service] = services

    ## ---- failures and repairs --------------------------------------------------
    σ_fail = _history_sim(seed, :failures)
    failure_gaps = Float64[]
    repairs = Float64[]
    # the scale that makes the Weibull interval average exactly `failure_mtbf`
    scale = failure_mtbf / mean(Weibull(1.6, 1.0))
    while σ_fail.now < minutes
        gap = weibull_rv(σ_fail, :failure, 1.6, scale)
        repair = log_normal_rv(σ_fail, :repair, log(10.0), 0.5)
        push!(failure_gaps, gap)
        push!(repairs, repair)
        advance!(σ_fail, gap + repair)
    end
    s[:failure_interval] = failure_gaps
    s[:repair] = repairs

    ## ---- demand ----------------------------------------------------------------
    σ_demand = _history_sim(seed, :demand)
    demands = Float64[]
    big = 0
    while σ_demand.now < days
        size = log_normal_rv(σ_demand, :size, log(demand_mean), 0.4)
        if rand_bool(σ_demand, :big_order, 0.05)
            size *= 4.0
            big += 1
        end
        push!(demands, size)
        advance!(σ_demand, exp_rv(σ_demand, :gap, demand_rate))
    end
    s[:demand_size] = demands

    counts = SymDict(:arrivals => length(gaps), :services => length(services),
        :failures => length(failure_gaps), :demands => length(demands),
        :big_orders => big)
    meta = SymDict(:days => days, :minutes => minutes, :drift => Float64(drift),
        :maintenance_day => Float64(maintenance_day),
        :service_improvement => Float64(service_improvement),
        :base_rate => Float64(base_rate), :service_mean => Float64(service_mean),
        :failure_mtbf => Float64(failure_mtbf), :demand_rate => Float64(demand_rate),
        :demand_mean => Float64(demand_mean), :seed => Int(seed),
        :generator => :plant_history_v1)
    return PlantHistory(:plant, Int(seed), days, :minutes, s, counts, meta)
end

## ---- describing the data --------------------------------------------------------

"""One row per series: how much of it there is and what it looks like."""
function summarize_history(h::PlantHistory)
    rows = SymDict[]
    for key in history_keys(h)
        x = history_series(h, key)
        row = SymDict()
        row[:series] = key
        row[:n] = length(x)
        row[:mean] = isempty(x) ? NaN : mean(x)
        row[:sd] = length(x) < 2 ? NaN : std(x)
        row[:cv] = isempty(x) || mean(x) == 0 ? NaN : std(x) / mean(x)
        row[:min] = isempty(x) ? NaN : minimum(x)
        row[:p50] = isempty(x) ? NaN : quantile(x, 0.5)
        row[:p95] = isempty(x) ? NaN : quantile(x, 0.95)
        row[:max] = isempty(x) ? NaN : maximum(x)
        row[:lag1] = autocorrelation(x, 1)
        push!(rows, row)
    end
    return rows
end

"""Write every series of a history as a CSV (one file per series)."""
function write_history_csv(h::PlantHistory, dir::AbstractString; max_rows::Integer = 20_000)
    mkpath(dir)
    paths = String[]
    for key in history_keys(h)
        x = history_series(h, key)
        path = joinpath(dir, string("observations_", code_string(key), ".csv"))
        open(path, "w") do io
            println(io, "index,", code_string(key))
            for (i, v) in enumerate(x)
                i > max_rows && break
                println(io, i, ",", v)
            end
        end
        push!(paths, path)
    end
    return paths
end

## ---- fitting a distribution to observations -------------------------------------

"""
    fit_distribution(kind, x) -> SymDict

Maximum-likelihood fit of one family to observations, returned in the
`:kind`/`:params` form the whole package speaks (the same form `dist` reads back):

```julia
fit = fit_distribution(:lognormal, service_times)
dist(fit)                       # the distribution again
fit[:params]                    # (2.1, 0.42)
```

The record also carries the log-likelihood, the AIC and a Kolmogorov--Smirnov
statistic with its p-value, so the report can say *how good* the fit is.
"""
function fit_distribution(kind::Symbol, x::AbstractVector{<:Real})
    data = Float64.(x)
    n = length(data)
    n >= 3 || throw(ArgumentError("fitting needs at least three observations"))
    k = Sym(kind)
    d, params = _fit_family(k, data)
    km = ks_test(data, d)
    ll = sum(log(max(pdf(d, v), 1e-300)) for v in data)
    rec = SymDict()
    rec[:kind] = k
    rec[:params] = params
    rec[:n] = n
    rec[:mean] = mean(d)
    rec[:sd] = std(d)
    rec[:cv] = iszero(mean(d)) ? Inf : std(d) / abs(mean(d))
    rec[:loglik] = ll
    rec[:aic] = 2 * length(params) - 2 * ll
    rec[:ks_stat] = km.stat
    rec[:ks_p] = km.p
    rec[:fits] = km.p > 0.05
    rec[:sample_mean] = mean(data)
    rec[:sample_sd] = std(data)
    return rec
end

"""Fit one family, returning the distribution and the parameters in `dist` form."""
function _fit_family(k::Symbol, data::Vector{Float64})
    if k === :exponential
        d = Distributions.fit(Exponential, data)
        return d, (1 / d.θ,)
    elseif k === :lognormal
        d = Distributions.fit(LogNormal, data)
        return d, (d.μ, d.σ)
    elseif k === :gamma
        d = Distributions.fit(Gamma, data)
        return d, (d.α, d.θ)
    elseif k === :weibull
        d = Distributions.fit(Weibull, data)
        return d, (d.α, d.θ)
    elseif k === :normal
        d = Distributions.fit(Normal, data)
        return d, (d.μ, d.σ)
    elseif k === :uniform
        lo, hi = extrema(data)
        return Uniform(lo, hi), (lo, hi)
    elseif k === :triangular
        lo, hi = extrema(data)
        mode = quantile(data, 0.5)
        return TriangularDist(lo, hi, mode), (lo, hi, mode)
    elseif k === :empirical
        return Distributions.DiscreteNonParametric(data, fill(1 / length(data), length(data))),
               (data,)
    end
    throw(ArgumentError("cannot fit :$k; try :exponential, :lognormal, :gamma, " *
                        ":weibull, :normal, :uniform, :triangular or :empirical"))
end

## ---- is the fit believable? -----------------------------------------------------

"""
    ks_test(x, d) -> (; stat, p)

Kolmogorov--Smirnov statistic of a sample against a distribution, with the
asymptotic p-value of the Kolmogorov distribution
(`Q(λ) = 2 Σ (-1)^(k-1) exp(-2k²λ²)`, `λ = (√n + 0.12 + 0.11/√n) D`), which is
the test a calibration uses to reject a family it cannot defend.
"""
function ks_test(x::AbstractVector{<:Real}, d)
    data = sort(Float64.(x))
    n = length(data)
    n == 0 && return (stat = NaN, p = NaN)
    d_max = 0.0
    for (i, v) in enumerate(data)
        cdf_hi = cdf(d, v)
        d_max = max(d_max, i / n - cdf_hi, cdf_hi - (i - 1) / n)
    end
    λ = (sqrt(n) + 0.12 + 0.11 / sqrt(n)) * d_max
    return (stat = d_max, p = kolmogorov_q(λ))
end

"""Asymptotic Kolmogorov distribution `Q(λ) = P(D > λ)`."""
function kolmogorov_q(λ::Real)
    λ <= 0 && return 1.0
    total = 0.0
    for k in 1:200
        term = (-1)^(k - 1) * exp(-2 * k^2 * λ^2)
        total += term
        abs(term) < 1e-14 && break
    end
    return clamp(2 * total, 0.0, 1.0)
end

"""
    best_fit(x, kinds) -> SymDict

Fit several families to one series and return the one with the smallest
Kolmogorov--Smirnov statistic (ties broken by the AIC), with the whole ranking in
`:ranking` and every candidate in `:candidates`.
"""
function best_fit(x::AbstractVector{<:Real},
    kinds = (:exponential, :lognormal, :gamma, :weibull, :normal))
    records = SymDict[]
    for k in kinds
        rec = try
            fit_distribution(k, x)
        catch
            continue
        end
        push!(records, rec)
    end
    isempty(records) && throw(ArgumentError("no candidate family could be fitted"))
    order = sortperm(records; by = r -> (r[:ks_stat], r[:aic]))
    best = copy(records[order[1]])
    ranking = SymDict()
    for (i, idx) in enumerate(order)
        ranking[records[idx][:kind]] = SymDict(:rank => i, :ks_stat => records[idx][:ks_stat],
            :ks_p => records[idx][:ks_p], :aic => records[idx][:aic],
            :mean => records[idx][:mean])
    end
    best[:ranking] = ranking
    best[:candidates] = records
    return best
end

## ---- calibrating a model from the data -----------------------------------------

"""
    calibrate(h::PlantHistory; families) -> SymDict

Fit a distribution to every series of a history and summarise the result as one
symbol-keyed record: `:interarrival`, `:service`, `:failure_interval`, `:repair`
and `:demand_size`, each with its fitted family, its parameters, its
Kolmogorov--Smirnov verdict and the implied process parameter (`:arrival_rate`,
`:service_rate`, `:mtbf`, `:mttr`, `:demand_mean`).
"""
function calibrate(h::PlantHistory; families = (:exponential, :lognormal, :gamma, :weibull))
    d = SymDict()
    d[:history] = h.name
    d[:days] = h.days
    d[:source] = :generated
    for key in history_keys(h)
        x = history_series(h, key)
        length(x) >= 5 || continue
        d[key] = best_fit(x, families)
    end
    d[:parameters] = inferred_parameters(d)
    return d
end

"""
    inferred_parameters(cal) -> SymDict

The process parameters a calibration implies, each in the `:kind`/`:params` form
so it can be used directly as a model parameter: the arrival rate is the
reciprocal of the mean interarrival time, the service rate the reciprocal of the
mean service time, and so on.
"""
function inferred_parameters(cal::AbstractDict)
    p = SymDict()
    if haskey(cal, :interarrival)
        fit = cal[:interarrival]
        p[:interarrival] = dist_spec(fit[:kind], fit[:params]...)
        p[:arrival_rate] = 1 / fit[:mean]
        p[:arrival_cv2] = fit[:cv]^2
    end
    if haskey(cal, :service)
        fit = cal[:service]
        p[:service] = dist_spec(fit[:kind], fit[:params]...)
        p[:service_rate] = 1 / fit[:mean]
        p[:service_cv2] = fit[:cv]^2
    end
    if haskey(cal, :failure_interval)
        fit = cal[:failure_interval]
        p[:failure_interval] = dist_spec(fit[:kind], fit[:params]...)
        p[:mtbf] = fit[:mean]
    end
    if haskey(cal, :repair)
        fit = cal[:repair]
        p[:repair] = dist_spec(fit[:kind], fit[:params]...)
        p[:mttr] = fit[:mean]
        if haskey(p, :mtbf) && p[:mtbf] > 0
            p[:availability] = p[:mtbf] / (p[:mtbf] + p[:mttr])
        end
    end
    if haskey(cal, :demand_size)
        fit = cal[:demand_size]
        p[:demand_size] = dist_spec(fit[:kind], fit[:params]...)
        p[:demand_mean] = fit[:mean]
    end
    return p
end

"""
    model_params_from_calibration(cal; model, overrides...) -> SymDict

Turn a calibration into the parameter record of a model, starting from the model
defaults and replacing what the data can actually say (the arrival rate, the
service rate, the MTBF/MTTR), so the resulting model is the plant, not the
textbook.
"""
function model_params_from_calibration(cal::AbstractDict, model::Symbol; overrides...)
    p = model_params(model, overrides...)
    q = get(cal, :parameters, SymDict())
    k = Sym(model)
    if haskey(q, :arrival_rate)
        p[:arrival_rate] = q[:arrival_rate]
    end
    if haskey(q, :service_rate) && k in (:mmc, :call_center)
        p[:service_rate] = q[:service_rate]
    end
    if haskey(q, :mtbf) && k in (:machine_shop, :transfer_line)
        p[:mtbf] = q[:mtbf]
    end
    if haskey(q, :mttr) && k in (:machine_shop, :transfer_line)
        p[:mttr] = q[:mttr]
    end
    if haskey(q, :demand_mean) && k === :inventory
        p[:demand_size] = q[:demand_mean]
    end
    return p
end

"""The calibration as one table (the body of the report's calibration section)."""
function calibration_table(cal::AbstractDict)
    rows = NamedTuple[]
    for (key, fit) in cal
        fit isa SymDict || continue
        haskey(fit, :kind) || continue
        push!(rows, (series = key, family = fit[:kind], params = fit[:params],
            mean = fit[:mean], sd = fit[:sd], cv = fit[:cv], n = fit[:n],
            ks_stat = fit[:ks_stat], ks_p = fit[:ks_p], fits = fit[:fits],
            sample_mean = fit[:sample_mean]))
    end
    return rows
end

"""
    bootstrap_ci(x, kind, parameter; reps, level, seed) -> (; lo, hi, median, n)

Bootstrap confidence interval of one parameter of a fitted family: resample the
observations `reps` times, refit and read the percentiles. It is slower than the
maximum-likelihood standard error and needs no theory, which is why it is what a
calibration report usually quotes.
"""
function bootstrap_ci(x::AbstractVector{<:Real}, kind::Symbol, parameter::Integer;
    reps::Integer = 200, level::Real = 0.95, seed::Integer = 20_260_101)
    data = Float64.(x)
    n = length(data)
    rng = StableRNGs.StableRNG(stream_seed(Int(seed), :bootstrap, Int(reps)))
    values = Float64[]
    sample = Vector{Float64}(undef, n)
    for _ in 1:Int(reps)
        for i in 1:n
            sample[i] = data[rand(rng, 1:n)]
        end
        rec = try
            fit_distribution(kind, sample)
        catch
            continue
        end
        push!(values, Float64(rec[:params][parameter]))
    end
    isempty(values) && return (lo = NaN, hi = NaN, median = NaN, n = 0)
    return (lo = quantile(values, (1 - level) / 2), hi = quantile(values, 1 - (1 - level) / 2),
        median = quantile(values, 0.5), n = length(values))
end
