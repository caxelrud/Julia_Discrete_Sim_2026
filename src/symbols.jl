# =============================================================================
# symbols.jl -- the DiscreteSim symbol vocabulary.
#
# Every categorical value of the package is a `Symbol`: the entity that moves
# through the model (`:job`, `:call`, `:truck`), the kind of event that moves it
# (`:arrival`, `:end_service`), the kind of resource that serves it (`:server`,
# `:machine`, `:berth`), the queue discipline (`:fifo`, `:spt`, `:edd`), the
# distribution family (`:exponential`, `:lognormal`, ...), the metric
# (`:wait`, `:queue_length`, `:utilisation`), the data source (`:offline_cache`,
# `:online`), the freshness of a source and the verdict of a reevaluation.
#
# Keeping the vocabulary in one place means that every `Dict`, `NamedTuple` and
# `struct` speaks the same language, that a report can be assembled generically,
# and that a typo is caught by `validate_vocabulary` instead of silently
# producing a `missing` lookup.
# =============================================================================

## ---- contents of a model ------------------------------------------------------

"""Entities that flow through the models (also the trace `entity` column)."""
const ENTITIES = (:job, :part, :order, :customer, :call, :truck, :pallet, :batch,
    :task, :token, :patient, :vehicle)

"""Kinds of event the calendar schedules and the trace records."""
const EVENT_KINDS = (:create, :arrival, :start_queue, :end_queue, :start_service,
    :end_service, :request, :acquire, :release, :preempt, :breakdown, :repair,
    :reorder, :receive, :ship, :scrap, :rework, :shift_change, :timeout, :interrupt,
    :schedule, :cancel, :warmup_end, :custom)

"""Kinds of resource a model can ask for."""
const RESOURCE_KINDS = (:server, :machine, :operator, :berth, :loader, :tank,
    :silo, :pallet_store, :channel, :work_center, :buffer)

"""Queue disciplines honoured by `Resource`. `:spt` and `:edd` need the service
estimate / due date the requesting process carries in its attributes."""
const DISCIPLINES = (:fifo, :lifo, :priority, :spt, :edd, :srpt, :random)

"""A process is always in exactly one of these states."""
const PROCESS_STATES = (:ready, :running, :waiting, :blocked, :passive, :finished,
    :failed, :cancelled)

"""A resource is always in exactly one of these states."""
const RESOURCE_STATES = (:idle, :busy, :blocked, :maintenance, :offline)

"""What a process asks the scheduler for when it yields."""
const SUSPENSION_KINDS = (:hold, :block, :passivate, :finish)

## ---- statistics ---------------------------------------------------------------

"""Kinds of statistic a collector can be."""
const STATISTIC_KINDS = (:tally, :time_weighted, :counter, :histogram, :recorder,
    :maximum, :minimum)

"""The canonical system metrics extracted from a run."""
const SYSTEM_METRICS = (:throughput, :cycle_time_mean, :wait_mean, :wait_p95,
    :service_mean, :queue_length_mean, :in_system_mean, :wip_mean, :utilisation,
    :availability, :completed, :scrapped, :reworked, :inventory_mean, :fill_rate,
    :stockout_fraction, :backlog_mean, :orders_placed, :abandoned_fraction,
    :service_level, :tardiness_mean, :setup_fraction, :blocked_fraction,
    :starved_fraction, :revenue)

"""What a metric measures, used to pick a unit and to aggregate correctly."""
const METRIC_KINDS = (
    :throughput => :rate,
    :cycle_time_mean => :duration,
    :wait_mean => :duration,
    :wait_p95 => :duration,
    :service_mean => :duration,
    :queue_length_mean => :count,
    :in_system_mean => :count,
    :wip_mean => :count,
    :utilisation => :ratio,
    :availability => :ratio,
    :completed => :count,
    :scrapped => :count,
    :reworked => :count,
    :inventory_mean => :count,
    :fill_rate => :ratio,
    :stockout_fraction => :ratio,
    :backlog_mean => :count,
    :orders_placed => :count,
    :abandoned_fraction => :ratio,
    :service_level => :ratio,
    :lost_orders => :count,
    :tardiness_mean => :duration,
    :setup_fraction => :ratio,
    :blocked_fraction => :ratio,
    :starved_fraction => :ratio,
    :revenue => :money,
)

"""Display label of every metric (a `Symbol`, like everything else)."""
const METRIC_LABELS = (
    :throughput => :Throughput,
    :cycle_time_mean => :MeanCycleTime,
    :wait_mean => :MeanWait,
    :wait_p95 => :P95Wait,
    :service_mean => :MeanService,
    :queue_length_mean => :MeanQueueLength,
    :in_system_mean => :MeanInSystem,
    :wip_mean => :MeanWIP,
    :utilisation => :Utilisation,
    :availability => :Availability,
    :completed => :Completed,
    :scrapped => :Scrapped,
    :reworked => :Reworked,
    :inventory_mean => :MeanInventory,
    :fill_rate => :FillRate,
    :stockout_fraction => :StockoutFraction,
    :backlog_mean => :MeanBacklog,
    :orders_placed => :OrdersPlaced,
    :abandoned_fraction => :AbandonmentFraction,
    :service_level => :ServiceLevel,
    :lost_orders => :LostOrders,
    :tardiness_mean => :MeanTardiness,
    :setup_fraction => :SetupFraction,
    :blocked_fraction => :BlockedFraction,
    :starved_fraction => :StarvedFraction,
    :revenue => :Revenue,
)


## ---- random variates ----------------------------------------------------------

"""Distribution families accepted by `dist`."""
const DISTRIBUTION_KINDS = (:deterministic, :constant, :exponential, :normal,
    :lognormal, :uniform, :triangular, :gamma, :weibull, :erlang, :beta, :poisson,
    :geometric, :empirical, :empirical_continuous, :discrete, :categorical)

## ---- data sources (offline first, online for reevaluation) --------------------

"""Where a number came from."""
const DATA_SOURCES = (:generated, :offline_cache, :online, :theory, :user)

"""How fresh a data source is."""
const FRESHNESS = (:fresh, :stale, :expired, :offline, :unknown)

"""What the reevaluation layer concluded."""
const REEVALUATION_VERDICTS = (:recalibrate, :keep, :escalate)

"""Policy of the offline/online data layer."""
const ONLINE_POLICIES = (:offline_first, :online_first, :cache_only)

"""Status of one attempt to read an online source."""
const FETCH_STATUSES = (:ok, :cached, :offline, :timeout, :error, :disabled, :empty)

## ---- experiments --------------------------------------------------------------

"""How a set of runs was designed."""
const EXPERIMENT_KINDS = (:single, :replications, :warmup, :batch_means, :paired,
    :sweep, :factorial)

"""Verdict of a paired scenario comparison."""
const COMPARISON_VERDICTS = (:better, :worse, :indistinguishable)

"""Direction in which a metric is good news."""
const OPTIMISATION_DIRECTIONS = (:min, :max)

"""Verdict of an analytical cross-check."""
const VALIDATION_VERDICTS = (:validated, :marginal, :failed, :not_applicable)

"""The analytical models known to `theory`."""
const THEORY_KINDS = (:mm1, :mmc, :md1, :mg1, :gg1_approx, :mm1k, :mmcc, :mmck,
    :erlang_b, :erlang_c)

"""What the whole simulation run did."""
const RUN_VERDICTS = (:stable, :degraded, :overloaded, :underused, :empty, :unknown)

## ---- units --------------------------------------------------------------------

"""Unit of a metric or a parameter."""
const UNITS = (:count, :seconds, :minutes, :hours, :days, :weeks, :ratio, :percent,
    :items_per_hour, :items_per_day, :per_hour, :per_day, :currency,
    :currency_per_hour, :inventory_units, :orders, :calls, :jobs)

## ---- normalising helpers ------------------------------------------------------

"""
    Sym(x) -> Symbol

Normalise any spelling of a categorical value to a `Symbol`. `Sym(:fifo)`,
`Sym("fifo")` and `Sym(" FIFO ")` all return `:fifo`, which is why every
constructor of this package funnels its symbol arguments through `Sym`.
"""
Sym(x::Symbol) = x
Sym(x::AbstractString) = Symbol(replace(strip(x), ' ' => '_'))
Sym(x::AbstractChar) = Symbol(x)
Sym(x::Integer) = Symbol(x)
Sym(::Nothing) = :none
Sym(x) = Symbol(string(x))

"""`String` form of a categorical value, e.g. `code_string(:queue_length)`."""
code_string(x) = String(Sym(x))

"""Human-readable form of a categorical value: `title_string(:queue_length)` is
`"Queue length"`; used by the report tables and the figure legends. Works with
multi-byte characters (`:λW`)."""
function title_string(x)
    s = replace(code_string(x), '_' => ' ')
    isempty(s) && return s
    return string(uppercase(first(s)), chop(s; head = 1, tail = 0))
end

"""Two categorical values are equal after normalisation."""
symbol_equal(a, b) = Sym(a) === Sym(b)

"""
    symbol_key(x) -> Symbol

Key used for the symbol-keyed containers of the package: anything that is not a
`Symbol` is converted with `Sym`, `nothing` becomes `:none`.
"""
symbol_key(x) = Sym(x)

"""`true` when the value belongs to one of the vocabularies."""
is_metric(x) = Sym(x) in SYSTEM_METRICS
is_entity(x) = Sym(x) in ENTITIES
is_event_kind(x) = Sym(x) in EVENT_KINDS
is_resource_kind(x) = Sym(x) in RESOURCE_KINDS
is_discipline(x) = Sym(x) in DISCIPLINES
is_distribution_kind(x) = Sym(x) in DISTRIBUTION_KINDS
is_data_source(x) = Sym(x) in DATA_SOURCES
is_unit_of(x) = Sym(x) in UNITS

"""
    vocabulary_of(kind) -> NTuple

The vocabulary tuple named by `kind`, e.g. `vocabulary_of(:disciplines)` is
`DISCIPLINES`.
"""
function vocabulary_of(kind)
    k = Sym(kind)
    k === :entities && return ENTITIES
    k === :events && return EVENT_KINDS
    k === :resources && return RESOURCE_KINDS
    k === :disciplines && return DISCIPLINES
    k === :distributions && return DISTRIBUTION_KINDS
    k === :metrics && return SYSTEM_METRICS
    k === :statistics && return STATISTIC_KINDS
    k === :sources && return DATA_SOURCES
    k === :freshness && return FRESHNESS
    k === :units && return UNITS
    k === :experiments && return EXPERIMENT_KINDS
    k === :theory && return THEORY_KINDS
    k === :policies && return ONLINE_POLICIES
    k === :process_states && return PROCESS_STATES
    k === :resource_states && return RESOURCE_STATES
    k === :verdicts && return REEVALUATION_VERDICTS
    k === :comparisons && return COMPARISON_VERDICTS
    k === :validation && return VALIDATION_VERDICTS
    k === :run_verdicts && return RUN_VERDICTS
    throw(ArgumentError("unknown vocabulary $(code_string(k)); known kinds are " *
                        join(sort(code_string.(vocabulary_kinds())), ", ")))
end

"""Kinds accepted by [`vocabulary_of`](@ref)."""
vocabulary_kinds() = (:entities, :events, :resources, :disciplines, :distributions,
    :metrics, :statistics, :sources, :freshness, :units, :experiments, :theory,
    :policies, :process_states, :resource_states, :verdicts, :comparisons,
    :validation, :run_verdicts)

"""
    validate_vocabulary(kind, values) -> (; ok, known, unknown)

Check `values` against a vocabulary tuple named by `kind`. Returns the offending
values instead of throwing, so a caller can decide whether an unknown symbol is a
typo or a deliberate extension.
"""
function validate_vocabulary(kind, values)
    vocabulary = vocabulary_of(kind)
    vals = values isa Symbol || values isa AbstractString ? Any[values] : collect(values)
    unknown = Any[v for v in vals if Sym(v) ∉ vocabulary]
    return (ok = isempty(unknown), known = Sym.(vals), unknown = Sym.(unknown))
end

"""
    @syms a b c

Bind `a`, `b` and `c` to the symbols `:a`, `:b` and `:c`: the shorthand that
keeps the symbol vocabulary out of the way of the mathematics.

```julia
@syms λ μ ρ                    # λ === :λ, μ === :μ, ρ === :ρ
params[λ]                      # the arrival rate
```
"""
macro syms(names...)
    exprs = [Expr(:(=), esc(n), QuoteNode(n)) for n in names]
    return Expr(:block, exprs..., QuoteNode(names))
end

"""Kind (`:rate`, `:duration`, `:count`, `:ratio`, `:money`) of a metric."""
metric_kind(m) = get(METRIC_KIND_TABLE, Sym(m), :count)

"""Unit symbol implied by the kind of a metric, or by the short name of a statistic."""
function metric_unit(m)
    k = Sym(m)
    haskey(STATISTIC_UNIT_TABLE, k) && return STATISTIC_UNIT_TABLE[k]
    kind = metric_kind(k)
    return kind === :rate ? :items_per_hour :
           kind === :duration ? :minutes :
           kind === :ratio ? :ratio :
           kind === :money ? :currency : :count
end

"""Display label of a metric (falls back to `title_string`)."""
metric_label(m) = get(METRIC_LABEL_TABLE, Sym(m), Symbol(title_string(m)))

## ---- lookup tables of the metric vocabulary ------------------------------------

"""Lookup table of [`METRIC_KINDS`](@ref) (a `Symbol` is the key of a record)."""
const METRIC_KIND_TABLE = Dict{Symbol,Symbol}(METRIC_KINDS)

"""Lookup table of [`METRIC_LABELS`](@ref)."""
const METRIC_LABEL_TABLE = Dict{Symbol,Symbol}(METRIC_LABELS)

"""Units of the short names a statistic is usually registered under."""
const STATISTIC_UNITS = (
    wait = :minutes,
    sojourn = :minutes,
    service = :minutes,
    tardiness = :minutes,
    setup = :minutes,
    queue_length = :count,
    wip = :count,
    in_system = :count,
    inventory = :count,
    backlog = :count,
    utilisation = :ratio,
    fill_rate = :ratio,
    service_level = :ratio,
    stockout_fraction = :ratio,
)

"""Lookup table of [`STATISTIC_UNITS`](@ref), built once for `metric_unit`."""
const STATISTIC_UNIT_TABLE =
    Dict{Symbol,Symbol}(k => v for (k, v) in pairs(STATISTIC_UNITS))

"""`:min` or `:max`: the direction in which a metric is good news."""
function optimisation_direction(m)
    return metric_kind(m) in (:duration, :count) ? :min :
           metric_kind(m) === :rate ? :max : :max
end

"""`true` when a lower value of the metric is the better one."""
is_lower_better(m) = optimisation_direction(m) === :min

"""Relative difference of two numbers (0 when the reference is 0)."""
function relative_change(new, old)
    iszero(old) && return new == old ? 0.0 : Inf
    return (new - old) / old
end

"""Format a duration given in the time unit of a model, in a readable way."""
function format_duration(x::Real, unit::Symbol = :minutes)
    u = code_string(unit)
    return string(round(x, digits = 3), " ", u)
end
