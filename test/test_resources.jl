# test_resources.jl -- servers, containers and stores.
@testset "resources" begin
    @test_throws ArgumentError Resource(:bad; capacity = 0)
    @test_throws ArgumentError Resource(:bad; discipline = :nonsense)
    @test_throws ArgumentError Container(:bad; capacity = -1.0)
    @test_throws ArgumentError Container(:bad; level = 5.0, capacity = 1.0)

    r = Resource(:machine; capacity = 2, kind = :machine, discipline = :lifo)
    @test r.capacity == 2 && r.kind === :machine && r.discipline === :lifo
    @test free_capacity(r) == 2 && in_use(r) == 0
    @test is_available(r) && availability(r) == 1.0
    @test isnan(mean_wait(r))
    @test summary_of(r)[:utilisation] == utilisation(r)
    @test summary_of(r)[:name] === :machine

    ## two servers, the third request waits; the statistics see everything
    σ = Sim(:pool; seed = 2, horizon = 200.0)
    pool = resource!(σ, Resource(:pool; capacity = 2))
    @test σ[:pool] === pool
    starts = Float64[]
    for _ in 1:4
        spawn!(σ, () -> begin
            request!(σ, pool)
            push!(starts, σ.now)
            hold!(σ, 1.0)
            release!(σ, pool)
            return nothing
        end; name = :user)
    end
    run!(σ)
    @test length(starts) == 4
    @test starts == [0.0, 0.0, 1.0, 1.0]
    @test count_of(pool.granted, :release) == 4
    @test mean_service(pool) == 1.0
    @test mean_wait(pool) > 0
    @test utilisation(pool) > 0.0
    @test queue_length(pool) == 0
    @test isempty(blocked_processes(σ))

    ## disciplines decide who is served first
    function service_order(discipline::Symbol)
        s = Sim(:order; horizon = 100.0)
        m = resource!(s, Resource(:m; discipline = discipline))
        seen = Int[]
        for i in 1:4
            spawn!(s, () -> begin
                request!(s, m; priority = i, service_estimate = Float64(i),
                    due = Float64(i))
                push!(seen, i)
                hold!(s, 1.0)
                release!(s, m)
                return nothing
            end; name = :client)
        end
        run!(s)
        return seen
    end
    @test service_order(:fifo) == [1, 2, 3, 4]
    @test service_order(:lifo) == [1, 4, 3, 2]
    @test service_order(:priority) == [1, 2, 3, 4]
    @test service_order(:spt) == [1, 2, 3, 4]
    @test service_order(:edd) == [1, 2, 3, 4]
    @test length(service_order(:random)) == 4

    ## use! releases even when the hold is interrupted
    σ2 = Sim(:use_protection; horizon = 100.0)
    m2 = resource!(σ2, Resource(:m))
    worker = spawn!(σ2, () -> begin
        try
            use!(σ2, m2, 30.0)
        catch err
            err isa SimInterrupt || rethrow()
        end
        return nothing
    end; name = :worker)
    callback!(σ2, 4.0, s -> interrupt!(s, worker, :preempted))
    run!(σ2)
    @test in_use(m2) == 0
    @test count_of(m2.granted, :release) == 1
    @test mean_service(m2) == 4.0

    ## with! does the same with a do block
    σ3 = Sim(:with; horizon = 100.0)
    m3 = resource!(σ3, Resource(:m))
    body_ran = Ref(false)
    spawn!(σ3, () -> begin
        with!(σ3, m3) do
            hold!(σ3, 2.0)
            body_ran[] = true
        end
        return nothing
    end; name = :user)
    run!(σ3)
    @test body_ran[]
    @test in_use(m3) == 0

    ## preemption takes a server away and hands it to the next waiter
    σ4 = Sim(:preempt; horizon = 100.0)
    m4 = resource!(σ4, Resource(:m))
    low = spawn!(σ4, () -> begin
        outcome = :none
        try
            request!(σ4, m4)
            hold!(σ4, 50.0)
            outcome = :finished
        catch err
            err isa SimInterrupt || rethrow()
            outcome = :preempted
        finally
            holds(m4, current_process(σ4)) && release!(σ4, m4)
        end
        outcome
    end; name = :low)
    callback!(σ4, 10.0, s -> preempt!(s, m4, low, message = :vip))
    run!(σ4)
    @test low.state === :finished
    @test total_of(m4.preemptions) == 1
    @test preempt!(σ4, m4, low) == false          # nothing to take any more

    ## a breakdown makes the resource unavailable and the repair brings it back
    σ5 = Sim(:breakdown; horizon = 100.0)
    m5 = resource!(σ5, Resource(:m))
    served = Float64[]
    for _ in 1:2
        spawn!(σ5, () -> begin
            request!(σ5, m5)
            push!(served, σ5.now)
            hold!(σ5, 1.0)
            release!(σ5, m5)
            return nothing
        end; name = :user)
    end
    callback!(σ5, 0.5, s -> breakdown!(s, m5, 20.0))
    run!(σ5)
    @test total_of(m5.breakdowns) == 1
    @test total_of(m5.repairs) == 1
    @test availability(m5) < 1.0
    @test served[1] == 0.0                        # the first user was already served
    @test served[2] >= 20.0                       # nobody else during the repair
    @test state_of(m5) === :idle
    repair!(σ5, m5)
    @test total_of(m5.repairs) == 2
end

@testset "containers and stores" begin
    σ = Sim(:tank; horizon = 200.0)
    tank = resource!(σ, Container(:tank; capacity = 10.0, level = 5.0))
    @test level_of(tank) == 5.0
    @test fill_ratio(tank) == 0.5
    produced = spawn!(σ, () -> begin
        for _ in 1:6
            fill!(σ, tank, 3.0)
            hold!(σ, 1.0)
        end
        return nothing
    end; name = :producer)
    consumed = spawn!(σ, () -> begin
        for _ in 1:6
            drain!(σ, tank, 3.0)
            hold!(σ, 1.0)
        end
        return nothing
    end; name = :consumer)
    run!(σ)
    @test is_finished(produced) && is_finished(consumed)
    @test 0.0 <= level_of(tank) <= 10.0
    @test total_of(tank.fills) == 6 && total_of(tank.drains) == 6
    @test mean_level(tank) > 0
    @test_throws ArgumentError fill!(σ, tank, -1.0)
    @test_throws ArgumentError drain!(σ, tank, 0.0)

    ## a store blocks a producer when it is full and a consumer when it is empty
    σ2 = Sim(:store; horizon = 100.0)
    buffer = resource!(σ2, Store(:buffer; capacity = 2))
    delivered = Symbol[]
    spawn!(σ2, () -> begin
        for i in 1:4
            store_item!(σ2, buffer, SymDict(:name => Symbol(:p, i)))
            hold!(σ2, 1.0)
        end
        return nothing
    end; name = :producer)
    spawn!(σ2, () -> begin
        for _ in 1:4
            item = retrieve!(σ2, buffer)
            push!(delivered, item[:name])
            hold!(σ2, 2.0)
        end
        return nothing
    end; name = :consumer)
    run!(σ2)
    @test delivered == [:p1, :p2, :p3, :p4]
    @test count_of(buffer) == 0
    @test mean_count(buffer) > 0
    @test total_of(buffer.stored) == 4 && total_of(buffer.retrieved) == 4

    ## a filtered retrieval serves the matching item first
    σ3 = Sim(:filtered_store; horizon = 100.0)
    parts = resource!(σ3, Store(:parts))
    taken = Symbol[]
    spawn!(σ3, () -> begin
        store_item!(σ3, parts, SymDict(:name => :a, :grade => 1))
        store_item!(σ3, parts, SymDict(:name => :b, :grade => 2))
        return nothing
    end; name = :producer)
    spawn!(σ3, () -> begin
        item = retrieve!(σ3, parts; filter = i -> i[:grade] == 2)
        push!(taken, item[:name])
        return nothing
    end; name = :consumer)
    run!(σ3)
    @test taken == [:b]
    @test count_of(parts) == 1
end