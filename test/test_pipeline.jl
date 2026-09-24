# test_pipeline.jl -- the one call that produces everything.
@testset "configuration" begin
    cfg = PipelineConfig()
    @test cfg.seed == 20260101
    @test cfg.featured === :machine_shop
    @test cfg.models == collect(MODELS)
    @test path_of(cfg, :data) == joinpath(cfg.root, "data")
    @test endswith(path_of(cfg, :pdf), "pdf")
    @test_throws ArgumentError path_of(cfg, :nonsense)

    from_dict = PipelineConfig(SymDict(:seed => 7, :replications => 3, :days => 5.0,
        :nonsense => 1))
    @test from_dict.seed == 7
    @test from_dict.replications == 3
    @test from_dict.days == 5.0
    @test PipelineConfig(SymDict(:online => SymDict(:policy => :cache_only))).online.policy === :cache_only
    @test PipelineConfig(SymDict(:plan => SymDict(:every => 2, :unit => :weeks))).plan.every == 2

    experiment_cfg = study_experiment(cfg; replications = 2, horizon = 100.0)
    @test experiment_cfg.replications == 2
    @test experiment_cfg.horizon == 100.0
    record = config_record(cfg)
    @test record[:featured] === :machine_shop
    @test record[:seed] == 20260101
    @test haskey(record, :objective)
end

@testset "a small study, end to end" begin
    root = joinpath(TEST_TMP, "study")
    mkpath(root)
    cfg = PipelineConfig(root = root, seed = 20260101, days = 3.0, replications = 2,
        horizon = 800.0, warmup = 80.0, featured = :mmc, objective = :wait_mean,
        sweep_values = Float64[0.6, 0.8], warmup_replications = 2,
        models = [:mmc, :inventory, :transfer_line], figures = true, export_data = true,
        render_pdf = true, print_sections = false,
        online = OnlineConfig(enabled = false))

    bundle = run_study(cfg)
    @test bundle isa SymDict
    @test bundle[:model] === :mmc
    @test bundle[:history] isa PlantHistory
    @test bundle[:calibration][:parameters][:arrival_rate] > 0
    @test length(bundle[:models]) == 3
    @test bundle[:experiment] isa ExperimentResult
    @test metric_value(bundle[:experiment], :throughput) > 0
    ## a small study is measured over replications, so its cross-check is meaningful
    @test bundle[:validation][:verdict] in (:validated, :marginal, :not_applicable)
    @test bundle[:theory][:kind] === :mmc
    @test bundle[:observed][:utilisation] > 0
    @test bundle[:comparison][:order][1] === :baseline
    @test bundle[:sweep][:values] == [0.6, 0.8]
    @test bundle[:factorial][:objective] === :wait_mean
    @test bundle[:batch_means][:n] == 2
    @test bundle[:online][:verdict] in (:keep, :recalibrate, :escalate)
    @test count(f -> f !== nothing, values(bundle[:figures])) >= 3
    @test bundle[:run] isa Sim
    @test bundle[:elapsed_seconds] > 0

    ## the artefacts are on disk
    artifacts = bundle[:artifacts]
    @test all(isfile, artifacts[:data])
    @test all(isfile, artifacts[:figures])
    @test all(isfile, artifacts[:html])
    @test all(isfile, artifacts[:pdf])
    @test isfile(joinpath(root, "data", "analysis.json"))
    @test isfile(joinpath(root, "data", "manifest.json"))
    @test isfile(joinpath(root, "data", "online_feed.json"))
    @test isfile(joinpath(root, "data", "reevaluation_log.json"))
    @test isfile(joinpath(root, "reports", "pdf", "discrete_sim_report.pdf"))
    @test isfile(joinpath(root, "reports", "figures", "wip.png"))
    @test read(joinpath(root, "reports", "pdf", "discrete_sim_report.pdf"), 4) == b"%PDF"
    @test bundle[:manifest][:status] in (:ok, :attention)
    @test bundle[:manifest][:n_pdf] >= 1
    @test occursin("seed", sprint(report_manifest, bundle[:manifest]))

    ## the report prints every section it was asked for
    html = report_html(bundle)
    @test occursin("Overview", html)
    @test occursin("The engine", html)
    @test occursin("Calibration", html)
    @test occursin("Contents", html)
    @test occursin("data:image/png;base64", html)
    section = section_document(bundle, :overview)
    @test occursin("Overview", section)
    @test !occursin("Contents", section)
    @test occursin("overview", preview_section(bundle, :overview))
    @test_throws ArgumentError section_of(bundle, :nonsense)
end

@testset "loading a study back" begin
    root = joinpath(TEST_TMP, "study")
    @test_throws ArgumentError load_study(joinpath(TEST_TMP, "nowhere"))

    loaded = load_study(root)
    @test loaded[:loaded] === true
    @test loaded[:run] === nothing
    @test loaded[:model] === :mmc
    @test loaded[:config][:seed] == 20260101
    @test loaded[:history] isa AbstractDict
    @test loaded[:history][:summary] |> length == 5
    @test loaded[:calibration][:parameters][:arrival_rate] > 0
    @test loaded[:experiment] isa ExperimentResult
    @test metric_value(loaded[:experiment], :throughput) > 0
    @test metric_ci(loaded[:experiment], :wait_mean)[:n] == 2
    @test loaded[:models][:mmc] isa ExperimentResult
    @test loaded[:validation][:verdict] in (:validated, :marginal, :not_applicable)
    @test loaded[:comparison][:results][Symbol(:baseline)] isa ExperimentResult
    @test length(loaded[:sweep][:results]) == 2
    @test loaded[:factorial][:effects] |> length == 3
    @test loaded[:batch_means][:n] == 2
    @test loaded[:online][:verdict] in (:keep, :recalibrate, :escalate)
    @test !isempty(loaded[:figures])
    @test occursin("data:image/png", first(values(loaded[:figures]))[:uri])

    ## a loaded study prints the same report as the live one
    html = report_html(loaded)
    @test occursin("Overview", html)
    @test occursin("The models", html)
    @test occursin("data:image/png;base64", html)
    preview = preview_section(loaded, :overview)
    @test occursin("id=\"overview\"", preview)
    @test occursin("wait_mean", metrics_table_html(loaded[:experiment]))  # the metric key
    out = print_section_pdf(loaded, :overview; root = root, prefix = "loaded")
    @test isfile(out[:html])
    @test out[:printed]
    @test isfile(out[:pdf])
    @test read(out[:pdf], 4) == b"%PDF"
end