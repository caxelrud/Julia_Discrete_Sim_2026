# test_printout.jl -- the HTML printout and the PDF printing.
@testset "formatting" begin
    @test html_escape("a<b>&\"'") == "a&lt;b&gt;&amp;&quot;&#39;"
    @test html_escape(3) == "3"
    @test fmt_number(1) == "1"
    @test fmt_number(1234.0) == "1234"
    @test fmt_number(12.34) == "12.3"
    @test fmt_number(0.1234) == "0.123"
    @test fmt_number(0.0001234) == "0.000123"
    @test fmt_number(0.0) == "0"
    @test fmt_number(NaN) == "—"
    @test fmt_number(Inf) == "—"
    @test fmt_number(nothing) == "—"
    @test fmt_number(:wait) == "wait"
    @test fmt_number(true) == "yes"
    @test fmt_metric(12.5, :items_per_hour) == "12.5 /h"
    @test fmt_metric(0.82, :ratio) == "0.82"
    @test fmt_metric(3.0, :minutes) == "3 minutes"
    @test fmt_value("text", :count) == "text"
    @test fmt_interval(SymDict(:mean => 2.0, :half_width => 0.5)) == "2 ± 0.5"
    @test occursin("badge good", badge("ok", :good))
    @test verdict_class(:validated) === :good
    @test verdict_class(:marginal) === :warn
    @test verdict_class(:failed) === :bad
    @test verdict_class(:whatever) === :info
    @test occursin("<p>", paragraph_html("hi"))
    @test occursin("<li>", list_html(["a", "b"]))
    @test occursin("<ol>", list_html(["a"]; ordered = true))
    @test occursin("callout bad", callout_html("x", :bad))
    @test occursin("Title", callout_html("x"; title = :Title))
end

@testset "building blocks" begin
    cards = cards_html([(label = :throughput, value = 1.5, unit = :items_per_hour),
        (label = :utilisation, value = 0.8, unit = :ratio)])
    @test occursin("Throughput", cards)
    @test occursin("items_per_hour", cards)
    @test occursin("class=\"card\"", cards)
    @test count("<div class=\"card\">", cards) == 2

    rows = [SymDict(:metric => :throughput, :mean => 1.5, :unit => :items_per_hour),
        SymDict(:metric => :utilisation, :mean => 0.75, :unit => :ratio)]
    table = table_html(rows, [:metric, :mean, :unit];
        units = Dict{Symbol,Symbol}(:mean => :items_per_hour))
    @test occursin("<table>", table)
    @test occursin("class=\"num\"", table)
    @test occursin("throughput", table)
    @test occursin("caption", table_html(rows, [:metric]; caption = :metrics))
    @test table_html(SymDict[], [:metric]) == ""

    tuples = [(metric = :wait, mean = 1.0), (metric = :queue_length, mean = 2.0)]
    tuple_table = table_html(tuples, [:metric, :mean])
    @test occursin("wait", tuple_table)
    @test occursin("Metric", tuple_table)          # the column header is a label

    kv = kv_html(SymDict(:seed => 1, :model => :mmc))
    @test occursin("Seed", kv) && occursin("mmc", kv)
    @test occursin("Seed", kv_html(SymDict(:seed => 1); keys = [:seed]))

    section = section_html(:overview, "Overview", "<p>x</p>"; lead = "hello")
    @test occursin("id=\"overview\"", section)
    @test occursin("hello", section)
    @test occursin("Overview", section)
end

@testset "figures and the document" begin
    σ = build_model(:mmc, model_params(:mmc), SymDict(:seed => 2, :horizon => 800.0,
        :trace => true))
    warmup!(σ, 100.0)
    run!(σ)
    p = fig_wip(σ)
    @test p isa Plots.Plot
    @test startswith(data_uri(p), "data:image/png;base64,")
    @test length(png_base64(p)) > 500
    @test fig_wait_hist(σ) isa Plots.Plot
    @test fig_utilisation(σ) isa Plots.Plot
    @test fig_throughput(σ) isa Plots.Plot
    @test fig_gantt(σ) isa Plots.Plot
    @test fig_convergence(experiment(opts -> build_model(:mmc, model_params(:mmc), opts),
        ExperimentConfig(replications = 3, horizon = 500.0))) isa Plots.Plot

    bundle = SymDict(:run => σ, :config => SymDict(:seed => 2, :replications => 3,
        :horizon => 800.0, :warmup => 100.0, :title => :test_study), :model => :mmc)
    figs = figure_set(bundle)
    @test haskey(figs, :wip)
    @test subset(figs, [:wip]) |> length == 1
    @test figure_html(figs[:wip]) |> x -> occursin("<img src=\"data:image/png;base64,", x)
    @test figure_html(nothing) == ""
    @test figure_html((plot = nothing, caption = :x, uri = "")) == ""

    ## a figure read back from disk is the same kind of object
    path = joinpath(TEST_TMP, "figure.png")
    Plots.savefig(p, path)
    from_disk = figure_from_png(path, :wip)
    @test occursin("data:image/png", from_disk[:uri])
    @test startswith(png_data_uri(path), "data:image/png")
    @test png_data_uri(joinpath(TEST_TMP, "missing.png")) == ""
    @test length(figure_set_from_dir(TEST_TMP)) == 1

    html = document_html("Title", "Subtitle", [:a => "<p>a</p>", :b => "<p>b</p>"];
        meta = SymDict(:seed => 1), footer = "the end")
    @test startswith(html, "<!DOCTYPE html>")
    @test occursin("<title>Title</title>", html)
    @test occursin("href=\"#a\"", html)
    @test occursin("the end", html)
    @test occursin(PRINTOUT_CSS[1:40], html)
    @test !occursin("href=\"#a\"", document_html("T", "S", [:a => "<p>a</p>"]; toc = false))

    preview = preview_section(bundle, :overview)
    @test occursin("<style>", preview)
    @test occursin("id=\"overview\"", preview)
end

@testset "the header of a printout" begin
    σ = build_model(:mmc, model_params(:mmc), SymDict(:seed => 2, :horizon => 800.0,
        :trace => true))
    warmup!(σ, 100.0)
    run!(σ)
    bundle = SymDict(:run => σ, :config => SymDict(:seed => 2, :replications => 3,
        :horizon => 800.0, :warmup => 100.0, :title => :test_study), :model => :mmc)

    meta = report_meta(bundle)
    @test meta[:model] === :mmc
    @test meta[:seed] == 2
    @test meta[:engine] === :DiscreteSim
    ## the header says when the document was made, in a readable form
    @test occursin(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$", meta[:generated])
    @test generation_stamp(DateTime(2026, 9, 24, 7, 21, 20)) == "2026-09-24 07:21:20"

    ## ... and it reaches the header line and the footer of the document
    html = report_html(bundle; keys = [:overview])
    @test occursin(string("Generated: ", meta[:generated]), html)
    @test occursin(string("from seed 2 on ", meta[:generated]), html)

    ## a caller that wants byte-identical printouts pins the stamp
    pinned = report_meta(SymDict(:model => :mmc,
        :config => SymDict(:generated => "1970-01-01 00:00:00")))
    @test pinned[:generated] == "1970-01-01 00:00:00"
    @test occursin("Generated: 1970-01-01 00:00:00",
        report_html(SymDict(:run => σ, :model => :mmc,
            :config => SymDict(:seed => 2, :generated => "1970-01-01 00:00:00"));
            keys = [:overview]))
    @test !occursin("from seed 2 on ", report_html(SymDict(:run => σ, :model => :mmc,
        :config => SymDict(:seed => 2, :generated => "")); keys = [:overview]))
end

@testset "printing to PDF" begin
    @test pdf_available()
    exe = find_chrome()
    @test isfile(exe)
    @test pdf_capability()[:available]
    @test_throws ArgumentError find_chrome(explicit = joinpath(TEST_TMP, "nope.exe"))

    html_path = joinpath(TEST_TMP, "printout.html")
    pdf_path = joinpath(TEST_TMP, "printout.pdf")
    write_printout(html_path, document_html("Test", "Subtitle", [:a => "<h2>A</h2><p>hello</p>"]))
    @test isfile(html_path)
    html_to_pdf(html_path, pdf_path)
    @test isfile(pdf_path)
    @test filesize(pdf_path) > 1000
    @test read(pdf_path, 4) == b"%PDF"

    second = joinpath(TEST_TMP, "second.pdf")
    print_html_to_pdf("<html><body><p>inline</p></body></html>", second)
    @test isfile(second)
    @test isfile(replace(second, ".pdf" => ".html"))
    @test_throws ArgumentError html_to_pdf(joinpath(TEST_TMP, "missing.html"),
        joinpath(TEST_TMP, "x.pdf"))
end