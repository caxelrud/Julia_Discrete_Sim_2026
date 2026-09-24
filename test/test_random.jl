# test_random.jl -- named streams and the distribution vocabulary.
@testset "streams" begin
    σ = Sim(:streams; seed = 11)
    a = [rand_stream(σ, :arrivals) for _ in 1:5]
    @test all(0 .<= a .< 1)
    @test length(unique(a)) == 5
    @test stream!(σ, :arrivals).draws == 5
    @test stream_seed(1, :a) == stream_seed(1, :a)          # deterministic
    @test stream_seed(1, :a) != stream_seed(1, :b)          # name matters
    @test stream_seed(1, :a) != stream_seed(2, :a)          # seed matters
    @test 0 <= stream_seed(20_260_101, :service) < 2^53

    ## the same seed reproduces a whole stream; a different name does not
    σ2 = Sim(:streams; seed = 11)
    @test [rand_stream(σ2, :arrivals) for _ in 1:5] == a
    σ3 = Sim(:streams; seed = 11)
    b = [rand_stream(σ3, :service) for _ in 1:5]
    @test b != a

    ## common random numbers: the same replication of two designs draws the same
    σ4 = Sim(:design_a; seed = seed_for(1000, 3))
    σ5 = Sim(:design_b; seed = seed_for(1000, 3))
    @test [rand_stream(σ4, :service) for _ in 1:3] == [rand_stream(σ5, :service) for _ in 1:3]
    σ6 = Sim(:design_c; seed = seed_for(1000, 4))
    @test [rand_stream(σ6, :service) for _ in 1:3] != [rand_stream(σ4, :service) for _ in 1:3]

    ## antithetic streams turn u into 1 - u
    σ7 = Sim(:anti; seed = 21)
    plain = [rand_stream(σ7, :x) for _ in 1:4]
    σ8 = Sim(:anti; seed = 21)
    antithetic!(σ8, [:x])
    @test [rand_stream(σ8, :x) for _ in 1:4] ≈ 1 .- plain
    σ9 = Sim(:anti; seed = 22)
    antithetic!(σ9)
    @test rand_stream(σ9, :anything) > 0.0

    ## indices and booleans
    σ10 = Sim(:misc; seed = 5)
    @test all(1 .<= [rand_index(σ10, :i, 4) for _ in 1:50] .<= 4)
    @test rand_index(σ10, :i, 1) == 1
    truth = [rand_bool(σ10, :coin, 0.5) for _ in 1:200]
    @test 60 < count(truth) < 140
    rows = streams_table(σ10)
    @test !isempty(rows) && rows[1][:draws] > 0
end

@testset "distributions" begin
    @test mean(dist(:exponential, 2.0)) ≈ 0.5            # the parameter is a rate
    @test mean(dist(:deterministic, 3.0)) == 3.0
    @test std(dist(:deterministic, 3.0)) == 0.0
    @test dist(:constant, 1.0).value == 1.0
    @test mean(dist(:normal, 2.0, 3.0)) == 2.0
    @test mean(dist(:uniform, 0.0, 2.0)) == 1.0
    @test mean(dist(:triangular, 0.0, 2.0, 1.0)) ≈ 1.0
    @test mean(dist(:gamma, 2.0, 3.0)) ≈ 6.0
    @test mean(dist(:weibull, 2.0, 3.0)) > 0
    @test mean(dist(:erlang, 3, 2.0)) ≈ 1.5
    @test mean(dist(:lognormal, 0.0, 1.0)) ≈ exp(0.5)
    @test mean(dist(:poisson, 4.0)) ≈ 4.0

    spec = dist_spec(:lognormal, 1.0, 0.5)
    @test spec[:kind] === :lognormal && spec[:params] == (1.0, 0.5)
    @test mean(dist(spec)) ≈ mean(dist(:lognormal, 1.0, 0.5))
    @test mean(dist(:exponential => (2.0,))) ≈ 0.5
    @test mean(dist((kind = :normal, params = (0.0, 1.0)))) == 0.0
    desc = describe_dist(spec)
    @test desc[:kind] === :lognormal && desc[:mean] > 0 && desc[:cv] > 0
    @test mean_of(spec) ≈ desc[:mean]
    @test sd_of(spec) ≈ desc[:sd]
    @test cv_of(spec) ≈ desc[:cv]

    empirical = dist(:empirical, [1.0, 2.0, 3.0])
    @test 1.0 <= quantile(empirical, 0.5) <= 3.0
    weighted = dist(:discrete, [1.0, 2.0], [0.5, 0.5])
    @test 1.0 <= quantile(weighted, 0.9) <= 2.0
    @test quantile(dist(:categorical, [0.3, 0.7]), 0.9) == 2.0
    diceroll = dist(:empirical, [1.0, 2.0, 3.0], [1.0, 1.0, 1.0])
    @test mean(diceroll) ≈ 2.0
    @test_throws ArgumentError dist(:nonsense, 1.0)
    @test_throws ArgumentError dist(:normal, 1.0)        # needs two parameters

    ## sampling goes through the named streams, so it is reproducible
    σ = Sim(:sampling; seed = 3)
    draws = [sample_rv(σ, :service, :exponential => (1.0,)) for _ in 1:2000]
    @test 0.9 < mean(draws) < 1.1
    @test stream!(σ, :service).draws == 2000
    σ2 = Sim(:sampling; seed = 3)
    @test [sample_rv(σ2, :service, :exponential => (1.0,)) for _ in 1:5] == draws[1:5]

    @test exp_rv(σ2, :x, 1.0) > 0
    @test det_rv(σ2, :x, 7.0) == 7.0
    @test 0.5 <= unif_rv(σ2, :x, 0.5, 1.5) <= 1.5
    @test tri_rv(σ2, :x, 0.0, 2.0, 1.0) >= 0.0
    @test weibull_rv(σ2, :x, 2.0, 1.0) > 0
    @test gamma_rv(σ2, :x, 2.0, 1.0) > 0
    @test poisson_rv(σ2, :x, 3.0) >= 0
    @test norm_rv(σ2, :x, 0.0, 1.0) isa Float64
    @test log_normal_rv(σ2, :x, 0.0, 1.0) > 0
    @test empirical_rv(σ2, :x, [1.0, 2.0]) in (1.0, 2.0)
    @test discrete_rv(σ2, :x, [1.0, 0.0]) == 1.0
    @test sample_n(σ2, :x, :deterministic => (2.0,), 3) == [2.0, 2.0, 2.0]
    @test mean_of_rate(0.25) == 4.0
end