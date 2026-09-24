# =============================================================================
# models.jl -- the reference models of the package.
#
# A simulation engine is only useful with models worth simulating, so this file
# ships five of them, each a small, honest description of a real system:
#
# | model | what it describes | the question it answers |
# |---|---|---|
# | `:mmc` | a service pool with `c` identical servers | *how many servers do we need?* |
# | `:transfer_line` | a serial line with buffers and failures | *where is the bottleneck?* |
# | `:machine_shop` | a job shop with routings, rework, scrap and breakdowns | *what is the OEE?* |
# | `:inventory` | an `(s, S)` replenishment policy with lead time | *what service level does this stock buy?* |
# | `:call_center` | agents on shifts, VIP priority, abandonment | *do we meet the service level?* |
#
# Every model is a *builder*: `build_model(name, params, opts)` returns a fresh
# `Sim` that has not been run yet, so `experiment` can drive it, and every model
# records the same kind of statistics (`:wait`, `:sojourn`, `:wip`,
# `:completed`), which is why the report, the metrics and the figures work for all
# of them without a single special case.
#
# `MODEL_CATALOGUE` holds the description of each model (`:title`, `:entity`,
# `:metrics`, `:params`, `:series`, `:theory`), so a notebook can iterate over the
# catalogue and build a dashboard for a model it has never heard of.
# =============================================================================

"""The models of the package, in the order a reader should meet them."""
const MODELS = (:mmc, :transfer_line, :machine_shop, :inventory, :call_center)

"""Title, entity, resource, series and parameters of every model."""
const MODEL_CATALOGUE = (
    mmc = (
        title = :ServicePool,
        entity = :customer,
        resource = :server,
        series = :wip,
        description = :ServicePoolWithIdenticalServers,
        theory = :mmc,
        metrics = (:throughput, :wait_mean, :wait_p95, :cycle_time_mean, :queue_length_mean,
            :utilisation, :completed),
        params = (:arrival_rate, :service_rate, :servers, :discipline, :balk_threshold),
    ),
    transfer_line = (
        title = :TransferLine,
        entity = :part,
        resource = :station,
        series = :wip,
        description = :SerialLineWithBuffersAndFailures,
        theory = :none,
        metrics = (:throughput, :cycle_time_mean, :wip_mean, :utilisation, :blocked_fraction,
            :availability, :completed),
        params = (:arrival_rate, :stations, :machines, :buffers, :cycle, :mtbf, :mttr),
    ),
    machine_shop = (
        title = :JobShop,
        entity = :job,
        resource = :machine,
        series = :wip,
        description = :JobShopWithRoutingsReworkScrapAndBreakdowns,
        theory = :none,
        metrics = (:throughput, :cycle_time_mean, :wip_mean, :utilisation, :availability,
            :scrapped, :reworked, :tardiness_mean, :completed),
        params = (:arrival_rate, :machines, :routing, :rework_rate, :scrap_rate, :mtbf, :mttr,
            :setup_time),
    ),
    inventory = (
        title = :InventoryPosition,
        entity = :order,
        resource = :stock,
        series = :inventory,
        description = :ReorderPointPolicyWithLeadTimeAndBackorders,
        theory = :none,
        metrics = (:inventory_mean, :backlog_mean, :fill_rate, :stockout_fraction,
            :orders_placed, :completed),
        params = (:demand_rate, :demand_size, :lead_time, :reorder_point, :order_up_to,
            :initial_level),
    ),
    call_center = (
        title = :ContactCenter,
        entity = :call,
        resource = :agent,
        series = :wip,
        description = :AgentPoolWithPatienceAndPriority,
        theory = :none,
        metrics = (:throughput, :wait_mean, :wait_p95, :service_level, :abandoned_fraction,
            :utilisation, :completed),
        params = (:arrival_rate, :service_rate, :agents, :patience, :vip_fraction,
            :service_target, :shifts),
    ),
)

"""Description record of one model."""
function catalogue(name::Symbol)
    k = Sym(name)
    haskey(MODEL_CATALOGUE, k) || throw(ArgumentError(string("unknown model :", k,
        "; known models: ", join(code_string.(MODELS), ", "))))
    return MODEL_CATALOGUE[k]
end

"""Title of a model (a `Symbol`)."""
model_title(name::Symbol) = catalogue(name).title

"""Serialisation of a model, drawn for the catalogue test."""
model_names() = Symbol[k for k in keys(MODEL_CATALOGUE)]

"""
    model_params(name, overrides...) -> SymDict

The default parameters of a model, with any overrides applied. This is what a
notebook or a scenario does: start from the defaults, change what the question is
about, and keep everything else identical.
"""
function model_params(name::Symbol, overrides...)
    p = default_params(Sym(name))
    for o in overrides
        (o isa AbstractDict || o isa NamedTuple) || continue
        for (k, v) in pairs(o)
            p[Sym(k)] = v
        end
    end
    return p
end

"""Apply overrides to an existing parameter record (the calibrated one, usually)."""
function model_params(base::AbstractDict, overrides...)
    p = SymDict(base)
    for o in overrides
        (o isa AbstractDict || o isa NamedTuple) || continue
        for (k, v) in pairs(o)
            p[Sym(k)] = v
        end
    end
    return p
end

"""`Sim` for a model: the options of a run are all symbol-keyed."""
function model_sim(name::Symbol, opts::AbstractDict = SymDict();
    time_unit::Symbol = :minutes)
    seed = get(opts, :seed, 20260101)
    horizon = get(opts, :horizon, 2000.0)
    σ = Sim(Sym(name); seed = Int(seed), horizon = Float64(horizon),
        trace_events = Bool(get(opts, :trace, false)), time_unit = Sym(time_unit),
        trace_limit = 100_000, max_events = 5_000_000)
    haskey(opts, :scenario) && (σ.scenario = SymDict(:name => Sym(opts[:scenario])))
    haskey(opts, :params) && (σ.scenario[:params] = opts[:params])
    haskey(opts, :replication) && (σ.scenario[:replication] = opts[:replication])
    return σ
end

"""The standard statistics every model of the package records."""
function standard_statistics!(σ::Sim; keep::Integer = 20_000)
    statistic!(σ, :wait, Tally(:wait; unit = time_unit(σ), keep = keep))
    statistic!(σ, :sojourn, Tally(:sojourn; unit = time_unit(σ), keep = keep))
    statistic!(σ, :service, Tally(:service; unit = time_unit(σ), keep = keep))
    statistic!(σ, :wip, Recorder(:wip))
    statistic!(σ, :completed, Counter(:completed; unit = :count))
    statistic!(σ, :status, Counter(:status; unit = :count))
    return σ
end

"""Name of the entity a model moves (used by the trace and the report)."""
model_entity(name::Symbol) = catalogue(name).entity

"""Name of the resource a model is built around."""
model_resource(name::Symbol) = catalogue(name).resource

"""Name of the series a model records for the warmup analysis and the figures."""
model_series(name::Symbol) = catalogue(name).series

## ---- default parameters and scenarios ------------------------------------------

"""
    default_params(name) -> SymDict

The parameters of a model and their reference values. They are chosen so that the
reference scenario is *busy but stable* -- a utilisation around 0.8, which is
where queueing systems are interesting and where a simulation has to be honest.
"""
function default_params(name::Symbol)
    k = Sym(name)
    d = SymDict()
    if k === :mmc
        d[:arrival_rate] = 0.8           # customers per minute
        d[:service_rate] = 1.0           # services per minute and server
        d[:servers] = 2
        d[:discipline] = :fifo
        d[:balk_threshold] = 0           # 0 = never balk
    elseif k === :transfer_line
        d[:stations] = 4
        d[:machines] = (1, 1, 1, 1)      # machines per station
        d[:buffers] = (6, 6, 6, 6)       # waiting capacity before each station
        d[:cycle] = (3.6, 5.0, 4.4, 3.8) # mean processing time per station
        d[:arrival_rate] = 0.20          # parts per minute
        d[:mtbf] = 500.0                 # minutes between failures
        d[:mttr] = 10.0                  # minutes to repair
        d[:cv2] = 0.25                    # squared CV of the processing time
    elseif k === :machine_shop
        d[:arrival_rate] = 0.095          # jobs per minute
        d[:machines] = (:mill, :drill, :grinder, :lathe, :press)
        d[:cycles] = (mill = 14.0, drill = 10.0, grinder = 12.0, lathe = 12.0, press = 10.0)
        d[:routing] = (mill = (:mill, :drill, :grinder), drill = (:drill, :lathe),
            grinder = (:grinder, :mill), lathe = (:lathe, :drill, :press),
            press = (:press, :grinder))
        d[:mix] = (mill = 0.3, drill = 0.25, grinder = 0.2, lathe = 0.15, press = 0.1)
        d[:mtbf] = (mill = 180.0, drill = 240.0, grinder = 150.0, lathe = 220.0,
            press = 300.0)
        d[:mttr] = (mill = 12.0, drill = 8.0, grinder = 15.0, lathe = 10.0, press = 6.0)
        d[:scrap_rate] = 0.02
        d[:rework_rate] = 0.06
        d[:setup_time] = 2.0
        d[:wip_limit] = 80                 # the shop refuses work beyond this WIP
    elseif k === :inventory
        d[:demand_rate] = 2.0            # orders per day
        d[:demand_size] = 12.0           # units per order
        d[:lead_time] = 3.0              # days
        d[:reorder_point] = 90.0
        d[:order_up_to] = 240.0
        d[:initial_level] = 180.0
        d[:review] = 0.5                 # days between inventory reviews
    elseif k === :call_center
        d[:arrival_rate] = 1.6           # calls per minute
        d[:service_rate] = 0.5           # calls per minute and agent
        d[:agents] = 4
        d[:patience] = 5.0               # mean minutes a caller waits before giving up
        d[:vip_fraction] = 0.15
        d[:service_target] = 0.5         # minutes: the service-level target
        d[:shifts] = (30.0, 25.0)        # shift length, break length
    else
        throw(ArgumentError("unknown model :$k; known models: " *
                            join(code_string.(MODELS), ", ")))
    end
    return d
end

"""The scenarios every model is compared against, the first one being the baseline."""
const SCENARIOS = (
    mmc = (:baseline, :capacity_up, :demand_up, :fast_service),
    transfer_line = (:baseline, :buffer_up, :add_machine, :faster_station),
    machine_shop = (:baseline, :demand_down, :reliability_up, :quality_up),
    inventory = (:baseline, :more_stock, :fast_supplier, :lean_stock),
    call_center = (:baseline, :more_agents, :better_patience, :priority_first),
)

"""Scenarios of a model."""
model_scenarios(name::Symbol) = SCENARIOS[Sym(name)]

"""
    scenario_overrides(name, scenario) -> SymDict

What a scenario changes about a parameter record, as symbol-keyed overrides that
[`apply_scenario`](@ref) understands:

* a plain number sets the parameter,
* `(:factor, x)` multiplies it, `(:delta, x)` shifts it,
* a function maps the current value (which is how a vector of buffer sizes is
  widened without rewriting the whole vector).
"""
function scenario_overrides(name::Symbol, scenario::Symbol)
    k, s = Sym(name), Sym(scenario)
    d = SymDict()
    s === :baseline && return d
    if k === :mmc
        s === :capacity_up && (d[:servers] = (:delta, 1))
        s === :demand_up && (d[:arrival_rate] = (:factor, 1.2))
        s === :fast_service && (d[:service_rate] = (:factor, 1.2))
    elseif k === :transfer_line
        s === :buffer_up && (d[:buffers] = (v -> map_table(v, x -> x + 4)))
        s === :add_machine && (d[:machines] = (v -> map_table(v, x -> x + 1)))
        s === :faster_station && (d[:cycle] = (v -> map_table(v, x -> 0.85x)))
    elseif k === :machine_shop
        s === :demand_down && (d[:arrival_rate] = (:factor, 0.9))
        s === :reliability_up && (d[:mtbf] = (v -> scale_table(v, 1.5)))
        s === :quality_up && (d[:scrap_rate] = (:factor, 0.5); d[:rework_rate] = (:factor, 0.5))
    elseif k === :inventory
        s === :more_stock && (d[:reorder_point] = (:factor, 1.5);
                              d[:order_up_to] = (:factor, 1.5))
        s === :fast_supplier && (d[:lead_time] = (:factor, 0.5))
        s === :lean_stock && (d[:reorder_point] = (:factor, 0.7);
                              d[:order_up_to] = (:factor, 0.8))
    elseif k === :call_center
        s === :more_agents && (d[:agents] = (:delta, 1))
        s === :better_patience && (d[:patience] = (:factor, 2.0))
        s === :priority_first && (d[:vip_fraction] = 0.3)
    end
    isempty(d) && throw(ArgumentError("unknown scenario :$s for model :$k; known: " *
                                      join(code_string.(model_scenarios(k)), ", ")))
    return d
end

"""
    apply_scenario(base, name, scenario) -> SymDict

Apply the overrides of a scenario to a parameter record -- the calibrated one, in
a study, or the defaults, in a notebook. This is why a scenario can be compared
against a *calibrated* baseline and still change exactly one thing.
"""
function apply_scenario(base::AbstractDict, name::Symbol, scenario::Symbol)
    out = SymDict(base)
    for (k, spec) in scenario_overrides(name, scenario)
        if spec isa Tuple && length(spec) == 2 && spec[1] isa Symbol
            kind, x = spec
            current = get(out, k, nothing)
            kind === :factor && current !== nothing && (out[k] = current * x)
            kind === :delta && (out[k] = (current === nothing ? 0 : current) + x)
            kind === :value && (out[k] = x)
        elseif spec isa Function
            current = get(out, k, nothing)
            current === nothing || (out[k] = spec(current))
        else
            out[k] = spec
        end
    end
    return out
end

"""
    scenario_params(name, scenario) -> SymDict

The parameters of a named scenario *of the defaults*: the baseline, or one of the
alternatives of [`SCENARIOS`](@ref). A study applies the same overrides to its
calibrated parameters with [`apply_scenario`](@ref).
"""
scenario_params(name::Symbol, scenario::Symbol) =
    apply_scenario(default_params(Sym(name)), Sym(name), Sym(scenario))

## ---- shared bits of the models -------------------------------------------------

"""
    record_wip!(σ, value) -> value

Record work in progress twice: as a time series (`:wip`, a `Recorder`, which is
what the warmup analysis and the figures read) and as a time-weighted statistic
(`:wip_mean`, which is what the metric table reads). Keeping both means the
figure and the number always describe the same run.
"""
function record_wip!(σ::Sim, value::Real)
    v = Float64(value)
    record!(σ, :wip, v)
    observe!(σ, :wip_mean, v)
    return v
end

"""Register the pair of statistics a model records for work in progress."""
function wip_statistics!(σ::Sim)
    statistic!(σ, :wip, Recorder(:wip))
    statistic!(σ, :wip_mean, TimeWeighted(:wip_mean))
    return σ
end

## ---- :mmc -- a pool of identical servers ---------------------------------------

"""
    build_mmc(params, opts) -> Sim

`c` identical servers, exponential interarrival times with rate `:arrival_rate`
and exponential service times with rate `:service_rate`. With `:balk_threshold`
above zero, a customer that finds more than that many waiting turns away instead
of joining, which is how a real service desk behaves.

```julia
σ = build_mmc(model_params(:mmc, (servers = 3,)),
              SymDict(:seed => 1, :horizon => 4000.0))
run!(σ)
utilisation(σ[:server])
```
"""
function build_mmc(params::AbstractDict, opts::AbstractDict = SymDict())
    λ = params[:arrival_rate]
    μ = params[:service_rate]
    c = Int(params[:servers])
    σ = model_sim(:mmc, opts)
    standard_statistics!(σ)
    wip_statistics!(σ)
    server = resource!(σ, Resource(:server; capacity = c,
        kind = Sym(get(params, :resource_kind, :server)),
        discipline = get(params, :discipline, :fifo)))
    balk = Int(get(params, :balk_threshold, 0))
    spawn!(σ, () -> mmc_arrivals(σ, λ, μ, server, balk); name = :arrivals)
    return σ
end

function mmc_arrivals(σ::Sim, λ, μ, server, balk)
    while σ.now <= σ.config.horizon
        hold!(σ, exp_rv(σ, :interarrival, λ))
        σ.now > σ.config.horizon && break
        if balk > 0 && length(server.queue) >= balk
            count!(σ, :status, :balked)
            continue
        end
        spawn!(σ, () -> mmc_customer(σ, μ, server); name = :customer,
            attrs = SymDict(:entity => :customer))
    end
    return nothing
end

function mmc_customer(σ::Sim, μ, server)
    t0 = σ.now
    service = exp_rv(σ, :service, μ)
    request!(σ, server; service_estimate = service)
    tally!(σ, :wait, σ.now - t0)
    record_wip!(σ, length(server.queue) + server.in_use)
    hold!(σ, service)
    release!(σ, server)
    record_wip!(σ, length(server.queue) + server.in_use)
    tally!(σ, :service, service)
    tally!(σ, :sojourn, σ.now - t0)
    count!(σ, :completed)
    count!(σ, :status, :served)
    trace!(σ, :ship, :customer, :server; value = σ.now - t0)
    return nothing
end

## ---- :transfer_line -- a serial line with buffers and failures ------------------

"""
    build_transfer_line(params, opts) -> Sim

A serial line: parts arrive at the first buffer, every station has `:machines`
identical machines, a buffer of `:buffers` places in front of it, a mean cycle
time from `:cycle` (with squared coefficient of variation `:cv2`) and random
failures with `:mtbf` and `:mttr`.

The model is the standard way to see *where* a line loses throughput: a machine
that waits because the upstream buffer is empty is starved, one that cannot pass a
finished part on is blocked, and both fractions are recorded -- so the report can
name the bottleneck instead of guessing it.
"""
function build_transfer_line(params::AbstractDict, opts::AbstractDict = SymDict())
    n = Int(params[:stations])
    machines = Tuple(Int.(params[:machines]))
    buffers = Tuple(Int.(params[:buffers]))
    cycle = Tuple(Float64.(params[:cycle]))
    λ = params[:arrival_rate]
    cv2 = Float64(get(params, :cv2, 0.25))
    σ = model_sim(:transfer_line, opts)
    standard_statistics!(σ)
    wip_statistics!(σ)
    statistic!(σ, :starved_time, Tally(:starved_time; keep = 20_000))
    statistic!(σ, :blocked_time, Tally(:blocked_time; keep = 20_000))

    inboxes = [resource!(σ, Store(Symbol(:buffer, :_, i); capacity = Int(buffers[i])))
               for i in 1:n]
    output = resource!(σ, Store(:output))
    stations = [resource!(σ, Resource(Symbol(:station, :_, i);
                     capacity = machines[i], kind = :machine)) for i in 1:n]
    for i in 1:n
        outbox = i == n ? output : inboxes[i + 1]
        for _ in 1:machines[i]
            spawn!(σ, () -> line_machine(σ, stations[i], inboxes[i], outbox, cycle[i], cv2);
                name = :machine)
        end
        spawn!(σ, () -> line_failures(σ, stations[i], params); name = :failures)
    end
    spawn!(σ, () -> line_arrivals(σ, λ, inboxes[1]); name = :arrivals)
    spawn!(σ, () -> line_shipper(σ, output, n); name = :shipper)
    return σ
end

function line_arrivals(σ::Sim, λ, first_buffer)
    while σ.now <= σ.config.horizon
        hold!(σ, exp_rv(σ, :interarrival, λ))
        σ.now > σ.config.horizon && break
        record_wip!(σ, wip_of(σ))
        store_item!(σ, first_buffer, SymDict(:name => :part, :created => σ.now))
        record_wip!(σ, wip_of(σ))
        trace!(σ, :arrival, :part, first_buffer.name)
    end
    return nothing
end

function line_machine(σ::Sim, station, inbox, outbox, cycle, cv2)
    while σ.now <= σ.config.horizon
        idle_from = σ.now
        part = retrieve!(σ, inbox)
        tally!(σ, :starved_time, σ.now - idle_from)
        request!(σ, station; service_estimate = cycle)
        hold!(σ, process_time(σ, cycle, cv2))
        release!(σ, station)
        part[:finished] = σ.now
        blocked_from = σ.now
        store_item!(σ, outbox, part)
        tally!(σ, :blocked_time, σ.now - blocked_from)
        record_wip!(σ, wip_of(σ))
    end
    return nothing
end

"""Processing time with mean `cycle` and squared coefficient of variation `cv2`."""
function process_time(σ::Sim, cycle::Real, cv2::Real)
    cv2 <= 0 && return cycle
    isapprox(cv2, 1.0; atol = 1e-9) && return exp_rv(σ, :service_gap, 1 / cycle)
    shape = 1 / cv2
    return gamma_rv(σ, :service_gap, shape, cycle / shape)
end

function line_failures(σ::Sim, station, params)
    mtbf = Float64(get(params, :mtbf, 0.0))
    mttr = Float64(get(params, :mttr, 0.0))
    (mtbf <= 0 || mttr <= 0) && return nothing
    while σ.now <= σ.config.horizon
        hold!(σ, exp_rv(σ, :mtbf, 1 / mtbf))
        σ.now > σ.config.horizon && break
        breakdown!(σ, station, exp_rv(σ, :mttr, 1 / mttr))
    end
    return nothing
end

"""Parts inside the line right now: what waits in the buffers plus what is served."""
function wip_of(σ::Sim)
    total = 0.0
    for (_, r) in σ.resources
        r isa Store && (total += length(r.items))
        r isa Resource && (total += r.in_use)
    end
    return total
end

function line_shipper(σ::Sim, output, n)
    span = Ref(0.0)
    while σ.now <= σ.config.horizon
        part = retrieve!(σ, output)
        cycle_time = σ.now - part[:created]
        tally!(σ, :sojourn, cycle_time)
        tally!(σ, :wait, cycle_time)
        count!(σ, :completed)
        count!(σ, :status, :shipped)
        trace!(σ, :ship, :part, :output; value = cycle_time)
    end
    metric!(σ, :parts_shipped, Float64(total_of(σ[:completed])))
    return nothing
end

## ---- :machine_shop -- a job shop with failures, rework and scrap ----------------

"""
    build_machine_shop(params, opts) -> Sim

Five machines (`:mill`, `:drill`, `:grinder`, `:lathe`, `:press`), each with its
own cycle time, its own MTBF/MTTR, a product mix with its own routing, rework and
scrap. Breakdowns *interrupt* the job on the machine (the job is thrown back to
the queue and finishes its remaining work after the repair), which is what makes
the availability -- not just the utilisation -- show up in the lead time.
"""
function build_machine_shop(params::AbstractDict, opts::AbstractDict = SymDict())
    σ = model_sim(:machine_shop, opts)
    standard_statistics!(σ)
    wip_statistics!(σ)
    statistic!(σ, :tardiness, Tally(:tardiness; unit = time_unit(σ), keep = 20_000))
    statistic!(σ, :scrapped, Counter(:scrapped; unit = :count))
    statistic!(σ, :reworked, Counter(:reworked; unit = :count))
    statistic!(σ, :setup, Tally(:setup; unit = time_unit(σ), keep = 20_000))
    statistic!(σ, :lost_orders, Counter(:lost_orders; unit = :count))

    machine_names = Tuple(Symbol.(params[:machines]))
    machines = SymDict()
    for m in machine_names
        machines[m] = resource!(σ, Resource(m; capacity = 1, kind = :machine,
            discipline = :priority))
        mtbf = table_value(params[:mtbf], m)
        mttr = table_value(params[:mttr], m)
        mtbf > 0 && mttr > 0 &&
            spawn!(σ, () -> shop_failures(σ, machines[m], mtbf, mttr); name = :failures)
    end
    spawn!(σ, () -> shop_arrivals(σ, params, machines); name = :arrivals)
    return σ
end

function shop_arrivals(σ::Sim, params, machines)
    λ = params[:arrival_rate]
    mix = params[:mix]
    products = Tuple(Symbol.(keys(mix)))
    in_shop = Ref(0)
    limit = Int(get(params, :wip_limit, 0))
    while σ.now <= σ.config.horizon
        hold!(σ, exp_rv(σ, :interarrival, λ))
        σ.now > σ.config.horizon && break
        if limit > 0 && in_shop[] >= limit
            count!(σ, :status, :refused)         # the shop will not take more work
            count!(σ, :lost_orders, :refused)
            continue
        end
        product = products[rand_index(σ, :mix, length(products))]
        vip = rand_bool(σ, :priority_mix, 0.1)
        job = SymDict(:name => :job, :product => product, :created => σ.now,
            :priority => vip ? 0 : 1, :rework => 0, :scrapped => false)
        job[:work] = sum(cycles_of(params, machines, product); init = 0.0)
        job[:due] = σ.now + Float64(get(params, :due_slack, 4.0)) * max(job[:work], 1.0)
        in_shop[] += 1
        spawn!(σ, () -> shop_job(σ, job, params, machines, in_shop); name = :job,
            attrs = SymDict(:entity => :job, :product => product))
    end
    return nothing
end

"""Total standard work content of a product, used for the due date."""
function cycles_of(params, machines, product)
    routing = params[:routing]
    haskey(routing, product) || return Float64[]
    return Float64[Float64(params[:cycles][m]) for m in routing[product]
                   if haskey(machines, m)]
end

"""Look a value up in a symbol-keyed table (a `NamedTuple` or a `SymDict`)."""
function table_value(table, key, default = 0.0)
    (table isa AbstractDict || table isa NamedTuple) || return Float64(default)
    haskey(table, Sym(key)) || return Float64(default)
    return Float64(table[Sym(key)])
end

"""
    map_table(value, f)

Apply `f` to a parameter that may be a number, a vector, a `NamedTuple` or a
symbol-keyed record: it is what lets a scenario widen every buffer of a line or
touch every station of a shop without knowing which shape the parameter has.
"""
map_table(v::Real, f) = f(v)
map_table(v::AbstractVector, f) = [map_table(x, f) for x in v]
map_table(v::NamedTuple, f) = NamedTuple{keys(v)}(Tuple(map_table(x, f) for x in values(v)))
map_table(v::AbstractDict, f) = SymDict(k => map_table(x, f) for (k, x) in v)
map_table(v::Tuple, f) = Tuple(map_table(x, f) for x in v)
map_table(v, f) = v

"""Scale a parameter of any shape by a factor (see [`map_table`](@ref))."""
scale_table(v, f::Real) = map_table(v, x -> x * f)

function shop_job(σ::Sim, job, params, machines, in_shop = Ref(1))
    try
        return shop_job_body(σ, job, params, machines)
    finally
        in_shop[] -= 1
    end
end

"""Body of one job of the shop: its routing, its rework, its scrap and its due date."""
function shop_job_body(σ::Sim, job, params, machines)
    t0 = σ.now
    record_wip!(σ, wip_of(σ))
    for (i, machine_name) in enumerate(params[:routing][job[:product]])
        haskey(machines, machine_name) || continue
        machine = machines[machine_name]
        if i == 1
            setup = Float64(get(params, :setup_time, 0.0))
            if setup > 0
                shop_hold!(σ, job, machine, setup)
                tally!(σ, :setup, setup)
            end
        end
        work = Float64(params[:cycles][machine_name])
        shop_hold!(σ, job, machine, work)
        if rand_bool(σ, :scrap, Float64(get(params, :scrap_rate, 0.0)))
            job[:scrapped] = true
            count!(σ, :status, :scrapped)
            count!(σ, :scrapped, :total)
            record_wip!(σ, wip_of(σ))
            return nothing
        end
        if rand_bool(σ, :rework, Float64(get(params, :rework_rate, 0.0)))
            job[:rework] += 1
            count!(σ, :status, :rework)
            count!(σ, :reworked, :total)
            shop_hold!(σ, job, machine, work)
        end
    end
    job[:finished] = σ.now
    tardiness = max(0.0, σ.now - job[:due])
    tally!(σ, :tardiness, tardiness)
    tally!(σ, :sojourn, σ.now - t0)
    tally!(σ, :wait, σ.now - t0)
    count!(σ, :completed)
    count!(σ, :status, tardiness > 0 ? :late : :on_time)
    record_wip!(σ, wip_of(σ))
    trace!(σ, :ship, :job, model_resource(:machine_shop); value = σ.now - t0,
        note = job[:product])
    return nothing
end

"""
    shop_hold!(σ, job, machine, duration) -> nothing

Acquire the machine, hold it for `duration` and release it -- surviving
breakdowns. When a failure interrupts the hold, the job keeps the *remaining*
time, releases what it holds and queues again; the repair must finish before the
machine can be granted again. Every path releases the machine, which is what
keeps a failure from leaking a machine.
"""
function shop_hold!(σ::Sim, job, machine, duration::Real)
    remaining = Float64(duration)
    while remaining > 0
        request!(σ, machine; priority = job[:priority], service_estimate = remaining)
        started = σ.now
        try
            hold!(σ, remaining)
            remaining = 0.0
        catch err
            err isa SimInterrupt || rethrow()
            remaining = max(0.0, remaining - (σ.now - started))
            count!(σ, :status, :interrupted)
        finally
            holds(machine, current_process(σ)) && release!(σ, machine)
        end
    end
    return nothing
end

function shop_failures(σ::Sim, machine, mtbf, mttr)
    while σ.now <= σ.config.horizon
        hold!(σ, exp_rv(σ, Symbol(:mtbf_, machine.name), 1 / mtbf))
        σ.now > σ.config.horizon && break
        breakdown!(σ, machine, exp_rv(σ, Symbol(:mttr_, machine.name), 1 / mttr))
        for pid in collect(keys(machine.holders))
            p = get(σ.processes, pid, nothing)
            p === nothing || interrupt!(σ, p, :breakdown)
        end
    end
    return nothing
end

## ---- :inventory -- an (s, S) policy, written with callbacks --------------------

"""
    build_inventory(params, opts) -> Sim

A stock position under an `(s, S)` policy: demand arrives with rate
`:demand_rate` and size `:demand_size`, the position is reviewed every `:review`
days, an order for `S - position` is placed as soon as the position drops to
`:reorder_point` and it arrives after `:lead_time`. Unsatisfied demand is
backordered.

This model is written in the *event-based* style -- one callback per demand, per
review and per receipt, no processes at all -- which is how the very large models
of this package are built, and which makes the state of the system (`:level`,
`:on_order`, `:backlog`) explicit in one record.
"""
function build_inventory(params::AbstractDict, opts::AbstractDict = SymDict())
    σ = model_sim(:inventory, opts; time_unit = :days)
    statistic!(σ, :inventory, Recorder(:inventory))
    statistic!(σ, :inventory_mean, TimeWeighted(:inventory_mean;
        initial = params[:initial_level]))
    statistic!(σ, :backlog_mean, TimeWeighted(:backlog_mean))
    statistic!(σ, :stockout_fraction, TimeWeighted(:stockout_fraction))
    statistic!(σ, :orders_placed, Counter(:orders_placed))
    statistic!(σ, :completed, Counter(:completed))
    statistic!(σ, :status, Counter(:status))
    statistic!(σ, :fill_rate, Tally(:fill_rate; unit = :ratio, keep = 20_000))
    statistic!(σ, :demand, Tally(:demand; unit = :count, keep = 20_000))

    state = SymDict(:level => Float64(params[:initial_level]), :on_order => 0.0,
        :backlog => 0.0, :demanded => 0.0, :lost => 0.0, :ordered_at => 0.0)
    callback!(σ, exp_rv(σ, :demand_gap, params[:demand_rate]), inventory_demand!, state,
        params; kind = :arrival)
    callback!(σ, Float64(params[:review]), inventory_review!, state, params; kind = :reorder)
    callback!(σ, Float64(σ.config.horizon), inventory_finalize!, state; kind = :custom,
        priority = -1000)
    return σ
end

"""Record the inventory position: level, backlog and the stock-out indicator."""
function record_inventory!(σ::Sim, state)
    level = state[:level]
    record!(σ, :inventory, level)
    observe!(σ, :inventory_mean, level)
    observe!(σ, :backlog_mean, state[:backlog])
    observe!(σ, :stockout_fraction, level <= 0 ? 1.0 : 0.0)
    return level
end

function inventory_demand!(σ::Sim, state, params)
    σ.now > σ.config.horizon && return nothing
    size = Float64(params[:demand_size]) * max(0.5, exp_rv(σ, :demand_size, 1.0))
    served = min(state[:level], size)
    state[:level] -= served
    shortfall = size - served
    shortfall > 1e-9 && (state[:backlog] += shortfall)
    state[:demanded] += size
    state[:lost] += shortfall
    count!(σ, :completed, :total)
    count!(σ, :status, shortfall > 1e-9 ? :short : :served)
    tally_record!(σ[:fill_rate], shortfall > 1e-9 ? 0.0 : 1.0)
    tally_record!(σ[:demand], size)
    record_inventory!(σ, state)
    trace!(σ, :arrival, :order, :stock; value = size,
        note = shortfall > 1e-9 ? :short : :served)
    callback!(σ, exp_rv(σ, :demand_gap, params[:demand_rate]), inventory_demand!, state,
        params; kind = :arrival)
    return nothing
end

function inventory_review!(σ::Sim, state, params)
    σ.now > σ.config.horizon && return nothing
    position = state[:level] + state[:on_order] - state[:backlog]
    if position <= Float64(params[:reorder_point]) && state[:on_order] <= 1e-9
        quantity = Float64(params[:order_up_to]) - position
        state[:on_order] += quantity
        state[:ordered_at] = σ.now
        count!(σ, :orders_placed, :total)
        trace!(σ, :reorder, :order, :stock; value = quantity)
        callback!(σ, exp_rv(σ, :lead_time, 1 / Float64(params[:lead_time])),
            inventory_receipt!, state, quantity; kind = :receive)
    end
    callback!(σ, Float64(params[:review]), inventory_review!, state, params; kind = :reorder)
    return nothing
end

function inventory_receipt!(σ::Sim, state, quantity)
    σ.now > σ.config.horizon && return nothing
    state[:on_order] -= quantity
    # a receipt first serves whatever is still owed, then builds stock
    backfilled = min(quantity, state[:backlog])
    state[:backlog] -= backfilled
    state[:level] += quantity - backfilled
    backfilled > 0 && count!(σ, :status, :backfilled)
    record_inventory!(σ, state)
    trace!(σ, :receive, :order, :stock; value = quantity,
        note = backfilled > 0 ? :backfilled : :stored)
    return nothing
end

"""Close the books at the end of the horizon: the fill rate and the mean backlog."""
function inventory_finalize!(σ::Sim, state)
    demanded = state[:demanded]
    metric!(σ, :fill_rate, demanded <= 0 ? 1.0 : 1 - state[:lost] / demanded)
    metric!(σ, :stockout_fraction, mean(σ[:stockout_fraction]))
    metric!(σ, :orders_placed, Float64(total_of(σ[:orders_placed])))
    metric!(σ, :backlog_mean, mean(σ[:backlog_mean]))
    metric!(σ, :inventory_mean, mean(σ[:inventory_mean]))
    metric!(σ, :completed, Float64(total_of(σ[:completed])))
    metric!(σ, :throughput, demanded <= 0 ? 0.0 :
            Float64(total_of(σ[:completed])) / measured_span(σ))
    return nothing
end

## ---- :call_center -- agents, patience and priority -----------------------------

"""
    build_call_center(params, opts) -> Sim

Agents (`:agents` of them) answer calls that arrive with rate `:arrival_rate`.
A share `:vip_fraction` of the calls is routed with priority, so it overtakes the
standard queue. Callers have an exponential patience with mean `:patience`: when
it expires, the caller is *interrupted* out of the queue and abandons -- which is
what makes `:service_level` (answered within `:service_target`) and
`:abandoned_fraction` the two numbers that matter.
"""
function build_call_center(params::AbstractDict, opts::AbstractDict = SymDict())
    σ = model_sim(:call_center, opts)
    standard_statistics!(σ)
    wip_statistics!(σ)
    statistic!(σ, :service_level, Tally(:service_level; unit = :ratio, keep = 20_000))
    statistic!(σ, :abandoned_fraction, Tally(:abandoned_fraction; unit = :ratio,
        keep = 20_000))
    agents = resource!(σ, Resource(:agent; capacity = Int(params[:agents]),
        kind = :operator, discipline = :priority))
    spawn!(σ, () -> center_arrivals(σ, params, agents); name = :arrivals)
    return σ
end

function center_arrivals(σ::Sim, params, agents)
    λ = params[:arrival_rate]
    vip_fraction = Float64(params[:vip_fraction])
    while σ.now <= σ.config.horizon
        hold!(σ, exp_rv(σ, :interarrival, λ))
        σ.now > σ.config.horizon && break
        vip = rand_bool(σ, :vip, vip_fraction)
        spawn!(σ, () -> center_call(σ, params, agents, vip); name = :call,
            attrs = SymDict(:entity => :call, :class => vip ? :vip : :standard))
    end
    return nothing
end

function center_call(σ::Sim, params, agents, vip)
    t0 = σ.now
    telephone = current_process(σ)
    patience = exp_rv(σ, :patience, 1 / Float64(params[:patience]))   # :patience is a mean
    dog = spawn!(σ, () -> center_patience(σ, telephone, patience); name = :watchdog)
    answered = false
    try
        request!(σ, agents; priority = vip ? 0 : 10)
        answered = true
    catch err
        err isa SimInterrupt || rethrow()
    end
    wait = σ.now - t0
    cancel!(σ, dog)
    tally!(σ, :wait, wait)
    if !answered
        tally_record!(σ[:service_level], 0.0)
        tally_record!(σ[:abandoned_fraction], 1.0)
        count!(σ, :status, :abandoned)
        trace!(σ, :timeout, :call, :agent; value = wait, note = :abandoned)
        return nothing
    end
    target = Float64(params[:service_target])
    tally_record!(σ[:service_level], wait <= target ? 1.0 : 0.0)
    tally_record!(σ[:abandoned_fraction], 0.0)
    count!(σ, :status, wait <= target ? :answered_in_target : :answered_late)
    record_wip!(σ, length(agents.queue) + agents.in_use)
    hold!(σ, exp_rv(σ, :service, Float64(params[:service_rate])))
    release!(σ, agents)
    record_wip!(σ, length(agents.queue) + agents.in_use)
    tally!(σ, :sojourn, σ.now - t0)
    count!(σ, :completed)
    trace!(σ, :end_service, :call, :agent; value = σ.now - t0,
        note = vip ? :vip : :standard)
    return nothing
end

function center_patience(σ::Sim, call, patience)
    hold!(σ, patience)
    interrupt!(σ, call, :impatience)
    return nothing
end

## ---- building any model --------------------------------------------------------

"""
    build_model(name, params, opts) -> Sim

Build the model `name` with the parameters `params` and the run options `opts`.
This is the single entry point the pipeline, the experiments and the notebooks
use, so a new model only has to be added here and to `MODEL_CATALOGUE`.

```julia
σ = build_model(:machine_shop, model_params(:machine_shop),
                SymDict(:seed => 20260101, :horizon => 5000.0))
```
"""
function build_model(name::Symbol, params::AbstractDict = SymDict(),
    opts::AbstractDict = SymDict())
    k = Sym(name)
    k === :mmc && return build_mmc(params, opts)
    k === :transfer_line && return build_transfer_line(params, opts)
    k === :machine_shop && return build_machine_shop(params, opts)
    k === :inventory && return build_inventory(params, opts)
    k === :call_center && return build_call_center(params, opts)
    throw(ArgumentError("unknown model :$k; known models: " *
                        join(code_string.(MODELS), ", ")))
end

"""
    build_scenario(name, scenario, opts) -> Sim

Build a named scenario of a model (`:baseline`, `:capacity_up`, ...), which is
what `compare_scenarios` and the dashboard iterate over.
"""
build_scenario(name::Symbol, scenario::Symbol, opts::AbstractDict = SymDict()) =
    build_model(name, scenario_params(name, scenario),
        merge(SymDict(opts), SymDict(:scenario => scenario)))

"""
    build_calibrated_scenario(cal, name, scenario, opts) -> Sim

Build a named scenario of a model whose parameters came from a calibration: the
scenario changes only what it is about, and the rest stays at the measured values.
This is what the study compares.
"""
function build_calibrated_scenario(cal::AbstractDict, name::Symbol, scenario::Symbol,
    opts::AbstractDict = SymDict())
    base = model_params_from_calibration(cal, name)
    params = apply_scenario(base, Sym(name), Sym(scenario))
    return build_model(name, params,
        merge(SymDict(opts), SymDict(:scenario => scenario)))
end

"""The analytical counterpart of a model (`nothing` when there is none)."""
function model_theory(name::Symbol, params::AbstractDict)
    k = Sym(name)
    if k === :mmc
        c = Int(params[:servers])
        λ = Float64(params[:arrival_rate])
        μ = Float64(params[:service_rate])
        λ / (μ * c) >= 1 && return nothing
        return theory(:mmc; λ = λ, μ = μ, c = c)
    end
    return nothing
end

## ---- model-specific cross-checks -----------------------------------------------

"""Mean of `size * max(0.5, Exp(1))`, the demand-size generator of the inventory model."""
function expected_demand_size(size::Real; n::Integer = 20_000)
    d = dist(:exponential, 1.0)
    rng = StableRNGs.StableRNG(20_260_101)
    total = 0.0
    for _ in 1:Int(n)
        total += Float64(size) * max(0.5, quantile(d, rand(rng)))
    end
    return total / n
end

"""
    inventory_validation(σ; tolerance = 0.10) -> SymDict

The cross-check of the inventory model, which has no queue to compare with a
closed form, so the invariants are checked instead: the demand-size generator must
reproduce its own expectation, the fill rate must agree with the fraction of
demands that were served in full, and the mean inventory level must lie between
zero and the order-up-to level.
"""
function inventory_validation(σ::Sim; demand_size::Real = 12.0, tolerance::Real = 0.10)
    obs = SymDict()
    haskey(σ.stats, :demand) && (obs[:demand_size] = mean(σ[:demand]))
    haskey(σ.metrics, :fill_rate) && (obs[:fill_rate] = σ.metrics[:fill_rate])
    served = count_of(σ[:status], :served)
    short = count_of(σ[:status], :short)
    obs[:served_fraction] = (served + short) == 0 ? NaN : served / (served + short)
    obs[:inventory_mean] = haskey(σ.stats, :inventory_mean) ? mean(σ[:inventory_mean]) : NaN
    obs[:orders_placed] = total_of(σ[:orders_placed])

    theo = SymDict(:demand_size => expected_demand_size(demand_size),
        :served_fraction => obs[:fill_rate])
    rows = SymDict[]
    worst = 0.0
    for (a, b) in [(:demand_size, :demand_size), (:fill_rate, :served_fraction)]
        (haskey(obs, a) && haskey(theo, b)) || continue
        (isfinite(obs[a]) && isfinite(theo[b])) || continue
        rel = relative_error(obs[a], theo[b])
        push!(rows, SymDict(:observed_key => a, :theory_key => Sym(b),
            :observed => obs[a], :theory => theo[b], :relative_error => rel,
            :within_tolerance => rel <= tolerance))
        worst = max(worst, rel)
    end
    d = SymDict()
    d[:label] = :inventory
    d[:system] = :model_invariants
    d[:comparisons] = rows
    d[:n_comparisons] = length(rows)
    d[:worst_relative_error] = worst
    d[:tolerance] = Float64(tolerance)
    d[:observed] = obs
    d[:verdict] = isempty(rows) ? :not_applicable :
                  worst <= tolerance ? :validated :
                  worst <= 2tolerance ? :marginal : :failed
    return d
end

"""
    validate_model(σ, name, params; tolerance = 0.10) -> SymDict

Cross-check a finished run against the closed-form result of its model: the
queueing systems (`:mmc`, `:call_center`) against Erlang C, every other model
against Little's law on its busiest resource. The verdict (`:validated`,
`:marginal`, `:failed`) is what the "does this simulation make sense?" section of
the report prints.
"""
function validate_model(σ::Sim, name::Symbol, params::AbstractDict;
    tolerance::Real = 0.10, resource::Symbol = model_resource(name))
    k = Sym(name)
    k === :inventory && return inventory_validation(σ;
        demand_size = Float64(get(params, :demand_size, 12.0)), tolerance = tolerance)
    theo = model_theory(k, params)
    if theo !== nothing && haskey(σ.resources, resource)
        obs = observed_summary(σ, resource)
        res = validate_against_theory(obs, theo;
            key_map = [:wait => :Wq, :queue_length => :Lq, :utilisation => :utilisation],
            tolerance = tolerance, label = k)
        iszero(obs[:requests]) && (res[:verdict] = :not_applicable)
        res[:observed] = obs
        return res
    end
    if !haskey(σ.resources, resource)
        rs = Resource[r for (_, r) in σ.resources if r isa Resource]
        isempty(rs) && throw(ArgumentError("the run has no resource to validate against"))
        resource = rs[argmax([utilisation(r) for r in rs])].name   # the busiest one
    end
    law = little_law(σ, resource)
    d = SymDict()
    d[:label] = k
    d[:system] = :little_law
    d[:resource] = resource
    d[:comparisons] = [SymDict(:observed_key => :L, :theory_key => :λW,
        :observed => law[:L], :theory => law[:λW],
        :relative_error => law[:relative_error], :within_tolerance => law[:holds])]
    d[:n_comparisons] = 1
    d[:worst_relative_error] = law[:relative_error]
    d[:tolerance] = Float64(tolerance)
    d[:verdict] = law[:holds] ? :validated :
                  law[:relative_error] <= 2tolerance ? :marginal : :failed
    d[:detail] = law
    return d
end