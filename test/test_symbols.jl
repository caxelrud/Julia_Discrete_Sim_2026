# test_symbols.jl -- the vocabulary and the symbol-keyed container.
@testset "vocabulary" begin
    @test Sym(:fifo) === :fifo
    @test Sym(" Fifo ") === :Fifo
    @test Sym(3) === Symbol("3")
    @test code_string(:queue_length) == "queue_length"
    @test title_string(:queue_length) == "Queue length"
    @test title_string(:λW) == "ΛW"                       # multi-byte safe
    @test symbol_equal(:wait, "wait")
    @test is_metric(:utilisation)
    @test !is_metric(:not_a_metric)
    @test is_discipline(:spt)
    @test is_distribution_kind(:lognormal)
    @test is_data_source(:online)
    @test vocabulary_of(:disciplines) === DISCIPLINES
    @test :metrics in vocabulary_kinds()
    @test_throws ArgumentError vocabulary_of(:nonsense)

    check = validate_vocabulary(:metrics, [:wait_mean, :nonsense])
    @test !check.ok && check.unknown == [:nonsense]
    @test validate_vocabulary(:entities, [:job]).ok

    @test metric_kind(:throughput) === :rate
    @test metric_kind(:cycle_time_mean) === :duration
    @test metric_unit(:utilisation) === :ratio
    @test is_lower_better(:cycle_time_mean)
    @test !is_lower_better(:throughput)
    @test optimisation_direction(:throughput) === :max
    @test metric_label(:wait_mean) === :MeanWait
    @test metric_label(:some_custom_metric) === Symbol("Some custom metric")

    @test relative_change(11.0, 10.0) == 0.1
    @test relative_error(9.0, 10.0) == 0.1
    @test format_duration(2.5, :minutes) == "2.5 minutes"
end

@testset "SymDict" begin
    d = SymDict(:a => 1, :b => 2)
    @test d[:a] == 1
    @test d.a == 1
    @test keys(d) == [:a, :b]
    @test length(d) == 2
    @test collect(d) == [:a => 1, :b => 2]
    d[:c] = 3
    @test keys(d) == [:a, :b, :c]            # insertion order is kept
    d[:a] = 10
    @test keys(d) == [:a, :b, :c]
    @test d[:a] == 10
    @test haskey(d, :c) && !haskey(d, :zz)
    @test get(d, :zz, :missing) === :missing
    @test get(() -> :f, d, :zz) === :f
    @test_throws KeyError d[:zz]

    @test to_named_tuple(d) == (a = 10, b = 2, c = 3)
    @test to_dict(d) isa Dict{Symbol,Any}
    @test keys(subset(d, [:c, :a])) == [:c, :a]
    @test numeric_keys(d) == [:a, :b, :c]
    @test common_keys(d, SymDict(:a => 1, :z => 0)) == [:a]

    e = SymDict(d)
    @test e[:b] == 2 && keys(e) == [:a, :b, :c]
    @test SymDict(:x => 1, :y => 2)[[:y]] isa SymDict
    @test SymDict((p = 1, q = 2)) == SymDict(:p => 1, :q => 2)
    @test SymDict(:a => v for (k, v) in [:a => 1])[:a] == 1

    m = merge(d, SymDict(:b => 20, :d => 4))
    @test m[:b] == 20 && m[:d] == 4 && d[:b] == 2      # merge does not mutate
    deep = deep_merge(SymDict(:x => SymDict(:a => 1)), SymDict(:x => SymDict(:b => 2)))
    @test deep[:x][:a] == 1 && deep[:x][:b] == 2
    @test deep_merge(SymDict(:x => 1), SymDict(:x => 2))[:x] == 2

    delete!(d, :b)
    @test keys(d) == [:a, :c]
    empty!(d)
    @test isempty(d) && length(d) == 0

    sd = SymDict(:uri => repeat("A", 4000), :n => 1)
    text = sprint(show, MIME"text/plain"(), sd)
    @test occursin("characters", text)                # long values are truncated
    @test !occursin(repeat("A", 300), text)
    @test occursin(":a => 1", sprint(show, SymDict(:a => 1)))

    nested = symbolize_deep(JSON3.read("{\"a\":{\"b\":[1,2]}}"))
    @test nested[:a][:b][1] == 1
    @test stringify_keys(SymDict(:a => 1))["a"] == 1
end
