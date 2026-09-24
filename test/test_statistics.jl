# test_statistics.jl -- the collectors and the intervals.
@testset "Tally" begin
    t = Tally(:wait; keep = 1000)
    @test t.metric === :wait
    @test t.unit === :minutes                      # a waiting time is a duration
    @test t.count == 0 && isnan(mean(t)) && isnan(std(t)) && isnan(half_width(t))
    for x in 1.0:100.0
        tally_record!(t, x)
    end
    @test t.count == 100
    @test mean(t) ≈ 50.5
    @test std(t) ≈ std(1.0:100.0)
    @test var(t) ≈ var(1.0:100.0)
    @test extrema_of(t) == (1.0, 100.0)
    @test quantile(t, 0.5) ≈ 50.5 atol = 1.0
    @test half_width(t) > 0
    @test standard_error(t) > 0
    @test outlier_fence(t)[2] > 100.0
    s = summary_of(t)
    @test s[:kind] === :tally && s[:n] == 100 && s[:adequate]
    @test s[:p95] > 94.0

    ## the confidence half-width is about the sample size, so compare like with like
    uniform_20 = Tally(:x; keep = 0)
    uniform_200 = Tally(:x; keep = 0)
    rng = StableRNGs.StableRNG(3)
    for x in rand(rng, 200)
        tally_record!(uniform_200, x)
    end
    for x in rand(StableRNGs.StableRNG(3), 20)
        tally_record!(uniform_20, x)
    end
    @test half_width(uniform_20) > half_width(uniform_200)
    @test half_width(uniform_200) < 0.3                 # √200 is enough to be precise
end

@testset "TimeWeighted" begin
    tw = TimeWeighted(:queue_length)
    @test mean(tw) == 0.0
    observe!(tw, 0.0, 10.0)
    observe!(tw, 4.0, 10.0)
    @test mean(tw) ≈ 2.0
    @test value_of(tw) == 4.0
    @test std(tw) ≈ 2.0

    ## thresholds accumulate from the moment they are tracked
    track_threshold!(tw, 1.0)
    observe!(tw, 4.0, 10.0)                  # above the threshold for ten units
    observe!(tw, 0.0, 10.0)                  # below it for another ten
    @test fraction_above(tw, 1.0) ≈ 10.0 / 40.0 rtol = 0.01
    @test time_above(tw, 1.0) ≈ 10.0 rtol = 0.01
    @test isnan(fraction_above(tw, 99.0))

    ## update! credits the elapsed time to the value that was in force
    σ = Sim(:tw; horizon = 100.0)
    stat = statistic!(σ, :wip_mean, TimeWeighted(:wip_mean))
    advance!(σ, 5.0)
    observe!(stat, σ, 2.0)                   # 0 for the first five units, then 2
    advance!(σ, 5.0)
    observe!(stat, σ, 2.0)
    @test mean(stat) ≈ 1.0                   # (0 * 5 + 2 * 5) / 10
    observe!(stat, σ, 0.0)
    @test mean(stat) ≈ 1.0
    @test summary_of(stat)[:kind] === :time_weighted
end

@testset "Counter, Histogram, Recorder" begin
    c = Counter(:status)
    count!(c, :served, 3)
    count!(c, :scrapped)
    count!(c, :served)
    @test count_of(c, :served) == 4
    @test count_of(c, :scrapped) == 1
    @test total_of(c) == 5
    @test fractions(c)[:served] ≈ 0.8
    @test most_common(c) === :served
    @test summary_of(c)[:total] == 5

    h = Histogram(:wait, 0.0, 10.0, 10)
    @test length(h.counts) == 10
    for x in [0.5, 1.5, 1.6, 9.9, 20.0, -1.0]
        hist_record!(h, x)
    end
    @test n_of(h) == 6
    @test h.overflow == 1 && h.underflow == 1
    @test length(bin_centres(h)) == 10
    @test 0.0 <= cdf(h, 2.0) <= 1.0
    @test quantile(h, 0.5) > 0.0
    @test sum(histogram_density(h)) > 0
    @test summary_of(h)[:p95] > 5.0
    @test_throws ArgumentError Histogram(:x, 0.0, 1.0, 0)      # a histogram needs a bin
    @test length(Histogram(:x, 0.0, 1.0, 1).counts) == 1

    r = Recorder(:wip; limit = 8)
    for i in 1:40
        recorder_record!(r, Float64(i), Float64(i))
    end
    @test n_of(r) <= 8
    @test r.decimation > 1
    @test peak(r) == 40.0
    @test tail_mean(r) > mean(r)
    t, v = moving_average(r; window = 4)
    @test length(t) == length(v)
    @test mean(r) > 0
    @test summary_of(r)[:kind] === :recorder
end

@testset "the registry of a simulation" begin
    σ = Sim(:stats; horizon = 100.0)
    tally!(σ, :wait, 1.0)
    tally!(σ, :wait, 3.0)
    observe!(σ, :queue_length, 2.0)
    count!(σ, :status, :served)
    record!(σ, :wip, 1.0)
    @test σ[:wait] isa Tally
    @test σ[:queue_length] isa TimeWeighted
    @test σ[:status] isa Counter
    @test σ[:wip] isa Recorder
    @test n_statistics(σ) == 4
    rows = statistics_table(σ)
    @test length(rows) == 4
    @test statistics_table(σ)[1][:name] in keys(σ.stats)
    @test summary_of(σ, :wait)[:n] == 2
    @test_throws KeyError σ[:nonsense]

    ## warmup! resets every statistic, and the report sees the new start
    advance!(σ, 10.0)
    stat = statistic!(σ, :late, Tally(:late))
    tally_record!(stat, 5.0)
    warmup!(σ, 20.0)
    run!(σ)
    @test σ.warmed
    @test mean(σ[:wait]) |> isnan            # reset, nothing recorded after
    @test mean(stat) |> isnan
end

@testset "intervals of replications" begin
    x = [1.0, 2.0, 3.0, 4.0, 5.0]
    ci = mean_ci(x)
    @test ci[:n] == 5
    @test ci[:mean] == 3.0
    @test ci[:lo] < 3.0 < ci[:hi]
    @test ci[:adequate]
    @test ci[:relative_half_width] > 0
    tiny = mean_ci([2.0])
    @test !tiny[:adequate] && isnan(tiny[:half_width])
    empty_ci = mean_ci(Float64[])
    @test empty_ci[:n] == 0

    spread = [1.0, 5.0, 9.0]
    @test required_replications(spread) > required_replications(x)
    @test cumulative_mean([1.0, 3.0]) == [1.0, 2.0]
    @test autocorrelation([1.0, 1.0, 1.0]) == 0.0
    @test autocorrelation(collect(1.0:100.0)) > 0.9    # a trend is autocorrelated
end
