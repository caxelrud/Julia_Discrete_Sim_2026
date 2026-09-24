# test_processes.jl -- processes, holds, interrupts and the error policy.
@testset "processes" begin
    σ = Sim(:processes; seed = 1, horizon = 100.0)
    order = Any[]
    p = spawn!(σ, () -> begin
        push!(order, (:start, σ.now))
        hold!(σ, 5.0)
        push!(order, (:middle, σ.now))
        hold!(σ, 5.0)
        push!(order, (:end, σ.now))
        return nothing
    end; name = :worker, attrs = SymDict(:entity => :job))
    @test process_id(p) == 1
    @test process_name(p) == :worker
    @test state_of(p) === :ready
    @test is_alive(p) && !is_finished(p)
    @test attribute(p, :entity) === :job
    set_attribute!(p, :product, :grade_a)
    @test attribute(p, :product) === :grade_a
    @test occursin(":worker", sprint(show, p))

    run!(σ)
    @test order == [(:start, 0.0), (:middle, 5.0), (:end, 10.0)]
    @test is_finished(p)
    @test sojourn_of(p) == 10.0
    @test σ.processed >= 3

    ## the state of the processes of a finished run is book-keeping too
    states = process_states(σ)
    @test states[:finished] == 1
    @test sum(values(states)) == length(σ.processes)
    @test isempty(live_processes(σ))
    @test isempty(blocked_processes(σ))

    ## a process that throws fails the run (strict by default)
    σ2 = Sim(:failure; horizon = 10.0, strict = true)
    spawn!(σ2, () -> error("boom"); name = :broken)
    err = try
        run!(σ2)
        nothing
    catch e
        e
    end
    @test err isa SimulationError
    @test err.kind === :user_error
    @test occursin("boom", err.message)
    @test occursin(":broken", sprint(showerror, err))

    ## with strict = false the error is recorded instead of thrown
    σ3 = Sim(:lenient; horizon = 10.0, strict = false)
    bad = spawn!(σ3, () -> error("recorded"); name = :broken)
    run!(σ3)
    @test state_of(bad) === :failed
    @test bad.error isa ErrorException

    ## an uncaught SimInterrupt is a bug in the model, not something to swallow
    σ4 = Sim(:interrupt_bug; horizon = 10.0)
    victim = spawn!(σ4, () -> (hold!(σ4, 100.0); nothing); name = :victim)
    callback!(σ4, 1.0, s -> interrupt!(s, victim, :surprise))
    err4 = try
        run!(σ4)
        nothing
    catch e
        e
    end
    @test err4 isa SimulationError
    @test occursin("SimInterrupt", err4.message)
end

@testset "holds, blocks and interruptions" begin
    ## hold! with zero delay yields without moving the clock
    σ = Sim(:yield; horizon = 5.0)
    events = Any[]
    spawn!(σ, () -> (push!(events, :a1); hold!(σ, 0.0); push!(events, :a2); nothing); name = :a)
    spawn!(σ, () -> (push!(events, :b1); hold!(σ, 0.0); push!(events, :b2); nothing); name = :b)
    run!(σ)
    @test events == [:a1, :b1, :a2, :b2]
    @test clock_time(σ) == 0.0

    ## block!/activate!/passivate! are the manual handshake
    σ2 = Sim(:handshake; horizon = 50.0)
    log = Any[]
    worker = spawn!(σ2, () -> begin
        push!(log, (:waiting, σ2.now))
        block!(σ2)
        push!(log, (:resumed, σ2.now))
        passivate!(σ2)
        push!(log, (:activated, σ2.now))
        return nothing
    end; name = :worker)
    callback!(σ2, 5.0, s -> activate!(s, worker))
    callback!(σ2, 20.0, s -> activate!(s, worker))
    run!(σ2)
    @test log == [(:waiting, 0.0), (:resumed, 5.0), (:activated, 20.0)]

    ## interrupt! cuts into a hold and the process can catch it
    σ3 = Sim(:cut; horizon = 100.0)
    story = Any[]
    victim = spawn!(σ3, () -> begin
        try
            hold!(σ3, 50.0)
            push!(story, :completed)
        catch err
            err isa SimInterrupt || rethrow()
            push!(story, (err.message, σ3.now))
        end
        return nothing
    end; name = :victim)
    callback!(σ3, 7.0, s -> interrupt!(s, victim, :shift_change))
    run!(σ3)
    @test story == [(:shift_change, 7.0)]

    ## a process waiting for a resource is detached and interrupted
    σ4 = Sim(:queued_interrupt; horizon = 100.0)
    machine = resource!(σ4, Resource(:machine))
    tale = Any[]
    first_user = spawn!(σ4, () -> (use!(σ4, machine, 40.0); nothing); name = :long)
    second = spawn!(σ4, () -> begin
        try
            request!(σ4, machine)
            push!(tale, :granted)
        catch err
            err isa SimInterrupt || rethrow()
            push!(tale, :interrupted_in_queue)
        end
        return nothing
    end; name = :short)
    callback!(σ4, 5.0, s -> interrupt!(s, second, :cancelled_order))
    run!(σ4)
    @test tale == [:interrupted_in_queue]
    @test queue_length(machine) == 0
    @test is_finished(first_user)

    ## cancel! abandons a process for good
    σ5 = Sim(:cancel; horizon = 100.0)
    zombie = spawn!(σ5, () -> (hold!(σ5, 50.0); nothing); name = :zombie)
    callback!(σ5, 3.0, s -> cancel!(s, zombie, reason = :user_cancelled))
    run!(σ5)
    @test state_of(zombie) === :cancelled
    @test attribute(zombie, :cancel_reason) === :user_cancelled
    @test pending(σ5) == 0

    ## hold_until! works in absolute time
    σ6 = Sim(:until; horizon = 100.0)
    stamps = Float64[]
    spawn!(σ6, () -> (hold_until!(σ6, 12.5); push!(stamps, σ6.now); nothing); name = :timed)
    run!(σ6)
    @test stamps == [12.5]

    ## @process names the process after the function it runs
    σ7 = Sim(:macro; horizon = 20.0)
    keeper(σ) = (hold!(σ, 1.0); nothing)
    p7 = @process σ7 keeper(σ7)
    run!(σ7)
    @test process_name(p7) === :keeper
    @test is_finished(p7)

    ## current_process throws outside a process
    @test !inside_process(σ7)
    @test_throws SimulationError current_process(σ7)
end
