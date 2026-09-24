# test_online.jl -- the offline-first data layer and the periodic reevaluation.
@testset "reading the feed" begin
    dir = joinpath(TEST_TMP, "online")
    mkpath(dir)
    h = generate_history(; seed = 20_260_101, days = 5.0)
    feed_path = joinpath(dir, "online_feed.json")
    write_online_feed(h, feed_path; exported_at = timestamp())
    @test isfile(feed_path)

    payload = JSON3.read(read(feed_path, String))
    @test haskey(payload, :observations)
    observations = parse_observations(payload)
    @test observations isa SymDict
    @test haskey(observations, :service)
    @test length(observations[:service]) ==
          length(history_series(h, :service)[1:min(end, 4000)])
    @test parse_observations(nothing) === nothing
    @test parse_observations(SymDict(:nonsense => 1)) === nothing
    @test parse_observations(SymDict(:service => [1.0, 2.0]))[:service] == [1.0, 2.0]

    ## the online source, when it is really there (a file:// URL is the online path)
    cfg_online = OnlineConfig(url = "file:///" * replace(feed_path, "\\" => "/"),
        local_file = feed_path, cache_dir = joinpath(dir, "cache"))
    online = fetch_online(cfg_online)
    @test online[:status] === :ok
    @test online[:source] === :online
    @test online[:freshness] === :fresh
    @test online[:attempts] == 1
    @test haskey(online[:observations], :interarrival)
    @test isfile(cache_path(cfg_online))

    ## an unreachable source falls back to the local copy of the same feed
    cfg_blocked = OnlineConfig(url = "http://127.0.0.1:9/nothing", local_file = feed_path,
        cache_dir = joinpath(dir, "cache"), timeout = 1.0, retries = 0)
    blocked = fetch_online(cfg_blocked)
    @test blocked[:status] === :cached
    @test blocked[:source] === :offline_cache
    @test blocked[:fallback] === :local_file
    @test haskey(blocked[:observations], :service)

    ## nothing at all is offline, and never an error
    cfg_offline = OnlineConfig(url = "http://127.0.0.1:9/nothing",
        local_file = joinpath(dir, "missing.json"), cache_dir = joinpath(dir, "empty_cache"),
        timeout = 1.0, retries = 0)
    offline = fetch_online(cfg_offline)
    @test offline[:status] === :offline
    @test offline[:source] === :generated
    @test offline[:freshness] === :offline
    @test offline[:observations] === nothing
    @test offline[:payload] === nothing

    ## cache only never touches the network
    cfg_cache = OnlineConfig(url = "http://127.0.0.1:9/nothing", local_file = feed_path,
        cache_dir = joinpath(dir, "cache"), policy = :cache_only)
    cached = fetch_online(cfg_cache)
    @test cached[:status] === :cached
    @test cached[:attempts] == 0
    @test occursin("offline_cache", describe_feed(cached))

    ## a disabled source says so
    disabled = fetch_online(OnlineConfig(enabled = false))
    @test disabled[:status] === :disabled
    @test disabled[:source] === :generated

    ## the cache remembers what was fetched, with its age
    write_cache(cfg_blocked, SymDict(:observations => SymDict(:service => [1.0])),
        "2026-01-01T00:00:00")
    fresh = fetch_online(OnlineConfig(url = "http://127.0.0.1:9/nothing",
        local_file = joinpath(dir, "missing.json"), cache_dir = joinpath(dir, "cache"),
        timeout = 1.0, retries = 0), name = "feed.json",
        now = "2026-01-02T00:00:00")
    @test fresh[:status] === :cached
    @test fresh[:age_days] ≈ 1.0 atol = 0.01
    @test fresh[:freshness] === :fresh
    @test fetch_online(OnlineConfig(cache_dir = joinpath(dir, "cache"), policy = :cache_only),
        name = "feed.json", now = "2026-03-01T00:00:00")[:freshness] === :expired
    @test freshness_of(NaN, cfg_blocked) === :unknown
    @test freshness_of(0.5, cfg_blocked) === :fresh
    @test freshness_of(30.0, cfg_blocked) === :expired
    @test seconds_between("2026-01-01T00:00:00", "2026-01-02T00:00:00") ≈ 86_400.0
    @test isnan(seconds_between("nonsense", "2026-01-02T00:00:00"))
    @test is_local_source("file:///x.json")
    @test !is_local_source("https://example.org/x.json")
    @test endswith(source_path("file:///c:/x.json"), "x.json")
    @test timestamp(DateTime(2026, 1, 2, 3, 4, 5)) == "2026-01-02T03:04:05"
end

@testset "reevaluation" begin
    dir = joinpath(TEST_TMP, "reevaluation")
    mkpath(dir)
    h = generate_history(; seed = 20_260_101, days = 20.0)
    cal = calibrate(h)
    feed_path = joinpath(dir, "online_feed.json")
    write_online_feed(h, feed_path)
    log_path = joinpath(dir, "reevaluation_log.json")
    cfg = OnlineConfig(url = "file:///" * replace(feed_path, "\\" => "/"),
        local_file = feed_path, cache_dir = joinpath(dir, "cache"))

    ## the same observations as the model was built from: keep
    record = reevaluate(cal; history = h, cfg = cfg, model = :mmc,
        plan = ReevaluationPlan(7, :days), log_path = log_path)
    @test record[:verdict] === :keep
    @test record[:reason] === :within_threshold
    @test record[:source] === :online
    @test record[:status] === :ok
    @test record[:model] === :mmc
    @test record[:plan] == "every 7 days"
    @test !isempty(record[:comparisons])
    @test !isempty(record[:ks])
    @test all(r -> abs(r[:relative_change]) < 0.10, record[:comparisons])
    @test all(kv -> kv[2][:same_process], record[:ks])
    @test haskey(record[:observations], :service)
    @test record[:payload_bytes] > 0
    @test isfile(log_path)
    @test length(reevaluation_log(log_path)) == 1
    @test last_reevaluation(log_path)[:at] == record[:at]

    ## observations from another process: recalibrate
    shifted_history = generate_history(; seed = 777, days = 20.0, base_rate = 1.5)
    write_online_feed(shifted_history, feed_path)
    moved = reevaluate(cal; history = h, cfg = cfg, model = :mmc, log_path = log_path)
    @test moved[:verdict] === :recalibrate
    @test moved[:reason] in (:parameter_moved, :sample_shifted)
    @test moved[:worst_change] > 0
    @test length(reevaluation_log(log_path)) == 2

    ## nothing reachable: escalate, and the log records why
    offline_cfg = OnlineConfig(url = "http://127.0.0.1:9/nothing",
        local_file = joinpath(dir, "missing.json"), cache_dir = joinpath(dir, "empty"),
        timeout = 1.0, retries = 0)
    offline = reevaluate(cal; history = h, cfg = offline_cfg, model = :mmc,
        log_path = log_path)
    @test offline[:verdict] === :escalate
    @test offline[:reason] === :no_observations_and_stale_source
    @test offline[:status] === :offline
    @test isempty(offline[:comparisons])
    @test length(reevaluation_log(log_path)) == 3

    ## the log row and the plan helpers
    row = feed_row(record)
    @test row.source === :online
    @test row.verdict === :keep
    @test row.observations > 0
    @test plan_days(ReevaluationPlan(1, :days)) == 1
    @test plan_days(ReevaluationPlan(2, :weeks)) == 14
    @test plan_days(ReevaluationPlan(1, :months)) == 30
    @test describe_plan(ReevaluationPlan(3, :days)) == "every 3 days"
    @test !due(ReevaluationPlan(7, :days), timestamp(), timestamp())
    @test due(ReevaluationPlan(7, :days), timestamp(Dates.now() - Dates.Day(9)), timestamp())
    @test due(ReevaluationPlan(7, :days), "nonsense", timestamp())

    ## jsonable survives a simulation, a process and a task
    σ = build_model(:mmc, model_params(:mmc), SymDict(:seed => 1, :horizon => 100.0,
        :trace => true))
    run!(σ)
    payload = jsonable(SymDict(:run => σ, :process => first(values(σ.processes)),
        :nan => NaN, :inf => Inf))
    @test payload["run"] isa Dict
    @test payload["run"]["name"] == "mmc"
    @test payload["run"]["events"] > 0
    @test payload["process"] isa Dict
    @test payload["nan"] === nothing
    @test payload["inf"] === nothing
    @test jsonable(:wait) == "wait"
    @test jsonable((a = 1,))["a"] == 1
end