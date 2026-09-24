# test_analytical.jl -- the formulas, and the engine against them.
@testset "queueing formulas" begin
    m1 = theory(:mm1; λ = 0.8, μ = 1.0)
    @test m1[:rho] ≈ 0.8
    @test m1[:Lq] ≈ 3.2
    @test m1[:Wq] ≈ 4.0
    @test m1[:W] ≈ 5.0
    @test m1[:L] ≈ 4.0
    @test m1[:P0] ≈ 0.2
    @test m1[:utilisation] ≈ 0.8
    @test !m1[:approximate]
    @test_throws ArgumentError theory(:mm1; λ = 1.0, μ = 1.0)     # ρ = 1 has no steady state
    @test_throws ArgumentError theory(:nonsense; λ = 0.5)
    @test_throws ArgumentError theory(:mmc; λ = 2.5, μ = 1.0, c = 2)
    @test_throws ArgumentError theory(:mm1k; λ = 0.5, μ = 1.0, K = 0)

    ## Erlang B and C
    @test erlang_b(1.0, 1) ≈ 0.5
    @test erlang_b(2.0, 2) ≈ 0.4
    @test erlang_b(0.0, 3) == 0.0
    @test erlang_c(0.8, 1) ≈ 0.8                            # one server: Pw = ρ
    @test 0.0 < erlang_c(1.6, 2) < 1.0
    @test erlang_c(2.5, 2) == 1.0                           # ρ > 1: everybody waits
    mmc = theory(:mmc; λ = 1.6, μ = 1.0, c = 2)
    @test mmc[:pw] ≈ erlang_c(1.6, 2)
    @test mmc[:Lq] ≈ mmc[:pw] * mmc[:rho] / (1 - mmc[:rho])
    @test mmc[:W] ≈ mmc[:Wq] + 1.0
    @test mmc[:L] ≈ 1.6 * mmc[:W]
    @test mmc[:P0] > 0

    ## the other families
    @test theory(:md1; λ = 0.8, μ = 1.0)[:Wq] ≈ 2.0         # half of M/M/1
    @test theory(:mg1; λ = 0.8, μ = 1.0, cs2 = 1.0)[:Wq] ≈ theory(:mm1; λ = 0.8, μ = 1.0)[:Wq]
    @test theory(:mg1; λ = 0.8, μ = 1.0, cs2 = 0.0)[:Wq] ≈ 2.0
    gg1 = theory(:gg1_approx; λ = 0.8, μ = 1.0, ca2 = 0.5, cs2 = 0.5)
    @test gg1[:approximate]
    @test gg1[:Wq] < theory(:mm1; λ = 0.8, μ = 1.0)[:Wq]

    ## finite capacity converges to the infinite one as K grows
    @test theory(:mm1k; λ = 0.8, μ = 1.0, K = 60)[:Lq] ≈ m1[:Lq] rtol = 0.01
    @test theory(:mmck; λ = 1.6, μ = 1.0, c = 2, K = 80)[:Wq] ≈ mmc[:Wq] rtol = 0.01
    @test theory(:mm1k; λ = 0.8, μ = 1.0, K = 2)[:loss] > 0
    @test theory(:mmcc; λ = 1.6, μ = 1.0, c = 2)[:blocking] ≈ erlang_b(1.6, 2)
    @test theory(:mmcc; λ = 1.6, μ = 1.0, c = 2)[:Lq] == 0.0
    @test theoretical_utilisation(0.8, 1.0, 2) ≈ 0.4
end

@testset "the engine against theory" begin
    ## M/M/1: one long run is close, replications are honest
    function mm1_run(seed; horizon = 8000.0, λ = 0.8, μ = 1.0)
        σ = Sim(:mm1; seed = seed, horizon = horizon)
        server = resource!(σ, Resource(:server))
        in_system = statistic!(σ, :in_system, TimeWeighted(:in_system))
        spawn!(σ, () -> begin
            while σ.now <= horizon
                hold!(σ, exp_rv(σ, :interarrival, λ))
                σ.now > horizon && break
                spawn!(σ, () -> begin
                    t0 = σ.now
                    request!(σ, server)
                    observe!(in_system, σ, in_system.value + 1)
                    hold!(σ, exp_rv(σ, :service, μ))
                    release!(σ, server)
                    observe!(in_system, σ, in_system.value - 1)
                    tally!(σ, :sojourn, σ.now - t0)
                    return nothing
                end; name = :customer)
            end
            return nothing
        end; name = :arrivals)
        run!(σ)
        return σ
    end

    single = mm1_run(20260101)
    observed = observed_summary(single, :server)
    theoretical = theory(:mm1; λ = 0.8, μ = 1.0)
    @test observed[:utilisation] ≈ theoretical[:rho] atol = 0.02
    @test observed[:wait] ≈ theoretical[:Wq] rtol = 0.25       # one run is autocorrelated
    @test observed[:queue_length] ≈ theoretical[:Lq] rtol = 0.30
    @test little_law(single, :server)[:relative_error] < 0.05

    ## the same run twice is the same run (the seed is the whole story)
    again = mm1_run(20260101)
    @test observed_summary(again, :server)[:wait] == observed[:wait]
    other = mm1_run(7)
    @test observed_summary(other, :server)[:wait] != observed[:wait]

    ## replications cover the theory
    waits = Float64[]
    utilisations = Float64[]
    for seed in 1:10
        r = mm1_run(seed; horizon = 3000.0)
        obs = observed_summary(r, :server)
        push!(waits, obs[:wait])
        push!(utilisations, obs[:utilisation])
    end
    wait_ci = mean_ci(waits)
    @test wait_ci[:lo] <= theoretical[:Wq] <= wait_ci[:hi]
    @test mean_ci(utilisations)[:lo] <= theoretical[:rho] <= mean_ci(utilisations)[:hi]

    ## M/M/c against Erlang C
    function mmc_run(seed; horizon = 6000.0, λ = 1.6, μ = 0.5, c = 4)
        σ = Sim(:mmc; seed = seed, horizon = horizon)
        pool = resource!(σ, Resource(:server; capacity = c))
        spawn!(σ, () -> begin
            while σ.now <= horizon
                hold!(σ, exp_rv(σ, :interarrival, λ))
                σ.now > horizon && break
                spawn!(σ, () -> use!(σ, pool, exp_rv(σ, :service, μ)); name = :customer)
            end
            return nothing
        end; name = :arrivals)
        run!(σ)
        return observed_summary(σ, :server)
    end
    c_obs = mmc_run(3)
    c_theory = theory(:mmc; λ = 1.6, μ = 0.5, c = 4)
    @test c_obs[:utilisation] ≈ c_theory[:rho] atol = 0.03
    @test c_obs[:wait] ≈ c_theory[:Wq] rtol = 0.35
    check = validate_against_theory(c_obs, c_theory;
        key_map = [:utilisation => :utilisation, :wait => :Wq], tolerance = 0.35)
    @test check[:verdict] in (:validated, :marginal)
    @test check[:n_comparisons] == 2
    @test length(check[:comparisons]) == 2
    @test all(c -> c[:within_tolerance], check[:comparisons])
end

@testset "the textbook cases" begin
    ## M/D/1 is faster than M/M/1 at the same load
    @test theory(:md1; λ = 0.8, μ = 1.0)[:Wq] < theory(:mm1; λ = 0.8, μ = 1.0)[:Wq]
    ## more servers, less waiting, at the same offered load
    wq = [theory(:mmc; λ = 1.6, μ = 1.0, c = c)[:Wq] for c in 2:6]
    @test issorted(wq; rev = true)
    ## an M/M/1/K system rejects work and never exceeds K
    k = theory(:mm1k; λ = 1.2, μ = 1.0, K = 4)
    @test k[:loss] > 0
    @test k[:L] < 4.0
    @test k[:λ_eff] < 1.2
end
