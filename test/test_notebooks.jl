# test_notebooks.jl -- the notebooks are deliverables, so they are checked.
@testset "reading a notebook" begin
    path = joinpath(TEST_TMP, "tiny.jl")
    open(path, "w") do io
        write(io, "### A Pluto.jl notebook ###\n# v0.20.23\n\nusing Markdown\n\n")
        write(io, "# ", Char(0x2554), Char(0x2550), Char(0x2561), " abc-1\nbegin\n    x = 1\nend\n\n")
        write(io, "# ", Char(0x2554), Char(0x2550), Char(0x2561), " abc-2\nmd\"\"\"\n# Hi\n\"\"\"\n\n")
        write(io, "# ", Char(0x2554), Char(0x2550), Char(0x2561), " Cell order:\n")
        write(io, "# ", Char(0x2560), Char(0x2550), "abc-1\n# ", Char(0x2560), Char(0x2550), "abc-2\n")
    end
    lines, cells = notebook_cells(path)
    @test length(cells) == 2
    @test first(cells)[1] == "abc-1"
    @test cells[1][2] == "begin\n    x = 1\nend"
    @test !is_markdown_cell(cells[1][2])
    @test is_markdown_cell(cells[2][2])
    @test cell_order_section(lines) == ["abc-1", "abc-2"]
    @test lines[1] == "### A Pluto.jl notebook ###"

    ## the static analysis understands the code a notebook contains
    @test cell_bindings(Meta.parse("x = 1")) == Set([:x])
    @test cell_bindings(Meta.parse("(a, b) = (1, 2)")) == Set([:a, :b])
    @test cell_bindings(Meta.parse("function f(x) x end")) == Set([:f])
    @test cell_bindings(Meta.parse("f = x -> x + y")) == Set([:f, :x])
    @test cell_bindings(Meta.parse("@bind n Slider(1:3)")) == Set([:n])
    @test cell_bindings(Meta.parse("using DiscreteSim")) == Set([:DiscreteSim])
    refs = cell_references(Meta.parse("x + y.f + g(1)"))
    @test :x in refs && :y in refs && :g in refs
    @test :f ∉ refs                                   # field names are not references
    @test :end ∉ cell_references(Meta.parse("v[end]"))
end

@testset "validating the shipped notebooks" begin
    results = validate_notebooks(joinpath(dirname(@__DIR__), "notebooks"))
    @test length(results) == 8
    @test all(r -> r.ok, results)
    @test all(r -> r.printout_cells > 0, results)
    @test all(r -> r.code_cells > 5, results)
    @test all(r -> r.markdown_cells > 3, results)
    @test string(first(results).notebook) == "00_Study_Overview.jl"
    @test string(results[2].notebook) == "01_The_Engine.jl"
    @test sort(string.(getfield.(results, :notebook))) ==
          sort(["00_Study_Overview.jl", "01_The_Engine.jl", "02_Queues_and_Capacity.jl",
        "03_The_Models.jl", "04_Experiments_and_Confidence.jl", "05_Calibration.jl",
        "06_Offline_and_Online.jl", "07_Artefacts_and_PDF.jl"])
    @test all(r -> isempty(r.problems), results)

    ## a notebook with a problem is reported with the reason
    bad = joinpath(TEST_TMP, "bad.jl")
    open(bad, "w") do io
        write(io, "### A Pluto.jl notebook ###\n\nusing Markdown\n\n")
        write(io, "# ", Char(0x2554), Char(0x2550), Char(0x2561), " one\nbegin\n    x = 1\n    y = 2\nend\n")
    end
    report = validate_notebook(bad)
    @test !report.ok
    @test !isempty(report.problems)
    @test any(p -> occursin("printout", p), report.problems)
    @test any(p -> occursin("Cell order", p), report.problems)
    @test report.cells == 1
    @test occursin("FAIL", sprint(print_validation_report, [report]))

    ## the file listing is in reading order and skips backups
    files = notebook_files(joinpath(dirname(@__DIR__), "notebooks"))
    @test length(files) == 8
    @test basename(files[1]) == "00_Study_Overview.jl"
    @test all(f -> endswith(f, ".jl"), files)
end

@testset "running a notebook headless" begin
    ## a real Pluto run is slow (it starts a notebook process), so it is opt-in
    if get(ENV, "DISCRETESIM_TEST_PLUTO", "false") == "true"
        path = joinpath(TEST_TMP, "pluto_smoke.jl")
        open(path, "w") do io
            write(io, "### A Pluto.jl notebook ###\n# v0.20.23\n\nusing Markdown\nusing InteractiveUtils\n\n")
            write(io, "# ", Char(0x2554), Char(0x2550), Char(0x2561), " c1\nbegin\n    println(\"hello\")\n    1 + 1\nend\n\n")
            write(io, "# ", Char(0x2554), Char(0x2550), Char(0x2561), " Cell order:\n")
            write(io, "# ", Char(0x2560), Char(0x2550), "c1\n")
        end
        report = run_notebook(path; passes = 1, save = false)
        @test report[:ok]
        @test report[:cells] == 1
        @test isempty(report[:errors])
        @test report[:seconds] > 0
    else
        @info "skipping the headless Pluto run (set DISCRETESIM_TEST_PLUTO=true to run it)"
        @test true
    end
end
