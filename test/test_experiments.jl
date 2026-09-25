# test_experiments.jl -- replications, intervals, sweeps and comparisons.
@testset "experiment design" begin
    cfg = ExperimentConfig(replications = 4, horizon = 2000.0, warmup = 200.0, seed = 5)
    @test cfg.replications == 4 && cfg.level == 0.95
    @test ExperimentConfig(SymDict(:replications => 2, :nonsense => 1)).replications == 2
    @test seed_for(1000, 1) != seed_for(1000, 2)
    @test seed_for(1000, 1) == seed_for(1000, 1)

    opts = run_options(cfg, 3; scenario = :baseline, params = SymDict(:servers => 2))
    @test opts[:replication] == 3
    @test opts[:seed] == seed_for(5, 3)
    @test opts[:horizon] == 2000.0
    @test opts[:scenario] === :baseline
    @test opts[:params][:servers] == 2

    params = model_params(:mmc)
    res = experiment(opts -> build_model(:mmc, params, opts), cfg; name = :check)
    @test res isa ExperimentResult
    @test res.name === :check
    @test res.kind === :replications
    @test length(res.per_replication) == 4
    @test length(metric_keys(res)) >= 5
    @test metric_value(res, :throughput) > 0
    @test isnan(metric_value(res, :nonsense_metric))
    @test metric_ci(res, :nonsense_metric) === nothing
    @test length(metric_series(res, :throughput)) == 4
    ci = metric_ci(res, :wait_mean)
    @test ci[:n] == 4 && ci[:adequate]
    table = metric_table(res)
    @test !isempty(table)
    @test table[1].metric in metric_keys(res)
    @test length(replications_table(res)) == 4
    @test occursin(":check", describe_experiment(res))
    @test res.sample isa Sim                       # the first run is kept for figures
    @test collect_metrics(res.sample)[:utilisation] > 0
end

@testset "warmup and batch means" begin
    cfg = ExperimentConfig(replications = 3, horizon = 3000.0, warmup = 0.0)
    wu = warmup_analysis(opts -> build_model(:mmc, model_params(:mmc,
            (arrival_rate = 0.85, servers = 1)), opts), cfg; series = :wip, window = 12)
    @test haskey(wu, :warmup)
    @test wu[:warmup] >= 0.0
    @test length(wu[:times]) == length(wu[:averaged]) == length(wu[:smoothed])
    @test wu[:plateau] > 0
    @test wu[:band] >= 0
    @test wu[:replications] == 3

    ## a series without the recorder it needs is reported, not fatal
    no_series = warmup_analysis(opts -> build_model(:inventory,
            default_params(:inventory), opts), cfg; series = :nonexistent)
    @test no_series[:warmup] == 0.0
    @test isnan(no_series[:plateau]) && isnan(no_series[:band])   # every key is there

    ## a series that is *pinned* (a WIP cap) is flat: the band must not be so narrow
    ## that a flat series is called "never settles" -- the floor on the band is what
    ## keeps the plateau test from becoming a knife edge
    capped = warmup_analysis(opts -> build_model(:machine_shop,
            model_params(:machine_shop, (arrival_rate = 0.6, wip_limit = 6)), opts),
        ExperimentConfig(replications = 2, horizon = 3000.0, warmup = 0.0, seed = 7);
        series = :wip, window = 20)
    @test capped[:plateau] <= 7.0                     # the shop sits at its WIP cap
    @test capped[:band] >= 0.5 * capped[:spread]      # the floor only widens the band
    @test capped[:band] > 0.0

    ## the shop the study calibrates: a WIP that wanders more than its own band is
    ## reported as such -- the suggestion is a number, and the section says in words
    ## that the diagnostic could not settle the series
    shop = warmup_analysis(opts -> build_model(:machine_shop,
            model_params_from_calibration(calibrate(generate_history(; seed = 20260101,
                days = 45.0)), :machine_shop), opts),
        ExperimentConfig(replications = 2, horizon = 4000.0, warmup = 0.0, seed = 20260101);
        series = :wip, window = 20)
    @test 0.0 <= shop[:warmup] <= 4000.0
    @test shop[:plateau] > 5.0                        # the shop works on about a dozen jobs
    late = shop[:warmup] > 0.5 * 4000.0
    if late
        section = preview_section(SymDict(:warmup => shop,
            :config => SymDict(:horizon => 4000.0)), :experiments)
        @test occursin("could not find a plateau", section)
        @test occursin("design decision, not a measurement", section)
    end

    bm = batch_means(rand(StableRNGs.StableRNG(4), 2000); batches = 20)
    @test bm[:batches] == 20
    @test bm[:half_width] > 0
    @test bm[:lo] < bm[:mean] < bm[:hi]
    @test bm[:adequate]
    @test -1.0 <= bm[:lag1] <= 1.0
    @test isnan(batch_means([1.0, 2.0])[:half_width])

    ## interpolating a series onto a grid does what the warmup analysis needs
    grid = collect(0.0:0.5:5.0)
    plain = interpolate_series([0.0, 1.0, 2.0], [0.0, 2.0, 4.0], grid)
    @test plain[1] == 0.0
    @test plain[3] ≈ 2.0                       # the grid point 1.0 is halfway
    @test isnan(plain[end])
end

@testset "sweeps, comparisons and factorial designs" begin
    base = model_params(:mmc)
    cfg = ExperimentConfig(replications = 4, horizon = 2000.0, warmup = 200.0, seed = 9)
    sw = sweep((v, opts) -> build_model(:mmc, model_params(base, (servers = v,)), opts),
        :servers, [1, 2, 3], cfg; objective = :wait_mean)
    @test sw[:param] === :servers
    @test sw[:values] == [1, 2, 3]
    @test sw[:objective] === :wait_mean
    @test sw[:direction] === :min
    @test length(sw[:results]) == 3
    @test length(sweep_rows(sw)) == 3
    @test sw[:best_value] == 3                       # more servers, less waiting
    @test sw[:means][1] > sw[:means][2] > sw[:means][3]
    @test haskey(sw[:rows][1], :throughput_mean)
    @test_throws ArgumentError sweep((v, opts) -> nothing, :x, Float64[], cfg)

    cmp = compare_scenarios([
            :baseline => (opts -> build_scenario(:mmc, :baseline, opts)),
            :capacity_up => (opts -> build_scenario(:mmc, :capacity_up, opts)),
            :demand_up => (opts -> build_scenario(:mmc, :demand_up, opts))],
        cfg; objective = :wait_mean)
    @test cmp[:baseline] === :baseline
    @test cmp[:order] == [:baseline, :capacity_up, :demand_up]
    @test cmp[:best] in (:baseline, :capacity_up, :demand_up)
    wait_rows = [c for c in cmp[:comparisons] if c[:metric] === :wait_mean]
    @test length(wait_rows) == 2
    capacity = first(filter(c -> c[:label] === :capacity_up, wait_rows))
    @test capacity[:verdict] === :better             # more servers help
    @test capacity[:difference] < 0
    @test capacity[:half_width] > 0
    @test capacity[:variance_reduction] > -1.0
    demand = first(filter(c -> c[:label] === :demand_up, wait_rows))
    @test demand[:verdict] === :worse
    @test haskey(cmp[:verdicts][:capacity_up], :wait_mean)

    ## a design compared with itself is indistinguishable
    same = paired_comparison(cmp[:results][:baseline], cmp[:results][:baseline], :wait_mean)
    @test same[:verdict] === :indistinguishable
    @test same[:difference] == 0.0

    fd = factorial_design((levels, opts) -> build_model(:mmc,
            model_params(base, (servers = Int(levels[:servers]),
                arrival_rate = Float64(levels[:arrival_rate]))), opts),
        [:servers, :arrival_rate],
        Dict(:servers => (1, 3), :arrival_rate => (0.6, 0.9)), cfg;
        objective = :wait_mean)
    rows = factorial_rows(fd)
    @test length(rows) == 3                          # two main effects and one interaction
    servers_effect = rows[1]
    @test servers_effect[:term] === :servers
    @test servers_effect[:effect] < 0                # servers reduce the wait
    @test servers_effect[:verdict] === :helps
    arrival_effect = rows[2]
    @test arrival_effect[:term] === :arrival_rate
    @test arrival_effect[:verdict] === :hurts        # more demand increases it
    @test rows[3][:term] === Symbol(:servers, :x, :arrival_rate)
    @test haskey(fd, :corners)
    @test length(fd[:results]) == 4
end