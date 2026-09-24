# =============================================================================
# online.jl -- offline first, online when it is there.
#
# The rule of this package is simple: **everything works with no network at all**,
# and the online source only ever *improves* a picture that already exists. So the
# data layer is a chain of fallbacks with a memory:
#
#     online HTTP  ->  a local copy of the same feed  ->  the last cached reply  ->  offline
#
# Every step is timestamped, every step reports which one answered
# (`:online`, `:offline_cache`, `:cached`, `:offline`) and how old the answer is
# (`:fresh`, `:stale`, `:expired`), and nothing ever throws because the network is
# down -- a pipeline that fails because a feed is unreachable is a pipeline nobody
# dares to schedule.
#
# On top of that sits `reevaluate`: it recalibrates the model from the freshest
# observations it can reach, compares them with the model in use (relative change
# of each parameter and a Kolmogorov--Smirnov test between the two samples) and
# records a verdict -- `:recalibrate`, `:keep` or `:escalate` -- in an append-only
# log, which is what makes a *periodic* reevaluation auditable.
# =============================================================================

"""Where the periodic feed lives when the repository is published."""
const DEFAULT_ONLINE_URL =
    "https://raw.githubusercontent.com/caxelrud/Julia_Discrete_Sim_2026/main/data/online_feed.json"

"""
    OnlineConfig

Everything the data layer needs: where the feed is (`url`), what to use instead
when there is no network (`local_file`), how long to wait (`timeout`), how many
times to retry, where the reply is cached (`cache_dir`), how long a cached reply
stays acceptable (`ttl_days`) and which policy to follow (`:offline_first`,
`:online_first`, `:cache_only`).
"""
Base.@kwdef mutable struct OnlineConfig
    enabled::Bool = true
    url::String = DEFAULT_ONLINE_URL
    local_file::String = joinpath("data", "online_feed.json")
    timeout::Float64 = 4.0
    retries::Int = 1
    cache_dir::String = joinpath("data", "online")
    ttl_days::Float64 = 7.0
    policy::Symbol = :offline_first
    user_agent::String = "DiscreteSim.jl"
end

OnlineConfig(d::AbstractDict) = begin
    known = Set{Symbol}(fieldnames(OnlineConfig))
    OnlineConfig(; (Sym(k) => v for (k, v) in d if Sym(k) in known)...)
end

"""Path of the cached reply of a source."""
cache_path(cfg::OnlineConfig, name::AbstractString = "feed.json") = joinpath(cfg.cache_dir, name)

"""Read a JSON payload from a local path (`nothing` when it is not there)."""
function read_json_file(path::AbstractString)
    isfile(path) || return nothing
    return try
        JSON3.read(read(path, String))
    catch
        nothing
    end
end

"""Write a JSON payload, creating the directory if needed."""
function write_json_file(path::AbstractString, payload)
    mkpath(dirname(path))
    open(path, "w") do io
        JSON3.pretty(io, payload)
    end
    return path
end

"""Seconds between two ISO timestamps (`NaN` when they cannot be parsed)."""
function seconds_between(a::AbstractString, b::AbstractString)
    ta = try
        DateTime(a)
    catch
        return NaN
    end
    tb = try
        DateTime(b)
    catch
        return NaN
    end
    return Float64(Dates.value(tb - ta)) / 1000
end

"""Read the cached reply of a source (`nothing` when there is no usable cache)."""
function read_cache(cfg::OnlineConfig, name::AbstractString = "feed.json")
    rec = read_json_file(cache_path(cfg, name))
    rec === nothing && return nothing
    d = SymDict()
    d[:payload] = get(rec, :payload, nothing)
    d[:fetched_at] = String(get(rec, :fetched_at, ""))
    d[:url] = String(get(rec, :url, cfg.url))
    return d
end

"""Store a reply in the cache, stamped with the time it was fetched."""
function write_cache(cfg::OnlineConfig, payload, fetched_at::AbstractString,
    name::AbstractString = "feed.json")
    return write_json_file(cache_path(cfg, name),
        SymDict(:fetched_at => String(fetched_at), :url => cfg.url, :payload => payload))
end

"""How old a reply is, as a freshness symbol, given the time-to-live of the config."""
function freshness_of(age_days::Real, cfg::OnlineConfig)
    isnan(age_days) && return :unknown
    age_days <= cfg.ttl_days && return :fresh
    age_days <= 3 * cfg.ttl_days && return :stale
    return :expired
end

"""Timestamps as the data layer writes them (sortable, time-zone free)."""
timestamp(t::DateTime = Dates.now()) = Dates.format(t, dateformat"yyyy-mm-dd\THH:MM:SS")

"""The local copy of the feed, read as a payload (`nothing` when it is absent)."""
read_local_feed(cfg::OnlineConfig) = read_json_file(cfg.local_file)

"""`true` when the URL is really a file path (`file://` or a relative path)."""
is_local_source(url::AbstractString) =
    startswith(url, "file://") || (!startswith(url, "http://") && !startswith(url, "https://"))

"""Path of a `file://` or plain-path URL (`file:///C:/...` works on Windows)."""
function source_path(url::AbstractString)
    u = replace(String(url), "file://" => "")
    u = replace(u, '/' => Base.Filesystem.path_separator)
    if Sys.iswindows() && startswith(u, '\\') && length(u) > 2 && u[3] == ':'
        u = u[2:end]                     # drop the leading separator of file:///C:/
    end
    return u
end

## ---- reading the feed ----------------------------------------------------------

"""
    fetch_online(cfg; name = "feed.json", now = timestamp()) -> SymDict

Read the periodic feed, following the offline-first chain and *never* throwing.
The record says everything the report needs to judge the number:

* `:status` -- `:ok` (the online source answered), `:cached` (a local copy or the
  cache answered), `:offline` (nothing was reachable), `:empty` (the source
  answered but carried nothing), `:disabled`, `:timeout`, `:error`,
* `:source` -- `:online`, `:offline_cache` or `:generated`,
* `:fetched_at`, `:age_days` and `:freshness` -- how old the answer is,
* `:payload` and `:observations` -- what came back.

```julia
cfg = OnlineConfig(local_file = "data/online_feed.json", policy = :offline_first)
feed = fetch_online(cfg)
feed[:status]        # :ok, :cached or :offline
```
"""
function fetch_online(cfg::OnlineConfig; name::AbstractString = "feed.json",
    now::AbstractString = timestamp())
    d = SymDict()
    d[:url] = cfg.url
    d[:policy] = cfg.policy
    d[:attempts] = 0
    d[:now] = now
    if !cfg.enabled
        d[:status] = :disabled
        d[:source] = :generated
        d[:freshness] = :unknown
        d[:payload] = nothing
        return d
    end

    if cfg.policy === :cache_only
        cached = read_cache(cfg, name)
        cached === nothing && (cached = _local_reply(cfg))
        return _from_cache(d, cached, cfg, now)
    end

    online = _try_online(cfg, d)
    if online !== nothing
        payload = online
        write_cache(cfg, payload, now, name)
        d[:status] = :ok
        d[:source] = :online
        d[:fetched_at] = now
        d[:age_days] = 0.0
        d[:freshness] = :fresh
        d[:payload] = payload
        d[:observations] = parse_observations(payload)
        return d
    end

    local_reply = _local_reply(cfg)
    if local_reply !== nothing && cfg.policy === :offline_first
        d[:status] = :cached
        d[:source] = :offline_cache
        d[:freshness] = :unknown
        d[:payload] = local_reply[:payload]
        d[:fetched_at] = local_reply[:fetched_at]
        d[:observations] = parse_observations(local_reply[:payload])
        d[:fallback] = :local_file
        return d
    end
    return _from_cache(d, read_cache(cfg, name), cfg, now)
end

"""The local copy of the feed as a reply record (`nothing` when it is absent)."""
function _local_reply(cfg::OnlineConfig)
    payload = read_local_feed(cfg)
    payload === nothing && return nothing
    stamp = timestamp(Dates.unix2datetime(stat(cfg.local_file).mtime))
    return SymDict(:payload => payload, :fetched_at => stamp, :source => :offline_cache)
end

"""Finish a reply that came from the cache, computing its age and its freshness."""
function _from_cache(d::SymDict, cached, cfg::OnlineConfig, now::AbstractString)
    if cached === nothing
        d[:status] = :offline
        d[:source] = :generated
        d[:freshness] = :offline
        d[:payload] = nothing
        d[:observations] = nothing
        return d
    end
    age = seconds_between(String(get(cached, :fetched_at, "")), now) / 86_400
    d[:status] = :cached
    d[:source] = :offline_cache
    d[:fetched_at] = get(cached, :fetched_at, "")
    d[:age_days] = age
    d[:freshness] = freshness_of(age, cfg)
    d[:payload] = get(cached, :payload, nothing)
    d[:observations] = parse_observations(get(cached, :payload, nothing))
    return d
end

"""One attempt at the online source; returns the payload or `nothing` on failure."""
function _try_online(cfg::OnlineConfig, d::SymDict)
    attempts = 0
    for _ in 1:(1 + max(cfg.retries, 0))
        attempts += 1
        d[:attempts] = attempts
        if is_local_source(cfg.url)
            payload = read_json_file(source_path(cfg.url))
            if payload !== nothing
                return payload
            end
            d[:status] = :error
            d[:error] = "the file source is not there"
            continue
        end
        try
            response = HTTP.get(cfg.url; connect_timeout = cfg.timeout,
                read_timeout = cfg.timeout, headers = ["User-Agent" => cfg.user_agent])
            response.status == 200 || begin
                d[:status] = :error
                d[:error] = "HTTP $(response.status)"
                continue
            end
            return JSON3.read(String(response.body))
        catch err
            message = first(replace(sprint(showerror, err), "\n" => " "), 200)
            d[:status] = occursin("timeout", lowercase(message)) ? :timeout : :error
            d[:error] = message
        end
    end
    return nothing
end

"""
    parse_observations(payload) -> SymDict | nothing

Read the observation arrays out of a feed. A feed may carry anything (a version
stamp, the time of the last export, a whole data set); the keys this package
understands are `:interarrival`, `:service`, `:failure_interval`, `:repair` and
`:demand_size`, either at the top level or under `:observations`.
"""
function parse_observations(payload)
    payload === nothing && return nothing
    haskey(payload, :observations) && (payload = payload[:observations])
    payload === nothing && return nothing
    out = SymDict()
    for key in (:interarrival, :service, :failure_interval, :repair, :demand_size)
        haskey(payload, key) || continue
        values = Float64[]
        for v in payload[key]
            v isa Real && push!(values, Float64(v))
        end
        isempty(values) || (out[key] = values)
    end
    haskey(payload, :exported_at) && (out[:exported_at] = String(payload[:exported_at]))
    isempty(out) && return nothing
    return out
end

"""
    online_feed(h::PlantHistory; observations) -> SymDict

The payload of the periodic feed: the observation arrays of a history, ready to be
written to `data/online_feed.json` -- the file the online URL serves and the file
the offline fallback reads, so the two paths carry exactly the same content.
"""
function online_feed(h::PlantHistory; exported_at::AbstractString = timestamp(),
    window_days::Real = 30.0)
    observations = SymDict()
    for key in history_keys(h)
        x = history_series(h, key)
        isempty(x) && continue
        observations[key] = x[1:min(length(x), 4000)]
    end
    return SymDict(:exported_at => String(exported_at), :window_days => Float64(window_days),
        :source => :plant_export, :observations => observations)
end

"""Write the periodic feed of a history to a JSON file."""
function write_online_feed(h::PlantHistory, path::AbstractString; kwargs...)
    return write_json_file(path, online_feed(h; kwargs...))
end

"""A short human-readable description of a feed reply."""
function describe_feed(feed::AbstractDict)
    return string(code_string(get(feed, :source, :generated)), "/",
        code_string(get(feed, :status, :unknown)),
        get(feed, :freshness, :unknown) === :unknown ? "" :
        string(" (", code_string(feed[:freshness]), ")"),
        get(feed, :age_days, NaN) isa Real && isfinite(Float64(get(feed, :age_days, NaN))) ?
        string(", ", round(Float64(feed[:age_days]), digits = 2), " d old") : "")
end

## ---- JSON ----------------------------------------------------------------------

"""
    jsonable(x, depth = 0)

Deep conversion of any result of the package into plain JSON-ready data: symbols
become strings, dates become ISO strings, non-finite numbers become `nothing`,
structs become objects of their fields, and the objects that cannot be
serialised at all -- a `Sim`, a `Process`, a `Task`, a channel, a function --
become a short description of themselves. A depth limit stops any cycle (a
`Process` points back at its `Sim`) instead of overflowing the stack, which is
what a report about a running simulation needs.
"""
jsonable(x::Any) = jsonable(x, 0)

function jsonable(x, depth::Int)
    depth > 12 && return :truncated
    x isa Symbol && return String(x)
    x isa Union{Dates.Date,Dates.DateTime} && return string(x)
    x isa AbstractFloat && return isfinite(x) ? x : nothing
    x isa AbstractDict && return Dict{String,Any}(string(jsonable(k, depth + 1)) =>
        jsonable(v, depth + 1) for (k, v) in x)
    x isa NamedTuple && return Dict{String,Any}(string(k) => jsonable(v, depth + 1)
                                               for (k, v) in pairs(x))
    x isa AbstractVector && return Any[jsonable(v, depth + 1) for v in x]
    x isa Tuple && return Any[jsonable(v, depth + 1) for v in x]
    (x isa Real || x isa AbstractString || x isa Bool || x === nothing) && return x
    x isa Sim && return jsonable_sim(x, depth)
    x isa Process && return Dict{String,Any}("id" => x.id, "name" => string(x.name),
        "state" => string(x.state))
    x isa ExperimentResult && return jsonable(result_json(x), depth + 1)
    x isa AbstractRNG && return :rng
    (x isa Task || x isa Channel || x isa Function || x isa Module) && return :runtime_object
    if isstructtype(typeof(x))
        return Dict{String,Any}(string(f) => jsonable(getfield(x, f), depth + 1)
                                for f in fieldnames(typeof(x)))
    end
    return string(x)
end

"""A `Sim` as JSON: what it did, not the objects it did it with."""
function jsonable_sim(σ::Sim, depth::Int)
    return Dict{String,Any}("name" => string(σ.name), "now" => σ.now,
        "time_unit" => string(σ.config.time_unit), "seed" => σ.config.seed,
        "events" => σ.processed, "processes" => length(σ.processes),
        "stop_reason" => string(σ.stop_reason),
        "resources" => Any[string(k) for k in keys(σ.resources)],
        "statistics" => Any[string(k) for k in keys(σ.stats)])
end

"""Write a symbol-keyed payload to JSON, with the symbol vocabulary preserved."""
function write_json_payload(path::AbstractString, payload)
    mkpath(dirname(path))
    open(path, "w") do io
        JSON3.pretty(io, jsonable(payload))
    end
    return path
end

## ---- the periodic reevaluation -------------------------------------------------

"""
    ReevaluationPlan(every = 7, unit = :days)

How often the sources should be revisited: `ReevaluationPlan(7, :days)`,
`ReevaluationPlan(1, :weeks)`, `ReevaluationPlan(1, :months)`. `due` answers
whether a plan has come round again for the age of the last evaluation.
"""
Base.@kwdef struct ReevaluationPlan
    every::Int = 7
    unit::Symbol = :days
end

"""Build a plan from a symbol-keyed record (`SymDict(:every => 1, :unit => :weeks)`)."""
function ReevaluationPlan(d::AbstractDict)
    known = Set{Symbol}(fieldnames(ReevaluationPlan))
    return ReevaluationPlan(; (Sym(k) => v for (k, v) in d if Sym(k) in known)...)
end

"""Length of a plan in days (every unit is expressed in days)."""
plan_days(plan::ReevaluationPlan) =
    plan.unit === :weeks ? 7 * plan.every :
    plan.unit === :months ? 30 * plan.every :
    plan.unit === :years ? 365 * plan.every : plan.every

"""One-line description of a plan."""
describe_plan(plan::ReevaluationPlan) =
    string("every ", plan.every, " ", code_string(plan.unit))

"""`true` when the last evaluation is older than the plan says it may be."""
function due(plan::ReevaluationPlan, last::AbstractString, now::AbstractString = timestamp())
    age = seconds_between(String(last), String(now)) / 86_400
    isnan(age) && return true
    return age >= plan_days(plan)
end

"""Calibrate a set of observations that did not come from the local generator."""
function calibrate_observations(observations::AbstractDict; source::Symbol = :online)
    series = SymDict()
    for (k, v) in observations
        v isa AbstractVector && (series[Sym(k)] = Float64.(v))
    end
    h = PlantHistory(Sym(source), 0, NaN, :minutes, series, SymDict(),
        SymDict(:source => Sym(source)))
    cal = calibrate(h)
    cal[:source] = Sym(source)
    return cal
end

"""
    two_sample_ks(x, y) -> (; stat, p, n1, n2)

Two-sample Kolmogorov--Smirnov test: the largest gap between the two empirical
distributions, with the same asymptotic p-value `ks_test` uses. It answers the
question the reevaluation asks -- *are these two samples the same process?*
"""
function two_sample_ks(x::AbstractVector{<:Real}, y::AbstractVector{<:Real})
    a, b = sort(Float64.(x)), sort(Float64.(y))
    n1, n2 = length(a), length(b)
    (n1 == 0 || n2 == 0) && return (stat = NaN, p = NaN, n1 = n1, n2 = n2)
    d = 0.0
    i = j = 0
    while i < n1 || j < n2
        if j >= n2 || (i < n1 && a[i + 1] <= b[j + 1])
            i += 1
            value = a[i]
        else
            j += 1
            value = b[j]
        end
        while i < n1 && a[i + 1] <= value
            i += 1
        end
        while j < n2 && b[j + 1] <= value
            j += 1
        end
        d = max(d, abs(i / n1 - j / n2))
    end
    ne = n1 * n2 / (n1 + n2)
    λ = (sqrt(ne) + 0.12 + 0.11 / sqrt(ne)) * d
    return (stat = d, p = kolmogorov_q(λ), n1 = n1, n2 = n2)
end

"""
    reevaluate(cal; history, cfg, model, threshold, plan, log_path, now) -> SymDict

One round of the periodic reevaluation:

1. read the freshest observations available (online, local copy, cache or none),
2. calibrate them exactly like the offline history,
3. compare the two calibrations parameter by parameter (relative change) and
   sample by sample (two-sample Kolmogorov--Smirnov, using the `history`),
4. decide: `:recalibrate` when a parameter moved by more than `threshold` or the
   samples differ significantly, `:keep` when they do not, `:escalate` when the
   source has gone stale beyond three times its time-to-live,
5. append the decision to the log (`data/reevaluation_log.json` by default), and
   hand back the record -- `:feed`, `:parameters`, `:comparisons`, `:ks`,
   `:verdict` and `:reason`.

```julia
rec = reevaluate(cal; history = h, model = :mmc, plan = ReevaluationPlan(7, :days))
rec[:verdict]        # :keep or :recalibrate
```
"""
function reevaluate(cal::AbstractDict; history = nothing, cfg::OnlineConfig = OnlineConfig(),
    model::Symbol = :mmc, threshold::Real = 0.10,
    plan::ReevaluationPlan = ReevaluationPlan(),
    log_path::Union{Nothing,AbstractString} = joinpath("data", "reevaluation_log.json"),
    now::AbstractString = timestamp(), append_log::Bool = true)
    feed = fetch_online(cfg; now = now)
    observations = get(feed, :observations, nothing)
    online_cal = observations === nothing ? nothing :
                 calibrate_observations(observations; source = :online)
    offline = get(cal, :parameters, SymDict())
    online = online_cal === nothing ? SymDict() : online_cal[:parameters]

    comparisons = SymDict[]
    worst = 0.0
    for key in (:arrival_rate, :service_rate, :mtbf, :mttr, :demand_mean)
        (haskey(offline, key) && haskey(online, key)) || continue
        rel = relative_change(online[key], offline[key])
        push!(comparisons, SymDict(:parameter => key, :offline => offline[key],
            :online => online[key], :relative_change => rel,
            :beyond_threshold => abs(rel) > threshold))
        worst = max(worst, abs(rel))
    end

    ks = SymDict()
    if observations !== nothing && history !== nothing
        for key in (:interarrival, :service, :failure_interval, :repair, :demand_size)
            haskey(observations, key) || continue
            offline_values = history_series(history, key)
            online_values = Float64[Float64(v) for v in observations[key] if v isa Real]
            (isempty(offline_values) || isempty(online_values)) && continue
            test = two_sample_ks(offline_values, online_values)
            ks[key] = SymDict(:stat => test.stat, :p => test.p, :n_offline => test.n1,
                :n_online => test.n2, :same_process => test.p > 0.05)
        end
    end

    verdict, reason = _reevaluation_verdict(feed, comparisons, ks, worst, threshold)
    record = SymDict()
    record[:at] = String(now)
    record[:model] = Sym(model)
    record[:plan] = describe_plan(plan)
    record[:threshold] = Float64(threshold)
    record[:feed] = SymDict((k => v for (k, v) in feed if k !== :payload))
    record[:payload_bytes] = get(feed, :payload, nothing) === nothing ? 0 :
                             length(JSON3.write(jsonable(get(feed, :payload, nothing))))
    record[:source] = get(feed, :source, :generated)
    record[:status] = get(feed, :status, :offline)
    record[:freshness] = get(feed, :freshness, :unknown)
    record[:age_days] = get(feed, :age_days, NaN)
    record[:observations] = observations === nothing ? SymDict() :
                            SymDict(k => length(v) for (k, v) in observations
                                    if v isa AbstractVector)
    record[:parameters] = online_cal === nothing ? SymDict() : online_cal[:parameters]
    record[:comparisons] = comparisons
    record[:ks] = ks
    record[:worst_change] = worst
    record[:verdict] = verdict
    record[:reason] = reason
    if append_log && log_path !== nothing
        record[:log] = append_reevaluation(record, log_path)
    end
    return record
end

"""The verdict and the reason of one reevaluation round."""
function _reevaluation_verdict(feed, comparisons, ks, worst, threshold)
    status = get(feed, :status, :offline)
    fresh = get(feed, :freshness, :unknown)
    if isempty(comparisons) && isempty(ks)
        (fresh === :expired || status === :offline) &&
            return (:escalate, :no_observations_and_stale_source)
        return (:keep, :no_online_observations)
    end
    worst > threshold && return (:recalibrate, :parameter_moved)
    any(row -> !row[:same_process], values(ks)) && return (:recalibrate, :sample_shifted)
    fresh === :expired && return (:escalate, :stale_source)
    return (:keep, :within_threshold)
end

"""Append one reevaluation record to the log (a JSON array on disk)."""
function append_reevaluation(record::AbstractDict, path::AbstractString)
    existing = read_json_file(path)
    rows = existing === nothing ? Any[] : Any[r for r in existing]
    push!(rows, jsonable(record))
    mkpath(dirname(path))
    open(path, "w") do io
        JSON3.pretty(io, rows)
    end
    return path
end

"""The reevaluation log as a vector of records (`[]` when there is no log yet)."""
function reevaluation_log(path::AbstractString = joinpath("data", "reevaluation_log.json"))
    existing = read_json_file(path)
    existing === nothing && return Any[]
    return Any[r for r in existing]
end

"""The last record of the reevaluation log (`nothing` when the log is empty)."""
function last_reevaluation(path::AbstractString = joinpath("data", "reevaluation_log.json"))
    rows = reevaluation_log(path)
    return isempty(rows) ? nothing : rows[end]
end

"""The reevaluation record as one table row for the report."""
function feed_row(record::AbstractDict)
    return (at = get(record, :at, ""), source = get(record, :source, :generated),
        status = get(record, :status, :offline), freshness = get(record, :freshness, :unknown),
        age_days = get(record, :age_days, NaN), verdict = get(record, :verdict, :keep),
        reason = get(record, :reason, :unknown), worst_change = get(record, :worst_change, NaN),
        observations = sum(values(get(record, :observations, SymDict())); init = 0))
end