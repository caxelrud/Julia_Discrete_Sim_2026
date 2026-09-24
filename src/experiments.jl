# =============================================================================
# experiments.jl -- turning a model into an experiment.
#
# One simulation run answers nothing: the numbers of a discrete-event model are
# autocorrelated, so a single long run has no honest confidence interval. This
# file implements what the textbooks prescribe and what a decision needs:
#
# * **Replications.** `experiment` runs a model `n` times with independent seeds
#   and reports every metric as a mean with a Student-t interval.
# * **Warmup detection.** `warmup_analysis` runs Welch's graphical procedure:
#   average the response across replications, smooth it with a moving average and
#   return the first time at which it has settled, so the transient is discarded
#   deliberately instead of by habit.
# * **Batch means.** `batch_means` gives an interval for one long run that
#   accounts for the autocorrelation inside it.
# * **Paired comparisons.** Because streams are named, two scenarios in the same
#   replication see the same randomness, so `compare_scenarios` reports the
#   *difference* with a confidence interval -- far sharper than comparing two
#   independent means.
# * **Sweeps and factorial designs.** `sweep` walks one parameter and
#   `factorial_design` estimates main effects and two-factor interactions.
#
# Every result is a symbol-keyed record, so a notebook and the printed report
# show the same numbers.
# =============================================================================

"""
    ExperimentConfig

The design of a set of runs: how many `replications`, how long each run is
(`horizon`), how much of the start is discarded (`warmup`), the base `seed`, the
confidence `level`, whether the runs may be spread over threads (`parallel`) and
whether the event trace is kept (`trace`).
"""
Base.@kwdef mutable struct ExperimentConfig
    replications::Int = 20
    horizon::Float64 = 2000.0
    warmup::Float64 = 0.0
    seed::Int = 20260101
    parallel::Bool = false
    trace::Bool = false
    level::Float64 = 0.95
end

ExperimentConfig(d::AbstractDict) = begin
    known = Set{Symbol}(fieldnames(ExperimentConfig))
    ExperimentConfig(; (Sym(k) => v for (k, v) in d if Sym(k) in known)...)
end

"""
    seed_for(base, k) -> Int

Seed of replication `k`: derived from the base seed, so a whole experiment is
reproducible from one number, and the same replication index in two scenarios
produces the same randomness (common random numbers).
"""
seed_for(base::Integer, k::Integer) = stream_seed(Int(base), :replication, Int(k))

"""
    run_options(cfg, k; scenario = nothing, params = nothing) -> SymDict

The symbol-keyed options of one replication: everything a model builder needs
(`:seed`, `:horizon`, `:warmup`, `:trace`, `:replication`, `:scenario`, `:params`).
"""
function run_options(cfg::ExperimentConfig, k::Integer; scenario = nothing, params = nothing)
    d = SymDict()
    d[:seed] = seed_for(cfg.seed, k)
    d[:horizon] = cfg.horizon
    d[:warmup] = cfg.warmup
    d[:trace] = cfg.trace
    d[:replication] = Int(k)
    d[:level] = cfg.level
    scenario === nothing || (d[:scenario] = scenario)
    params === nothing || (d[:params] = params)
    return d
end

"""Metric name a statistic contributes to the system metrics of a run."""
const STATISTIC_METRIC_MAP = (
    wait = :wait_mean,
    sojourn = :cycle_time_mean,
    service = :service_mean,
    queue_length = :queue_length_mean,
    in_system = :in_system_mean,
    wip = :wip_mean,
    utilisation = :utilisation,
    inventory = :inventory_mean,
    backlog = :backlog_mean,
    tardiness = :tardiness_mean,
    setup = :setup,
    blocked = :blocked_fraction,
    starved = :starved_fraction,
)

"""
Metric a statistic with this name feeds: the explicit table first, then the name
itself when it is already a system metric (so a `TimeWeighted` statistic called
`:wip_mean` feeds `:wip_mean` without being listed).
"""
function metric_of_statistic(name)
    k = Sym(name)
    haskey(STATISTIC_METRIC_MAP, k) && return STATISTIC_METRIC_MAP[k]
    return k in SYSTEM_METRICS ? k : :none
end

"""
    collect_metrics(σ; resources = true) -> SymDict

The system metrics of one finished run: what the model set explicitly
(`metric!`), what the statistics imply (means, quantiles, counters) and what the
resources measured (utilisation, availability, worst queue). This is the record
that `experiment` aggregates into confidence intervals.
"""
function collect_metrics(σ::Sim; resources::Bool = true)
    d = SymDict()
    span = measured_span(σ)

    for (k, v) in σ.metrics
        v isa Real && !(v isa Bool) && (d[k] = Float64(v))
    end

    for (name, st) in σ.stats
        target = metric_of_statistic(name)
        target === :none && continue
        if st isa Tally
            d[target] = mean(st)
            st.count > 0 && target === :wait_mean && (d[:wait_p95] = quantile(st, 0.95))
        elseif st isa TimeWeighted
            d[target] = mean(st)
        elseif st isa Counter
            d[target] = Float64(total_of(st))
            target === :completed && span > 0 && (d[:throughput] = total_of(st) / span)
        end
    end

    if resources
        rs = Resource[r for (_, r) in σ.resources if r isa Resource]
        if !isempty(rs)
            haskey(d, :utilisation) ||
                (d[:utilisation] = sum(utilisation(r) for r in rs) / length(rs))
            d[:availability] = minimum(availability(r) for r in rs)
            d[:max_queue_length] = maximum(mean_queue_length(r) for r in rs)
            if !haskey(d, :wait_mean) && sum(r.wait.count for r in rs) > 0
                d[:wait_mean] = sum(mean_wait(r) * r.wait.count for r in rs) /
                                sum(r.wait.count for r in rs)
            end
            if !haskey(d, :queue_length_mean)
                d[:queue_length_mean] = sum(mean_queue_length(r) for r in rs)
            end
        end
    end

    d[:span] = span
    d[:events] = σ.processed
    d[:stop_reason] = σ.stop_reason
    return d
end

## ---- one experiment ------------------------------------------------------------

"""
    ExperimentResult

The outcome of a set of runs: the per-replication records (`:per_replication`),
the aggregate of every metric with its confidence interval (`:summary`), the
design that produced them (`:config`) and one sample run for the figures
(`:sample`).
"""
struct ExperimentResult
    name::Symbol
    kind::Symbol
    config::ExperimentConfig
    scenario::SymDict
    per_replication::Vector{SymDict}
    summary::SymDict
    sample::Any
    notes::SymDict
end

"""Summary of one metric of an experiment (`nothing` when the metric is absent)."""
metric_ci(res::ExperimentResult, key::Symbol) =
    haskey(res.summary, Sym(key)) ? res.summary[Sym(key)] : nothing

"""Mean of one metric of an experiment (`NaN` when the metric is absent)."""
metric_value(res::ExperimentResult, key::Symbol) =
    (c = metric_ci(res, key)) === nothing ? NaN : c[:mean]

"""Per-replication values of one metric of an experiment."""
function metric_series(res::ExperimentResult, key::Symbol)
    k = Sym(key)
    return Float64[row[k] for row in res.per_replication if haskey(row, k)]
end

"""Every metric an experiment measured."""
metric_keys(res::ExperimentResult) = Symbol[k for k in keys(res.summary)]

"""Metrics of an experiment, as one table (the body of the report's table)."""
function metric_table(res::ExperimentResult; keys = metric_keys(res))
    rows = NamedTuple[]
    for k in keys
        c = metric_ci(res, k)
        c === nothing && continue
        push!(rows, (metric = k, unit = metric_unit(k), mean = c[:mean], sd = c[:sd],
            half_width = c[:half_width], lo = c[:lo], hi = c[:hi], n = c[:n],
            relative_half_width = c[:relative_half_width], adequate = c[:adequate]))
    end
    return rows
end

"""A compact one-line summary of an experiment (for the console and the log)."""
function describe_experiment(res::ExperimentResult; keys = (:throughput, :cycle_time_mean,
    :wait_mean, :utilisation))
    parts = String[]
    for k in keys
        c = metric_ci(res, k)
        c === nothing && continue
        push!(parts, string(code_string(k), "=", round(c[:mean], digits = 3),
            "±", round(c[:half_width], digits = 3)))
    end
    return string(":", res.name, " ", code_string(res.kind), " (", res.config.replications,
        " reps, h=", res.config.horizon, ") ", join(parts, "  "))
end

## ---- running a design ----------------------------------------------------------

"""
    run_replication(build, cfg, k; scenario, params) -> Sim

Run replication `k` of a design: build the model from the run options, apply the
warmup and run to the horizon.
"""
function run_replication(build::Base.Callable, cfg::ExperimentConfig, k::Integer;
    scenario = nothing, params = nothing)
    opts = run_options(cfg, k; scenario = scenario, params = params)
    σ = build(opts)
    σ isa Sim || throw(ArgumentError("a model builder must return a Sim, got $(typeof(σ))"))
    cfg.warmup > 0 && warmup!(σ, cfg.warmup)
    run!(σ; until = cfg.horizon)
    return σ
end

"""Aggregate the per-replication records of an experiment into confidence intervals."""
function summarize_records(records::Vector{SymDict}; level::Real = 0.95)
    out = SymDict()
    isempty(records) && return out
    for k in numeric_keys(records[1])
        vals = Float64[row[k] for row in records if haskey(row, k) && row[k] isa Real]
        isempty(vals) && continue
        out[k] = mean_ci(vals; level = level)
    end
    return out
end

"""
    experiment(build, cfg; name, scenario, params, kind) -> ExperimentResult

Run `cfg.replications` independent replications of a model and aggregate every
metric into a mean with a confidence interval. `build` is called with the
symbol-keyed run options of the replication (see [`run_options`](@ref)) and must
return a `Sim`.

```julia
res = experiment(opts -> build_model(:mmc, params, opts),
                 ExperimentConfig(replications = 20, horizon = 5000.0, warmup = 500.0))
metric_value(res, :wait_mean)
```
"""
function experiment(build::Base.Callable, cfg::ExperimentConfig = ExperimentConfig();
    name::Symbol = :experiment, scenario = nothing, params = nothing,
    collector::Base.Callable = collect_metrics, kind::Symbol = :replications)
    sims = Vector{Any}(undef, cfg.replications)
    if cfg.parallel && Threads.nthreads() > 1
        tasks = [Threads.@spawn run_replication(build, cfg, k; scenario = scenario,
            params = params) for k in 1:cfg.replications]
        for k in 1:cfg.replications
            sims[k] = fetch(tasks[k])
        end
    else
        for k in 1:cfg.replications
            sims[k] = run_replication(build, cfg, k; scenario = scenario, params = params)
        end
    end
    records = SymDict[collector(σ) for σ in sims]
    notes = SymDict()
    bad = count(r -> get(r, :stop_reason, :horizon) === :max_events ||
                     get(r, :stop_reason, :horizon) === :wall_clock, records)
    bad > 0 && (notes[:truncated_runs] = bad)
    return ExperimentResult(Sym(name), Sym(kind), cfg,
        scenario === nothing ? SymDict() : SymDict(scenario), records,
        summarize_records(records; level = cfg.level),
        isempty(sims) ? nothing : sims[1], notes)
end

"""All per-replication records of an experiment, as a table."""
replications_table(res::ExperimentResult) = [to_named_tuple(r) for r in res.per_replication]

## ---- how long the transient lasts ----------------------------------------------

"""Linearly interpolate a series onto a grid (`NaN` outside the span of the series)."""
function interpolate_series(times::AbstractVector{<:Real}, values::AbstractVector{<:Real},
    grid::AbstractVector{<:Real})
    out = fill(NaN, length(grid))
    n = length(times)
    n == 0 && return out
    j = 1
    for (i, g) in enumerate(grid)
        g < times[1] && continue
        g > times[n] && break
        while j < n - 1 && times[j + 1] < g
            j += 1
        end
        dt = times[j + 1] - times[j]
        out[i] = dt == 0 ? values[j] :
                 values[j] + (values[j + 1] - values[j]) * (g - times[j]) / dt
    end
    return out
end

"""
    warmup_analysis(build, cfg; series = :wip, replications = 5, window = 20,
                    tolerance = 0.5) -> SymDict

Welch's procedure for the length of the transient: run `replications` copies of
the model, average the recorded `series` across them on a common time grid,
smooth it with a moving average of `window` points and report the first time from
which the smoothed curve stays inside `tolerance` standard deviations of the
plateau mean.

The returned record carries the curve, the smoothed curve, the band and the
suggested `:warmup`, which is what `cfg.warmup` should be set to.
"""
function warmup_analysis(build::Base.Callable, cfg::ExperimentConfig;
    series::Symbol = :wip, replications::Integer = cfg.replications, window::Integer = 20,
    tolerance::Real = 0.5, grid_points::Integer = 400)
    grid = collect(range(0.0, cfg.horizon; length = Int(grid_points)))
    cols = Vector{Vector{Float64}}()
    for k in 1:Int(replications)
        σ = run_replication(build, cfg, k)
        st = get(σ.stats, Sym(series), nothing)
        st isa Recorder || continue
        push!(cols, interpolate_series(st.times, st.values, grid))
    end
    d = SymDict()
    d[:series] = Sym(series)
    d[:replications] = length(cols)
    d[:times] = grid
    isempty(cols) && (d[:warmup] = 0.0; return d)

    averaged = Float64[]
    for i in eachindex(grid)
        vals = Float64[c[i] for c in cols if !isnan(c[i])]
        push!(averaged, isempty(vals) ? NaN : sum(vals) / length(vals))
    end
    smoothed = fill(NaN, length(averaged))
    w = min(Int(window), length(averaged))
    for i in w:length(averaged)
        slice = @view averaged[(i - w + 1):i]
        any(isnan, slice) || (smoothed[i] = sum(slice) / w)
    end
    d[:averaged] = averaged
    d[:smoothed] = smoothed
    d[:window] = w

    valid = findall(!isnan, smoothed)
    if isempty(valid)
        d[:warmup] = 0.0
        return d
    end
    half = valid[max(1, div(length(valid), 2)):end]
    plateau = sum(smoothed[i] for i in half) / length(half)
    spread = sqrt(max(sum((smoothed[i] - plateau)^2 for i in half) /
                      max(length(half) - 1, 1), 0.0))
    band = Float64(tolerance) * spread
    t_star = 0.0
    for idx in eachindex(valid)
        stable = all(abs(smoothed[j] - plateau) <= band for j in valid[idx:end])
        if stable
            t_star = grid[valid[idx]]
            break
        end
    end
    d[:plateau] = plateau
    d[:spread] = spread
    d[:band] = band
    d[:warmup] = t_star
    return d
end

## ---- one long run, honestly -----------------------------------------------------

"""
    batch_means(x; batches = 10, level = 0.95) -> SymDict

Confidence interval of the mean of a single long run: the series is split into
`batches` consecutive blocks, the block means are treated as independent
observations, and the Student-t interval of those is reported together with the
lag-1 autocorrelation of the series -- the reason a plain interval would be wrong.
"""
function batch_means(x::AbstractVector{<:Real}; batches::Integer = 10, level::Real = 0.95)
    v = Float64.(x)
    n = length(v)
    d = SymDict()
    d[:n] = n
    d[:mean] = n == 0 ? NaN : sum(v) / n
    if n < 4
        d[:batches] = 0
        d[:half_width] = NaN
        d[:adequate] = false
        return d
    end
    k = clamp(Int(batches), 2, max(2, div(n, 2)))
    m = div(n, k)
    bm = [sum(@view v[((i - 1) * m + 1):(i * m)]) / m for i in 1:k]
    ci = mean_ci(bm; level = level)
    d[:batches] = k
    d[:batch_length] = m
    d[:half_width] = ci[:half_width]
    d[:lo] = ci[:mean] - ci[:half_width]
    d[:hi] = ci[:mean] + ci[:half_width]
    d[:sd] = ci[:sd]
    d[:lag1] = autocorrelation(v, 1)
    d[:adequate] = k >= 5
    return d
end

"""Lag-`k` autocorrelation of a series (0 when it is undefined)."""
function autocorrelation(x::AbstractVector{<:Real}, k::Integer = 1)
    n = length(x)
    n <= k + 1 && return 0.0
    m = sum(x) / n
    num = 0.0
    den = 0.0
    for i in 1:n
        den += (x[i] - m)^2
        i + k <= n && (num += (x[i] - m) * (x[i + k] - m))
    end
    return den == 0 ? 0.0 : num / den
end

## ---- sweeps --------------------------------------------------------------------

"""Table of a sweep: one row per parameter value, with the metric means and widths."""
function sweep_matrix(values::AbstractVector, results::Vector{ExperimentResult}, metrics)
    rows = SymDict[]
    for (v, res) in zip(values, results)
        row = SymDict()
        row[:value] = v
        for m in metrics
            c = metric_ci(res, m)
            c === nothing && continue
            row[Symbol(m, :_mean)] = c[:mean]
            row[Symbol(m, :_half_width)] = c[:half_width]
        end
        push!(rows, row)
    end
    return rows
end

"""
    sweep(factory, param, values, cfg; objective, name, metrics) -> SymDict

Walk one parameter: `factory(value, opts)` builds the model for every value, the
same replication seeds are used for all values (common random numbers, so the
curves move only because the parameter moved), and the record reports the table,
the objective of each value, the direction in which the metric is good and the
best value.

```julia
sw = sweep((v, opts) -> build_model(:mmc, params, opts), :c, [1, 2, 3, 4],
           ExperimentConfig(replications = 10, horizon = 4000.0);
           objective = :wait_mean)
sw[:best_value]
```
"""
function sweep(factory::Base.Callable, param::Symbol, values::AbstractVector,
    cfg::ExperimentConfig = ExperimentConfig(); name::Symbol = Symbol(:sweep, :_, param),
    objective::Symbol = :throughput, scenario = nothing,
    metrics = (:throughput, :cycle_time_mean, :wait_mean, :utilisation, :completed))
    isempty(values) && throw(ArgumentError("a sweep needs at least one value"))
    results = ExperimentResult[]
    for (i, v) in enumerate(values)
        push!(results, experiment(opts -> factory(v, opts), cfg;
            name = Symbol(name, :_, i), kind = :sweep, scenario = scenario))
    end
    means = [metric_value(res, objective) for res in results]
    best_index = is_lower_better(objective) ? argmin(means) : argmax(means)
    d = SymDict()
    d[:param] = Sym(param)
    d[:values] = collect(values)
    d[:objective] = Sym(objective)
    d[:direction] = optimisation_direction(objective)
    d[:metrics] = collect(metrics)
    d[:results] = results
    d[:means] = means
    d[:rows] = sweep_matrix(collect(values), results, metrics)
    d[:best_index] = best_index
    d[:best_value] = values[best_index]
    d[:best] = results[best_index]
    d[:best_ci] = metric_ci(results[best_index], objective)
    return d
end

"""Rows of a sweep, with one column per metric (the body of the sweep table)."""
sweep_rows(sw::SymDict) = sw[:rows]

## ---- paired comparisons --------------------------------------------------------

"""
    paired_comparison(res, base, metric; label) -> SymDict

Compare one metric of two experiments *by replication pair*: because both designs
used the same seed in replication `k`, the per-replication differences are
meaningful, so the interval of their mean is far tighter than the intervals of the
two means. The record reports the difference, its interval, the verdict
(`:better`, `:worse`, `:indistinguishable`) and how much variance the common
random numbers removed.
"""
function paired_comparison(res::ExperimentResult, base::ExperimentResult, metric::Symbol;
    label = res.name)
    a = metric_series(res, metric)
    b = metric_series(base, metric)
    n = min(length(a), length(b))
    d = SymDict()
    d[:label] = Sym(label)
    d[:metric] = Sym(metric)
    d[:n] = n
    d[:direction] = optimisation_direction(metric)
    n < 2 && (d[:verdict] = :not_applicable; return d)
    diffs = a[1:n] .- b[1:n]
    ci = mean_ci(diffs)
    direction = is_lower_better(metric) ? -1 : 1
    verdict = ci[:lo] > 0 ? (direction > 0 ? :better : :worse) :
              ci[:hi] < 0 ? (direction > 0 ? :worse : :better) : :indistinguishable
    d[:baseline_mean] = metric_value(base, metric)
    d[:scenario_mean] = metric_value(res, metric)
    d[:difference] = ci[:mean]
    d[:half_width] = ci[:half_width]
    d[:lo] = ci[:lo]
    d[:hi] = ci[:hi]
    d[:relative_difference] = relative_change(metric_value(res, metric),
        metric_value(base, metric))
    d[:sd_paired] = ci[:sd]
    d[:sd_independent] = sqrt(var(a[1:n]) + var(b[1:n]))
    d[:variance_reduction] = iszero(d[:sd_independent]) ? 0.0 :
                             1 - (ci[:sd]^2 / d[:sd_independent]^2)
    d[:verdict] = verdict
    return d
end

"""
    compare_scenarios(scenarios, cfg; objective, metrics, name) -> SymDict

Run several designs of the same model with common random numbers and compare each
one against the first (the baseline). `scenarios` is a vector of
`name => builder` pairs, where the builder takes the run options.

```julia
cmp = compare_scenarios([:baseline => f1, :capacity_up => f2, :faster => f3], cfg;
                        objective = :cycle_time_mean)
```
"""
function compare_scenarios(scenarios::AbstractVector,
    cfg::ExperimentConfig = ExperimentConfig(); objective::Symbol = :throughput,
    name::Symbol = :comparison,
    metrics = (:throughput, :cycle_time_mean, :wait_mean, :utilisation, :completed))
    isempty(scenarios) && throw(ArgumentError("compare_scenarios needs at least one scenario"))
    results = SymDict()
    order = Symbol[]
    for s in scenarios
        results[Sym(s.first)] = experiment(s.second, cfg; name = Sym(s.first), kind = :paired)
        push!(order, Sym(s.first))
    end
    baseline = results[order[1]]
    comparisons = SymDict[]
    for nm in order[2:end]
        for m in metrics
            (metric_ci(results[nm], m) === nothing || metric_ci(baseline, m) === nothing) &&
                continue
            push!(comparisons, paired_comparison(results[nm], baseline, m; label = nm))
        end
    end
    verdicts = SymDict()
    for c in comparisons
        row = get!(verdicts, c[:label], SymDict())
        row[c[:metric]] = c[:verdict]
    end
    d = SymDict()
    d[:name] = Sym(name)
    d[:objective] = Sym(objective)
    d[:order] = order
    d[:baseline] = order[1]
    d[:results] = results
    d[:comparisons] = comparisons
    d[:verdicts] = verdicts
    d[:best] = sort(order; by = nm -> is_lower_better(objective) ?
        -metric_value(results[nm], objective) : metric_value(results[nm], objective))[end]
    return d
end

## ---- factorial designs ---------------------------------------------------------

"""
    effect_row(term, diffs, objective) -> SymDict

One row of a factorial analysis: the average effect of a term, its interval and a
verdict relative to the objective (`:helps`, `:hurts`, `:negligible`).
"""
function effect_row(term::Symbol, diffs::Vector{Float64}, objective::Symbol)
    ci = mean_ci(diffs)
    direction = is_lower_better(objective) ? -1 : 1
    verdict = ci[:lo] > 0 ? (direction > 0 ? :helps : :hurts) :
              ci[:hi] < 0 ? (direction > 0 ? :hurts : :helps) : :negligible
    return SymDict(:term => Sym(term), :metric => Sym(objective), :effect => ci[:mean],
        :half_width => ci[:half_width], :lo => ci[:lo], :hi => ci[:hi], :n => ci[:n],
        :verdict => verdict)
end

"""
    factorial_design(factory, factors, levels, cfg; objective, name) -> SymDict

Two-level factorial design: every corner of the `2^k` design is run with the same
replication seeds, so the main effect of each factor and every two-factor
interaction can be estimated *by replication pair*, which is the sharpest way to
answer "which of these knobs actually matters?".

`factory(levelmap, opts)` builds the model for a corner, with `levelmap` a
symbol-keyed record of the factor settings.
"""
function factorial_design(factory::Base.Callable, factors::Vector{Symbol},
    levels::AbstractDict, cfg::ExperimentConfig = ExperimentConfig();
    objective::Symbol = :throughput, name::Symbol = :factorial)
    k = length(factors)
    k >= 1 || throw(ArgumentError("a factorial design needs at least one factor"))
    for f in factors
        haskey(levels, f) || throw(ArgumentError("no levels given for factor :$f"))
    end
    corners = collect(0:(2^k - 1))
    curves = Dict{Int,Vector{Float64}}()
    results = SymDict()
    corner_labels = SymDict()
    for c in corners
        levelmap = SymDict()
        for (i, f) in enumerate(factors)
            bit = (c >> (i - 1)) & 1
            levelmap[f] = bit == 1 ? levels[f][2] : levels[f][1]
        end
        res = experiment(opts -> factory(levelmap, opts), cfg;
            name = Symbol(name, :_, c), kind = :factorial)
        curves[c] = metric_series(res, objective)
        results[Symbol(:corner, :_, c)] = res
        corner_labels[c] = levelmap
    end
    n = minimum(length(v) for v in values(curves))
    rows = SymDict[]
    for (i, f) in enumerate(factors)
        diffs = zeros(n)
        for c in corners
            sign = ((c >> (i - 1)) & 1) == 1 ? 1.0 : -1.0
            diffs .+= sign .* curves[c][1:n]
        end
        push!(rows, effect_row(f, diffs ./ 2^(k - 1), objective))
    end
    for i in 1:k, j in (i + 1):k
        diffs = zeros(n)
        for c in corners
            sign = (((c >> (i - 1)) & 1) == 1 ? 1.0 : -1.0) *
                   (((c >> (j - 1)) & 1) == 1 ? 1.0 : -1.0)
            diffs .+= sign .* curves[c][1:n]
        end
        term = Symbol(factors[i], :x, factors[j])
        push!(rows, effect_row(term, diffs ./ 2^(k - 1), objective))
    end
    d = SymDict()
    d[:factors] = factors
    d[:levels] = levels
    d[:objective] = Sym(objective)
    d[:corners] = corner_labels
    d[:results] = results
    d[:effects] = rows
    d[:n] = n
    return d
end

"""Rows of a factorial analysis: one per term, with effect and interval."""
factorial_rows(fd::SymDict) = fd[:effects]