# =============================================================================
# stats.jl -- the statistics collectors.
#
# A discrete-event model produces numbers of four different kinds, and mixing
# them up is the classic way to report nonsense: observations that are not
# weighted by time (waiting times -- a `Tally`), quantities that are only
# piecewise constant (queue lengths, work in progress, inventory -- a
# `TimeWeighted`), counts of categorical outcomes (completed, scrapped -- a
# `Counter`) and distributions (a `Histogram`, with a `Recorder` for the shape
# over time). Each collector knows its own mean, its confidence interval and
# whether it is an *adequate* statistic -- the time-weighted ones are, plain
# tallies of queue length are not.
#
# Every statistic of a simulation is registered under a `Symbol` in `σ.stats`,
# so `σ[:wait]` is the waiting-time tally and the report can format it without
# knowing the model.
# =============================================================================

## ---- Tally ---------------------------------------------------------------------

"""
    Tally(metric; unit = metric_unit(metric), keep = 0)

A tally of independent observations. `keep > 0` also keeps the last `keep`
observations, which is what makes quantiles and outliers available.
"""
Tally(metric::Symbol; unit = nothing, keep::Integer = 0) =
    Tally(Sym(metric), unit === nothing ? metric_unit(metric) : Sym(unit), 0, 0.0, 0.0,
        Inf, -Inf, Float64[], Int(keep), 0.0)

"""Record one observation."""
function tally_record!(t::Tally, x::Real)
    x = Float64(x)
    t.count += 1
    t.total += x
    t.sumsq += x * x
    x < t.lowest && (t.lowest = x)
    x > t.highest && (t.highest = x)
    if t.keep > 0
        length(t.history) >= t.keep && popfirst!(t.history)
        push!(t.history, x)
    end
    return t
end

"""Number of observations."""
n_of(t::Tally) = t.count

"""Mean of a tally (`NaN` when nothing was recorded)."""
mean(t::Tally) = t.count == 0 ? NaN : t.total / t.count

"""Unbiased variance of a tally (`NaN` for fewer than two observations)."""
function var(t::Tally)
    t.count < 2 && return NaN
    return max((t.sumsq - t.count * mean(t)^2) / (t.count - 1), 0.0)
end

"""Standard deviation of a tally."""
std(t::Tally) = sqrt(var(t))

"""Standard error of the mean of a tally (`NaN` when it cannot be estimated)."""
standard_error(t::Tally) = t.count < 2 ? NaN : std(t) / sqrt(t.count)

"""Smallest and largest observation."""
extrema_of(t::Tally) = (t.lowest, t.highest)

"""Quantile of the kept observations (`NaN` when the tally keeps no history)."""
function quantile(t::Tally, p::Real)
    isempty(t.history) && return NaN
    return quantile(t.history, p)
end

"""Confidence half-width of the mean (Student-t, `level = 0.95` by default)."""
function half_width(t::Tally; level::Real = 0.95)
    t.count < 2 && return NaN
    q = quantile(TDist(t.count - 1), 1 - (1 - level) / 2)
    return q * standard_error(t)
end

"""Fences of the usual 1.5 IQR outlier rule (`NaN`s without a history)."""
function outlier_fence(t::Tally)
    isempty(t.history) && return (NaN, NaN)
    q1, q3 = quantile(t.history, 0.25), quantile(t.history, 0.75)
    return (q1 - 1.5 * (q3 - q1), q3 + 1.5 * (q3 - q1))
end

"""The `SymDict` the report renders for a tally."""
function summary_of(t::Tally)
    d = SymDict()
    d[:kind] = :tally
    d[:metric] = t.metric
    d[:unit] = t.unit
    d[:n] = t.count
    d[:mean] = mean(t)
    d[:sd] = std(t)
    d[:se] = standard_error(t)
    d[:half_width] = half_width(t)
    d[:min] = t.count == 0 ? NaN : t.lowest
    d[:max] = t.count == 0 ? NaN : t.highest
    d[:adequate] = true
    isempty(t.history) || (d[:p50] = quantile(t.history, 0.5))
    isempty(t.history) || (d[:p95] = quantile(t.history, 0.95))
    return d
end

## ---- TimeWeighted --------------------------------------------------------------

"""
    TimeWeighted(metric; unit = metric_unit(metric), initial = 0.0)

A time-weighted statistic. `observe!(tw, value, duration)` adds `value` for
`duration` time units; `update!(tw, σ, value)` does the same using the clock of a
simulation.

```julia
update!(σ[:queue_length], σ, length(σ[:line].queue))
```
"""
TimeWeighted(metric::Symbol; unit = nothing, initial::Real = 0.0) =
    TimeWeighted(Sym(metric), unit === nothing ? metric_unit(metric) : Sym(unit), 0.0, 0.0,
        0.0, Float64(initial), Float64(initial), Float64(initial), 0, 0.0, 0.0,
        Dict{Float64,Float64}())

"""Add `value` for `duration` time units to a time-weighted statistic.

The convention is "this value held for this long": `observe!(tw, 0.0, 10.0)`
followed by `observe!(tw, 4.0, 10.0)` leaves a mean of 2. Models use
[`update!`](@ref), which attributes the elapsed time to the *previous* value.
"""
function observe!(tw::TimeWeighted, value::Real, duration::Real)
    duration = Float64(duration)
    v = Float64(value)
    if duration > 0
        tw.area += v * duration
        tw.area_sq += v^2 * duration
        tw.duration += duration
        tw.last += duration
        tw.observations += 1
        for (threshold, area) in tw.above
            tw.above[threshold] = area + (v > threshold ? duration : 0.0)
        end
    end
    v < tw.lowest && (tw.lowest = v)
    v > tw.highest && (tw.highest = v)
    tw.value = v
    return tw
end

"""Shift a time-weighted statistic to a new value at the current time of `σ`:
the time since the last change is credited to the previous value."""
function update!(tw::TimeWeighted, σ::Sim, value::Real)
    dt = σ.now - tw.last
    previous = tw.value
    dt > 0 && observe!(tw, previous, dt)
    tw.value = Float64(value)
    v = Float64(value)
    v < tw.lowest && (tw.lowest = v)
    v > tw.highest && (tw.highest = v)
    return tw
end

"""Alias of [`update!`](@ref): shift a time-weighted statistic to a new value at
the current time of the simulation."""
observe!(tw::TimeWeighted, σ::Sim, value::Real) = update!(tw, σ, value)

"""Start tracking a threshold, so `fraction_above` can answer it later."""
function track_threshold!(tw::TimeWeighted, threshold::Real)
    haskey(tw.above, Float64(threshold)) || (tw.above[Float64(threshold)] = 0.0)
    return tw
end

"""Time-weighted mean of the quantity."""
mean(tw::TimeWeighted) = tw.duration == 0 ? tw.value : tw.area / tw.duration

"""Time-weighted standard deviation of a piecewise constant quantity."""
function std(tw::TimeWeighted)
    tw.duration == 0 && return 0.0
    m = mean(tw)
    return sqrt(max(tw.area_sq / tw.duration - m^2, 0.0))
end

"""Fraction of the elapsed time the quantity spent above `threshold`."""
fraction_above(tw::TimeWeighted, threshold::Real) =
    haskey(tw.above, Float64(threshold)) && tw.duration > 0 ?
    tw.above[Float64(threshold)] / tw.duration : NaN

"""Time the quantity spent above `threshold`. Call `track_threshold!` first."""
time_above(tw::TimeWeighted, threshold::Real) =
    haskey(tw.above, Float64(threshold)) ? tw.above[Float64(threshold)] : NaN

"""Value the statistic had when the run ended."""
value_of(tw::TimeWeighted) = tw.value

"""The `SymDict` the report renders for a time-weighted statistic."""
function summary_of(tw::TimeWeighted)
    d = SymDict()
    d[:kind] = :time_weighted
    d[:metric] = tw.metric
    d[:unit] = tw.unit
    d[:mean] = mean(tw)
    d[:sd] = std(tw)
    d[:half_width] = NaN
    d[:min] = tw.lowest
    d[:max] = tw.highest
    d[:last] = tw.value
    d[:duration] = tw.duration
    d[:adequate] = true
    return d
end

## ---- Counter -------------------------------------------------------------------

"""
    Counter(metric; unit = :count)

Counts of categorical outcomes; the first key touched is the total by convention
(`count!(c, :total)` happens automatically when a `Counter` is written through
`count!(σ, ...)`).
"""
Counter(metric::Symbol; unit = :count) =
    Counter(Sym(metric), Sym(unit), Dict{Symbol,Int}(), Symbol[])

"""Index a counter by category: `c[:served]` is `count_of(c, :served)`."""
Base.getindex(c::Counter, key::Symbol) = count_of(c, key)

"""Increment the count of a category."""
function Base.count!(c::Counter, key::Symbol = :total, n::Integer = 1)
    k = Sym(key)
    haskey(c.counts, k) || push!(c.order, k)
    c.counts[k] = get(c.counts, k, 0) + Int(n)
    return c
end

"""Count of one category."""
count_of(c::Counter, key::Symbol = :total) = get(c.counts, Sym(key), 0)

"""Total number of counted events (the sum over the categories)."""
total_of(c::Counter) = sum(values(c.counts); init = 0)

"""Share of each category of the total."""
function fractions(c::Counter)
    total = total_of(c)
    d = SymDict()
    for k in c.order
        d[k] = total == 0 ? 0.0 : c.counts[k] / total
    end
    return d
end

"""Category with the largest count (`:none` when nothing was counted)."""
function most_common(c::Counter)
    isempty(c.order) && return :none
    return c.order[argmax([c.counts[k] for k in c.order])]
end

"""The `SymDict` the report renders for a counter."""
function summary_of(c::Counter)
    d = SymDict()
    d[:kind] = :counter
    d[:metric] = c.metric
    d[:unit] = c.unit
    d[:total] = total_of(c)
    d[:adequate] = true
    for k in c.order
        d[k] = c.counts[k]
    end
    return d
end

## ---- Histogram -----------------------------------------------------------------

"""
    Histogram(metric, edges; unit = :count)
    Histogram(metric, lo, hi, bins)

Fixed-bin distribution with underflow and overflow buckets, so a report can show
a shape and a P95 without keeping every sample.
"""
function Histogram(metric::Symbol, edges::AbstractVector{<:Real}; unit = :count)
    e = sort(Float64.(collect(edges)))
    length(e) >= 2 || throw(ArgumentError("a histogram needs at least two bin edges"))
    return Histogram(Sym(metric), Sym(unit), e, zeros(Int, length(e) - 1), 0, 0)
end

Histogram(metric::Symbol, lo::Real, hi::Real, bins::Integer = 10; kwargs...) =
    (bins >= 1 || throw(ArgumentError("a histogram needs at least one bin")),
     Histogram(metric, collect(range(Float64(lo), Float64(hi); length = Int(bins) + 1));
         kwargs...))

"""Bin a value: the index of the bin, `0` for underflow, `length(counts)+1` for overflow."""
function bin_index(h::Histogram, x::Real)
    x < h.edges[1] && return 0
    x >= h.edges[end] && return length(h.counts) + 1
    return searchsortedlast(h.edges, x)
end

"""Record one observation."""
function hist_record!(h::Histogram, x::Real)
    i = bin_index(h, x)
    i == 0 ? (h.underflow += 1) :
    i == length(h.counts) + 1 ? (h.overflow += 1) : (h.counts[i] += 1)
    return h
end

"""Number of observations in the histogram."""
n_of(h::Histogram) = sum(h.counts) + h.underflow + h.overflow

"""Midpoint of every bin."""
bin_centres(h::Histogram) = (h.edges[1:(end - 1)] .+ h.edges[2:end]) ./ 2

"""Empirical distribution function of the histogram (stepwise)."""
function cdf(h::Histogram, x::Real)
    n = n_of(h)
    n == 0 && return NaN
    x < h.edges[1] && return h.underflow / n
    x >= h.edges[end] && return 1.0
    i = searchsortedlast(h.edges, x)
    below = h.underflow + sum(h.counts[1:(i - 1)]; init = 0)
    width = h.edges[i + 1] - h.edges[i]
    inside = width == 0 ? 0.0 : h.counts[i] * (x - h.edges[i]) / width
    return (below + inside) / n
end

"""Quantile of the histogram (linear interpolation inside the bin)."""
function quantile(h::Histogram, p::Real)
    n = n_of(h)
    n == 0 && return NaN
    target = p * n
    running = Float64(h.underflow)
    running >= target && return h.edges[1]
    for i in eachindex(h.counts)
        running + h.counts[i] >= target && begin
            width = h.edges[i + 1] - h.edges[i]
            within = h.counts[i] == 0 ? 0.0 : (target - running) / h.counts[i]
            return h.edges[i] + within * width
        end
        running += h.counts[i]
    end
    return h.edges[end]
end

"""Histogram of every bin, normalised to integrate to one."""
function histogram_density(h::Histogram)
    n = n_of(h)
    n == 0 && return zeros(length(h.counts))
    widths = h.edges[2:end] .- h.edges[1:(end - 1)]
    return h.counts ./ (n .* widths)
end

"""The `SymDict` the report renders for a histogram."""
function summary_of(h::Histogram)
    d = SymDict()
    d[:kind] = :histogram
    d[:metric] = h.metric
    d[:unit] = h.unit
    d[:n] = n_of(h)
    d[:mean] = n_of(h) == 0 ? NaN : sum(bin_centres(h) .* h.counts) / max(sum(h.counts), 1)
    d[:p50] = quantile(h, 0.5)
    d[:p95] = quantile(h, 0.95)
    d[:p99] = quantile(h, 0.99)
    d[:min] = h.edges[1]
    d[:max] = h.edges[end]
    d[:underflow] = h.underflow
    d[:overflow] = h.overflow
    d[:adequate] = true
    return d
end

## ---- Recorder ------------------------------------------------------------------

"""
    Recorder(metric; unit = :count, limit = 20_000)

A time series, decimated on the fly: once `limit` points are held, every second
change is dropped, keeping the shape of the curve printable without keeping a
number per event.
"""
Recorder(metric::Symbol; unit = :count, limit::Integer = 20_000) =
    Recorder(Sym(metric), Sym(unit), Float64[], Float64[], Int(limit), 1, 0, 0.0)

"""Record a value at time `t`."""
function recorder_record!(r::Recorder, t::Real, value::Real)
    r.added += 1
    r.last = Float64(value)
    if length(r.times) >= r.limit
        r.decimation *= 2
        keep = 1:2:length(r.times)
        r.times = r.times[keep]
        r.values = r.values[keep]
    end
    r.added % r.decimation == 0 || return r
    push!(r.times, Float64(t))
    push!(r.values, Float64(value))
    return r
end

"""Record a value at the current time of `σ`."""
record_at!(r::Recorder, σ::Sim, value::Real) = recorder_record!(r, σ.now, value)

"""Number of points actually held."""
n_of(r::Recorder) = length(r.times)

"""Mean of the recorded series (plain sample mean, for the shape only)."""
mean(r::Recorder) = isempty(r.values) ? NaN : sum(r.values) / length(r.values)

"""Largest recorded value."""
peak(r::Recorder) = isempty(r.values) ? NaN : maximum(r.values)

"""Mean of the last `fraction` of the series: a cheap steady-state estimate."""
function tail_mean(r::Recorder; fraction::Real = 0.5)
    n = length(r.values)
    n == 0 && return NaN
    first_i = max(1, floor(Int, n * (1 - fraction)))
    return sum(@view r.values[first_i:end]) / length(r.values[first_i:end])
end

"""Moving average of the series with window `w` (used by the warmup analysis)."""
function moving_average(r::Recorder; window::Integer = 20)
    n = length(r.values)
    n == 0 && return (Float64[], Float64[])
    w = min(Int(window), n)
    out_t = Float64[]
    out_v = Float64[]
    running = 0.0
    for i in 1:n
        running += r.values[i]
        i > w && (running -= r.values[i - w])
        if i >= w
            push!(out_t, sum(@view r.times[(i - w + 1):i]) / w)
            push!(out_v, running / w)
        end
    end
    return (out_t, out_v)
end

"""The `SymDict` the report renders for a recorder."""
function summary_of(r::Recorder)
    d = SymDict()
    d[:kind] = :recorder
    d[:metric] = r.metric
    d[:unit] = r.unit
    d[:n] = n_of(r)
    d[:mean] = mean(r)
    d[:max] = peak(r)
    d[:last] = r.last
    d[:adequate] = true
    return d
end

## ---- the registry of a simulation ----------------------------------------------

"""
    statistic(σ, name; kind = :tally, unit = nothing) -> statistic

The statistic registered under `name`, created on first use with the requested
`kind` (`:tally`, `:time_weighted`, `:counter`, `:histogram`, `:recorder`).
"""
function statistic(σ::Sim, name; kind::Symbol = :tally, unit = nothing)
    k = Sym(name)
    haskey(σ.stats, k) && return σ.stats[k]
    st = kind === :time_weighted ? TimeWeighted(k; unit = unit) :
         kind === :counter ? Counter(k; unit = unit) :
         kind === :recorder ? Recorder(k; unit = unit) :
         kind === :histogram ? Histogram(k, 0.0, 1.0, 10) :
         Tally(k; unit = unit)
    σ.stats[k] = st
    return st
end

"""Record an observation in the tally named `name`."""
tally!(σ::Sim, name, x::Real) = tally_record!(statistic(σ, name; kind = :tally), x)

"""Update the time-weighted statistic named `name` with a new value."""
observe!(σ::Sim, name, value::Real) =
    update!(statistic(σ, name; kind = :time_weighted), σ, value)

"""Increment the counter named `name` (`:total` by default)."""
Base.count!(σ::Sim, name, key::Symbol = :total, n::Integer = 1) =
    count!(statistic(σ, name; kind = :counter), key, n)

"""Append the current time and a value to the recorder named `name`."""
record!(σ::Sim, name, value::Real) =
    recorder_record!(statistic(σ, name; kind = :recorder), σ.now, value)

"""Reset every statistic of a simulation (used by `warmup!`)."""
function reset_statistics!(σ::Sim)
    for (_, st) in σ.stats
        reset_statistic!(st, σ.now)
    end
    for (_, r) in σ.resources
        reset_resource_statistics!(r, σ.now)
    end
    return σ
end

function reset_statistic!(t::Tally, t0::Real)
    t.count = 0
    t.total = 0.0
    t.sumsq = 0.0
    t.lowest = Inf
    t.highest = -Inf
    empty!(t.history)
    t.since = t0
    return t
end

function reset_statistic!(tw::TimeWeighted, t0::Real)
    tw.area = 0.0
    tw.area_sq = 0.0
    tw.duration = 0.0
    tw.observations = 0
    tw.last = t0
    tw.since = t0
    for k in collect(keys(tw.above))
        tw.above[k] = 0.0
    end
    return tw
end

reset_statistic!(c::Counter, t0::Real) = (empty!(c.counts); empty!(c.order); c)
reset_statistic!(h::Histogram, t0::Real) =
    (fill!(h.counts, 0); h.underflow = 0; h.overflow = 0; h)
reset_statistic!(r::Recorder, t0::Real) =
    (empty!(r.times); empty!(r.values); r.decimation = 1; r.added = 0; r)

"""`summary` of whatever kind of statistic a name refers to."""
summary_of(σ::Sim, name) = summary_of(statistic(σ, name))

"""Number of statistics registered by a run."""
n_statistics(σ::Sim) = length(σ.stats)

"""Every statistic of a run as one table (the body of the report's metric table)."""
function statistics_table(σ::Sim)
    rows = SymDict[]
    for (name, st) in σ.stats
        row = summary_of(st)
        row[:name] = name
        push!(rows, row)
    end
    return rows
end

## ---- confidence intervals of a set of replications -----------------------------

"""
    mean_ci(x; level = 0.95) -> SymDict

Mean of a set of independent replications with the Student-t confidence interval
the experiment report prints: `:n`, `:mean`, `:sd`, `:se`, `:half_width`, `:lo`,
`:hi`, `:relative_half_width` and `:adequate` (`false` for fewer than two runs).
"""
function mean_ci(x::AbstractVector{<:Real}; level::Real = 0.95)
    d = SymDict()
    n = length(x)
    d[:n] = n
    m = n == 0 ? NaN : sum(x) / n
    d[:mean] = m
    if n < 2
        d[:sd] = NaN
        d[:se] = NaN
        d[:half_width] = NaN
        d[:lo] = m
        d[:hi] = m
        d[:relative_half_width] = NaN
        d[:adequate] = false
        return d
    end
    sd = sqrt(sum((y - m)^2 for y in x) / (n - 1))
    hw = quantile(TDist(n - 1), 1 - (1 - level) / 2) * sd / sqrt(n)
    d[:sd] = sd
    d[:se] = sd / sqrt(n)
    d[:half_width] = hw
    d[:lo] = m - hw
    d[:hi] = m + hw
    d[:relative_half_width] = m == 0 ? NaN : hw / abs(m)
    d[:adequate] = true
    return d
end

"""Sample size needed for a relative precision of `ρ` with the observed spread."""
function required_replications(x::AbstractVector{<:Real}; relative_precision::Real = 0.05,
    level::Real = 0.95)
    d = mean_ci(x; level = level)
    (d[:adequate] && isfinite(d[:sd]) && d[:mean] != 0) || return 0
    z = quantile(Normal(), 1 - (1 - level) / 2)
    target = relative_precision * abs(d[:mean])
    return ceil(Int, (z * d[:sd] / target)^2)
end

"""Cumulative mean of a series (the classic convergence plot of a replication study)."""
function cumulative_mean(x::AbstractVector{<:Real})
    out = Float64[]
    running = 0.0
    for (i, v) in enumerate(x)
        running += v
        push!(out, running / i)
    end
    return out
end