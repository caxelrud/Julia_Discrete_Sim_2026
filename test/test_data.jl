# test_data.jl -- the plant history and the calibration.
@testset "history" begin
    h = generate_history(; seed = 20_260_101, days = 10.0, base_rate = 0.8)
    @test h isa PlantHistory
    @test h.name === :plant
    @test h.seed == 20_260_101
    @test h.days == 10.0
    @test history_keys(h) == [:interarrival, :service, :failure_interval, :repair,
        :demand_size]
    gaps = history_series(h, :interarrival)
    services = history_series(h, :service)
    @test length(gaps) > 100
    @test length(services) > 50
    @test all(>(0.0), gaps) && all(>(0.0), services)
    @test h.counts[:arrivals] == length(gaps)
    @test h.meta[:days] == 10.0
    @test count(x -> x > 0, history_series(h, :failure_interval)) > 5
    @test history_series(h, :nonsense) == Float64[]

    summary_rows = summarize_history(h)
    @test length(summary_rows) == 5
    row = first(filter(r -> r[:series] === :service, summary_rows))
    @test row[:n] == length(services)
    @test row[:mean] > 0 && row[:sd] > 0 && row[:cv] > 0
    @test row[:p50] < row[:p95] <= row[:max]
    @test abs(row[:lag1]) < 0.5                  # the generator has no autocorrelation

    ## the history is deterministic and the drift is really there
    h2 = generate_history(; seed = 20_260_101, days = 10.0, base_rate = 0.8)
    @test history_series(h2, :service) == services
    other = generate_history(; seed = 42, days = 10.0)
    @test history_series(other, :service) != services
    @test h.meta[:drift] > 0

    files = write_history_csv(h, TEST_TMP)
    @test length(files) == 5
    @test all(isfile, files)
    @test length(readlines(files[1])) > 1
    write_json_payload(joinpath(TEST_TMP, "history.json"), SymDict(:meta => h.meta))
    @test isfile(joinpath(TEST_TMP, "history.json"))
end

@testset "fitting" begin
    σ = Sim(:fitting; seed = 2026)
    exponential = sample_n(σ, :expo, :exponential => (1 / 3.0,), 4000)
    lognormal = sample_n(σ, :lognormal, :lognormal => (log(3.0), 0.5), 4000)
    weibull_sample = sample_n(σ, :weibull, :weibull => (2.0, 3.0), 4000)

    fit = fit_distribution(:exponential, exponential)
    @test fit[:kind] === :exponential
    @test fit[:mean] ≈ 3.0 rtol = 0.05
    @test fit[:fits]                                  # the right family is accepted
    @test fit[:ks_p] > 0.05
    @test isapprox(fit[:mean], fit[:sample_mean]; rtol = 0.05)
    @test fit[:n] == 4000

    wrong = fit_distribution(:lognormal, exponential)
    @test wrong[:ks_stat] > fit[:ks_stat]
    @test fit_distribution(:normal, exponential)[:kind] === :normal
    @test fit_distribution(:uniform, exponential)[:kind] === :uniform
    @test fit_distribution(:triangular, exponential)[:kind] === :triangular
    @test fit_distribution(:gamma, exponential)[:kind] === :gamma
    @test fit_distribution(:weibull, weibull_sample)[:mean] ≈ 3.0 * 0.886 rtol = 0.1
    @test fit_distribution(:empirical, exponential)[:kind] === :empirical
    @test_throws ArgumentError fit_distribution(:nonsense, exponential)
    @test_throws ArgumentError fit_distribution(:normal, [1.0, 2.0])

    ## the fitted record is the same object `dist` reads back
    @test mean(dist(fit)) ≈ fit[:mean]
    @test std(dist(fit)) ≈ fit[:sd]

    ## best_fit picks the family the sample really came from
    chosen = best_fit(lognormal)
    @test chosen[:kind] in (:lognormal, :gamma, :weibull)
    @test first(filter(kv -> kv[2][:rank] == 1, chosen[:ranking]))[1] === chosen[:kind]
    @test length(chosen[:candidates]) == 5

    interval = bootstrap_ci(lognormal, :lognormal, 1; reps = 40)
    @test interval[:lo] <= interval[:median] <= interval[:hi]
end

@testset "calibration" begin
    h = generate_history(; seed = 20_260_101, days = 30.0, base_rate = 0.8,
        service_mean = 1.2, failure_mtbf = 180.0)
    cal = calibrate(h)
    @test cal[:source] === :generated
    @test cal[:history] === :plant
    for key in (:interarrival, :service, :failure_interval, :repair, :demand_size)
        @test haskey(cal, key)
        @test cal[key][:kind] in DISTRIBUTION_KINDS
        @test cal[key][:params] isa Tuple
    end
    parameters = cal[:parameters]
    @test 0.6 < parameters[:arrival_rate] < 1.1            # the generator used 0.8 (drifting)
    @test 0.7 < parameters[:service_rate] < 1.0            # mean 1.2 minutes
    @test 130 < parameters[:mtbf] < 240
    @test 7 < parameters[:mttr] < 15
    @test 0.9 < parameters[:availability] < 1.0
    @test parameters[:arrival_cv2] > 0
    @test parameters[:service][:kind] in DISTRIBUTION_KINDS

    table = calibration_table(cal)
    @test length(table) == 5
    @test table[1].series in history_keys(h)

    ## the calibration reaches the model parameters
    mmc_params = model_params_from_calibration(cal, :mmc)
    @test mmc_params[:arrival_rate] == parameters[:arrival_rate]
    @test mmc_params[:servers] == default_params(:mmc)[:servers]
    shop_params = model_params_from_calibration(cal, :machine_shop)
    @test shop_params[:mtbf] == parameters[:mtbf]
    ## ... including the shop's processing times, which are *scaled* to the plant: the
    ## work content of an average job is the service time the plant measured, so the
    ## arrival rate and the cycles belong to the same plant
    @test default_work_content(shop_params) ≈ cal[:service][:mean] rtol = 1e-6
    @test default_work_content(default_params(:machine_shop)) > 10.0
    @test default_work_content(SymDict()) == 0.0
    inventory_params = model_params_from_calibration(cal, :inventory)
    @test inventory_params[:demand_size] == parameters[:demand_mean]

    ## observations from elsewhere calibrate the same way
    remote = calibrate_observations(SymDict(:service => history_series(h, :service)),
        source = :online)
    @test remote[:source] === :online
    @test haskey(remote[:parameters], :service_rate)

    ## the Kolmogorov statistic and its p-value behave
    @test kolmogorov_q(0.0) == 1.0
    @test kolmogorov_q(0.3) > 0.99
    @test kolmogorov_q(1.5) < 0.05
    @test 0.0 <= kolmogorov_q(0.77) <= 1.0
    test = two_sample_ks(history_series(h, :service), history_series(h, :service))
    @test test[:stat] ≈ 0.0 atol = 1e-9
    @test test[:p] > 0.9
    shifted = two_sample_ks(history_series(h, :service),
        history_series(h, :service) .* 1.5)
    @test shifted[:p] < 0.01
    @test isnan(two_sample_ks(Float64[], [1.0, 2.0])[:p])

    ## the demand generator is what the model expected
    @test expected_demand_size(12.0) ≈ 13.28 rtol = 0.05
end