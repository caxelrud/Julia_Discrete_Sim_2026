# test_engine.jl -- the calendar, the clock and the trace.
@testset "calendar" begin
    cal = Calendar()
    @test isempty(cal) && length(cal) == 0
    for (t, prio, seq) in ((2.0, 0, 1), (1.0, 5, 2), (1.0, 1, 3), (3.0, 0, 4))
        push_event!(cal, Event(t, prio, seq, :x, 0))
    end
    @test length(cal) == 4
    @test peek_event(cal).time == 1.0
    @test peek_event(cal).priority == 1          # the low priority number wins
    @test pop_event!(cal).seq == 3
    @test pop_event!(cal).seq == 2               # then insertion order at equal time
    @test pop_event!(cal).time == 2.0
    @test next_time(cal) == 3.0
    @test pop_event!(cal).time == 3.0
    @test pop_event!(cal) === nothing
    @test isempty(cal)

    ## a heap of 2000 random events comes out in order
    cal2 = Calendar()
    rng = StableRNGs.StableRNG(7)
    times = rand(rng, 2000) .* 100
    for (i, t) in enumerate(times)
        push_event!(cal2, Event(t, 0, i, :x, 0))
    end
    out = [pop_event!(cal2).time for _ in 1:2000]
    @test issorted(out)
    @test isempty(cal2)

    ## cancelling an event that is already out of the calendar is harmless
    cal3 = Calendar()
    ev = Event(1.0, 0, 1, :x, 0)
    push_event!(cal3, ev)
    @test length(cal3) == 1
    cancel_event!(cal3, ev)
    @test length(cal3) == 0
    cancel_event!(cal3, ev)
    @test length(cal3) == 0
    @test pop_event!(cal3) === nothing
    cancelled = Event(2.0, 0, 2, :x, 0)
    push_event!(cal3, cancelled)
    push_event!(cal3, Event(2.0, 0, 3, :y, 0))
    cancel_event!(cal3, cancelled)
    @test pop_event!(cal3).kind === :y
    @test length(cal3) == 0
end

@testset "clock and scheduling" begin
    σ = Sim(:clock; seed = 1, horizon = 100.0)
    @test clock_time(σ) == 0.0
    @test pending(σ) == 0
    @test seed_of(σ) == 1
    @test time_unit(σ) === :minutes
    @test stop_reason(σ) === :none
    @test !is_stopped(σ)

    hits = Any[]
    callback!(σ, 5.0, (s, x) -> push!(hits, (s.now, x)), :five)
    callback!(σ, 10.0, (s, x) -> push!(hits, (s.now, x)), :ten)
    @test pending(σ) == 2
    @test next_time(σ) == 5.0

    run!(σ)
    @test hits == [(5.0, :five), (10.0, :ten)]
    @test clock_time(σ) == 10.0
    @test stop_reason(σ) === :empty_calendar
    @test events_processed(σ) == 2

    ## the horizon stops the run and never moves past it
    σ2 = Sim(:horizon; horizon = 5.0)
    callback!(σ2, 3.0, s -> nothing)
    callback!(σ2, 8.0, s -> nothing)
    run!(σ2)
    @test clock_time(σ2) == 3.0
    @test stop_reason(σ2) === :horizon
    @test pending(σ2) == 1

    ## step! is one event, advance! is a window, stop! ends a run
    σ3 = Sim(:steps; horizon = 100.0)
    callback!(σ3, 1.0, s -> nothing)
    callback!(σ3, 2.0, s -> nothing)
    step!(σ3)
    @test clock_time(σ3) == 1.0
    advance!(σ3, 5.0)
    @test clock_time(σ3) == 6.0                     # the clock moved, the events ran
    @test stop_reason(σ3) === :none
    stop!(σ3, :user)
    run!(σ3)
    @test stop_reason(σ3) === :user

    ## limits stop a runaway model instead of hanging it
    σ4 = Sim(:limits; horizon = Inf, max_events = 5)
    tick(s) = (callback!(s, 1.0, tick); nothing)
    callback!(σ4, 1.0, tick)
    run!(σ4)
    @test stop_reason(σ4) === :max_events
    @test events_processed(σ4) == 5

    ## hooks
    σ5 = Sim(:hooks)
    seen = Any[]
    on!(σ5, :tick, (s, payload) -> push!(seen, payload))
    emit!(σ5, :tick, 1)
    emit!(σ5, :other, 2)
    @test seen == [1]

    ## reset! clears the calendar and the clock
    σ6 = Sim(:reset; horizon = 10.0)
    callback!(σ6, 1.0, s -> nothing)
    run!(σ6)
    reset!(σ6)
    @test clock_time(σ6) == 0.0 && pending(σ6) == 0 && events_processed(σ6) == 0
    @test stop_reason(σ6) === :none
end

@testset "trace" begin
    σ = Sim(:trace; seed = 3, horizon = 50.0, trace_events = true)
    server = resource!(σ, Resource(:server))
    spawn!(σ, () -> begin
        for _ in 1:3
            use!(σ, server, 1.0)
        end
        return nothing
    end; name = :user)
    run!(σ)
    @test n_of(σ.trace) > 0
    @test sum(values(trace_summary(σ.trace))) == n_of(σ.trace)
    @test length(rows_of(σ.trace, :ship)) == 0
    @test last_time(σ.trace) <= 50.0
    @test events_after(σ.trace, 0.0) == n_of(σ.trace)

    table = trace_table(σ)
    @test Tables.columnnames(table) == (:time, :kind, :entity, :resource, :process, :value, :note)
    @test length(Tables.getcolumn(table, :kind)) == n_of(σ.trace)
    @test Tables.getcolumn(table, :time) === σ.trace.times
    @test_throws ArgumentError Tables.getcolumn(table, :nonsense)
    rows = trace_rows(σ.trace)
    @test length(rows) == n_of(σ.trace)
    @test first(rows).kind in EVENT_KINDS

    segments = occupation_segments(σ.trace, :server)
    @test !isempty(segments)
    @test all(s -> s[2] >= s[1], segments)

    ## a limited trace drops rows instead of growing without bound
    σ2 = Sim(:limited; horizon = 100.0, trace_limit = 10)
    m = resource!(σ2, Resource(:m))
    spawn!(σ2, () -> begin
        for _ in 1:20
            use!(σ2, m, 0.5)
        end
        return nothing
    end; name = :user)
    run!(σ2)
    @test n_of(σ2.trace) == 10
    @test is_truncated(σ2.trace)
    reset_trace!(σ2.trace)
    @test n_of(σ2.trace) == 0 && !is_truncated(σ2.trace)

    ## a filtered trace only records the kinds it was asked for
    σ3 = Sim(:filtered; horizon = 20.0, trace_kinds = [:ship])
    m3 = resource!(σ3, Resource(:m))
    spawn!(σ3, () -> use!(σ3, m3, 1.0); name = :user)
    run!(σ3)
    @test all(==(:ship), σ3.trace.kinds) || n_of(σ3.trace) == 0
end
