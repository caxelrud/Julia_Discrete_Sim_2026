# test_models.jl -- the five reference models.
@testset "the catalogue" begin
    @test length(MODELS) == 5
    @test model_names() == collect(MODELS)
    for name in MODELS
        c = catalogue(name)
        @test c.title isa Symbol
        @test c.entity in ENTITIES
        @test c.series isa Symbol
        @test !isempty(c.metrics)
        @test !isempty(c.params)
        @test model_entity(name) === c.entity
        @test model_resource(name) === c.resource
        @test model_series(name) === c.series
        p = default_params(name)
        @test all(haskey(p, k) for k in c.params)
        @test model_scenarios(name)[1] === :baseline
        for scenario in model_scenarios(name)
            applied = scenario_params(name, scenario)
            @test applied isa SymDict
            @test length(applied) == length(p)
        end
        @test_throws ArgumentError default_params(:nonsense)
        @test_throws ArgumentError scenario_params(name, :nonsense)
    end
    @test_throws ArgumentError build_model(:nonsense)
    @test_throws ArgumentError catalogue(:nonsense)

    ## an override is set however it is written down -- a Pair, a NamedTuple, a record
    ## or a tuple of those. A sweep passes `(param => value,)`, and silently ignoring
    ## it would make a sweep that varies nothing look like a flat response
    @test model_params(:mmc, :arrival_rate => 0.5)[:arrival_rate] == 0.5
    @test model_params(:mmc, (:arrival_rate => 0.5,))[:arrival_rate] == 0.5
    @test model_params(:mmc, [:arrival_rate => 0.5])[:arrival_rate] == 0.5
    @test model_params(:mmc, (arrival_rate = 0.5,))[:arrival_rate] == 0.5
    @test model_params(:mmc, SymDict(:arrival_rate => 0.5))[:arrival_rate] == 0.5
    @test model_params(:mmc, SymDict(:servers => 3), :arrival_rate => 0.4)[:servers] == 3
    @test model_params(model_params(:mmc), :arrival_rate => 0.2)[:arrival_rate] == 0.2
    @test model_params(:mmc, nothing)[:arrival_rate] == default_params(:mmc)[:arrival_rate]
    @test_throws ArgumentError model_params(:mmc, 0.5)

    ## the time unit of a model is what its rates are expressed in, and the models
    ## really do count in it (a rate labelled per minute must come from minutes)
    for name in MODELS
        @test model_time_unit(name) === time_unit(build_model(name, default_params(name),
            SymDict(:horizon => 50.0)))
    end
    @test model_time_unit(:inventory) === :days
    @test model_time_unit(:machine_shop) === :minutes
end

@testset "scenarios change one thing at a time" begin
    base = default_params(:mmc)
    @test scenario_params(:mmc, :baseline) == base
    up = scenario_params(:mmc, :capacity_up)
    @test up[:servers] == base[:servers] + 1
    @test up[:arrival_rate] == base[:arrival_rate]
    busy = scenario_params(:mmc, :demand_up)
    @test busy[:arrival_rate] ≈ 1.2 * base[:arrival_rate]
    @test busy[:servers] == base[:servers]

    ## overrides are applied to whatever baseline is given (the calibrated one)
    calibrated = model_params(:mmc, (arrival_rate = 0.5, servers = 3))
    applied = apply_scenario(calibrated, :mmc, :capacity_up)
    @test applied[:arrival_rate] == 0.5
    @test applied[:servers] == 4
    line = apply_scenario(default_params(:transfer_line), :transfer_line, :buffer_up)
    @test line[:buffers] == map(x -> x + 4, default_params(:transfer_line)[:buffers])
    reliable = apply_scenario(default_params(:machine_shop), :machine_shop, :reliability_up)
    @test reliable[:mtbf][:mill] ≈ 1.5 * default_params(:machine_shop)[:mtbf][:mill]

    ## a calibrated scenario builder keeps the calibration
    cal_holder = SymDict(:parameters => SymDict(:arrival_rate => 0.4, :service_rate => 0.9))
    σ = build_calibrated_scenario(cal_holder, :mmc, :baseline,
        SymDict(:seed => 1, :horizon => 100.0))
    @test σ isa Sim
    @test σ.scenario[:name] === :baseline
end

@testset "every model builds, records and validates" begin
    for name in (:mmc, :transfer_line, :machine_shop, :inventory, :call_center)
        params = default_params(name)
        horizon = name === :inventory ? 400.0 : 2000.0
        σ = build_model(name, params, SymDict(:seed => 2026, :horizon => horizon,
            :trace => true))
        @test σ isa Sim
        @test σ.name === name
        @test σ.config.horizon == horizon
        run!(σ)
        @test σ.processed > 0
        @test stop_reason(σ) in (:horizon, :empty_calendar)
        ## the statistics of the run are registered, and the counters counted
        @test haskey(σ.stats, :completed)
        @test haskey(σ.stats, :status)
        if name !== :inventory
            for key in (:wait, :sojourn, :service, :wip)
                @test haskey(σ.stats, key)
            end
        end
        @test σ[:completed] isa Counter
        metrics = collect_metrics(σ)
        @test metrics[:completed] > 0
        @test metrics[:span] > 0
        validation = validate_model(σ, name, params)
        @test validation[:verdict] in (:validated, :marginal, :not_applicable)
        @test haskey(validation, :worst_relative_error)
        @test isempty([p for (_, p) in σ.processes if p.state === :failed])
    end
end

@testset "model details" begin
    ## the M/M/c queue agrees with Erlang C through the whole framework
    params = model_params(:mmc, (arrival_rate = 1.6, service_rate = 0.5, servers = 4))
    σ = build_model(:mmc, params, SymDict(:seed => 1, :horizon => 4000.0))
    run!(σ)
    observed = observed_summary(σ, :server)
    expected = theory(:mmc; λ = 1.6, μ = 0.5, c = 4)
    @test observed[:utilisation] ≈ expected[:rho] atol = 0.05
    validation = validate_model(σ, :mmc, params)
    @test validation[:system] === :mmc
    @test validation[:n_comparisons] == 3

    ## the transfer line has buffers, and blocking shows up as lost throughput
    line = build_model(:transfer_line, default_params(:transfer_line),
        SymDict(:seed => 2026, :horizon => 3000.0))
    run!(line)
    @test haskey(line.resources, :buffer_1)
    @test line[:starved_time].count > 0
    @test total_of(line[:completed]) > 0
    @test wip_of(line) >= 0.0

    ## the job shop refuses work beyond its WIP limit, and records it
    shop_params = model_params(:machine_shop, (arrival_rate = 0.3, wip_limit = 10))
    shop = build_model(:machine_shop, shop_params, SymDict(:seed => 2026,
        :horizon => 2000.0))
    run!(shop)
    @test total_of(shop[:lost_orders]) > 0
    @test count_of(shop[:status], :refused) > 0
    @test total_of(shop[:reworked]) > 0
    @test shop[:tardiness].count > 0

    ## work in progress counts the *work*, not the machines: a job waiting for
    ## machine is work in progress exactly as much as a job being machined. The
    ## shop must therefore satisfy Little's law as a system -- WIP = throughput
    ## times cycle time -- and not report a WIP near the number of machines (5).
    σ = build_model(:machine_shop, model_params(:machine_shop),
        SymDict(:seed => 20260101, :horizon => 4000.0))
    warmup!(σ, 400.0)
    run!(σ)
    m = collect_metrics(σ)
    cycle = mean(σ[:sojourn])
    @test m[:wip_mean] > length(default_params(:machine_shop)[:machines])
    @test isapprox(m[:wip_mean], m[:throughput] * cycle; rtol = 0.05)
    @test m[:wip_mean] <= default_params(:machine_shop)[:wip_limit]

    ## a scalar MTBF/MTTR applies to every machine. The calibration produces scalars
    ## (one measurement of the plant for the whole shop), and a shop whose failures
    ## were silently switched off would report an availability of 1.0 and a
    ## "reliability up" scenario that changes nothing.
    scalar_shop = build_model(:machine_shop,
        model_params(:machine_shop, (mtbf = 100.0, mttr = 10.0, arrival_rate = 0.05)),
        SymDict(:seed => 3, :horizon => 3000.0))
    run!(scalar_shop)
    @test total_of(scalar_shop[:mill].breakdowns) > 0
    @test total_of(scalar_shop[:mill].repairs) > 0
    @test availability(scalar_shop[:mill]) < 1.0
    @test collect_metrics(scalar_shop)[:availability] < 0.99
    @test count_of(scalar_shop[:status], :interrupted) > 0

    ## the inventory model keeps its books
    inventory = build_model(:inventory, default_params(:inventory),
        SymDict(:seed => 2026, :horizon => 300.0))
    run!(inventory)
    @test inventory.metrics[:orders_placed] > 0
    @test 0.0 <= inventory.metrics[:fill_rate] <= 1.0
    @test inventory.metrics[:inventory_mean] > 0
    @test minimum(inventory.stats[:inventory].values) >= 0.0
    @test length(inventory.stats[:inventory].values) > 10

    ## the call centre abandons calls when callers run out of patience
    cc_params = model_params(:call_center, (patience = 0.5, agents = 2))
    cc = build_model(:call_center, cc_params, SymDict(:seed => 2026, :horizon => 2000.0))
    run!(cc)
    @test cc[:service_level].count > 0
    @test mean(cc[:abandoned_fraction]) > 0.0
    @test count_of(cc[:status], :abandoned) > 0
end
