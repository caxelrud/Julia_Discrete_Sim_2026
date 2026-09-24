### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 59f6a264-421e-4b91-82ee-c86d453fc4bb
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ c414361d-a643-4539-8068-80eaf4eed8e8
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ b9ba93d7-7eb6-404f-bb4e-77f922d60830
md"""
# Offline first, online for periodic reevaluation

A feed that never breaks the pipeline, and the decision it justifies.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ e90c2f22-a08f-4fd3-9e9f-bc61028a959a
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ f228f369-fca4-4d36-a5f4-6ad6524fa807
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ c240d2c1-cf37-4103-bc27-d6582133696d
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ 447d67aa-f572-49b8-bcd1-dfce5fe1de1b
begin
bundle = load_study(ROOT);
end

# ╔═╡ c593733d-f9a7-4255-b77d-3bc9ffa6e489
begin
TableOfContents()
end

# ╔═╡ 612c97ff-6c86-41e8-995a-ea878d9b9474
md"""
## The section: *Online*
"""

# ╔═╡ 3b4639f3-9448-4421-a00a-dc0f70c535c2
begin
HTML(preview_section(bundle, :online))
end

# ╔═╡ 1a4b3a92-e386-490b-b2f7-41285849af9d
md"""
## The fallback chain, live

The data layer never fails. Ask for the periodic feed and it walks down the chain:
the online source, the local copy of the same feed, the last cached reply, and
finally offline with whatever the model already knows.
"""

# ╔═╡ 74989b33-1c09-4404-a3d7-45d736f8a4c8
begin
reachable = fetch_online(OnlineConfig())
    SymDict(:url => reachable[:url], :status => reachable[:status], :source => reachable[:source],
        :freshness => reachable[:freshness], :attempts => reachable[:attempts],
        :age_days => get(reachable, :age_days, NaN))
end

# ╔═╡ 0ec92ba5-62c6-4d08-97a7-8354c2290dca
begin
feed_file = joinpath(ROOT, "data", "online_feed.json")
    blocked = fetch_online(OnlineConfig(url = "http://127.0.0.1:9/nothing",
        local_file = feed_file, timeout = 1.0, retries = 0))
    counts = get(blocked, :observations, nothing)
    SymDict(:status => blocked[:status], :source => blocked[:source],
        :fallback => get(blocked, :fallback, :none),
        :series => counts === nothing ? 0 : length(counts))
end

# ╔═╡ eb17ba2f-8719-4903-8f70-78a56169668c
begin
offline = fetch_online(OnlineConfig(url = "http://127.0.0.1:9/nothing",
        local_file = joinpath(ROOT, "data", "missing.json"), timeout = 1.0, retries = 0,
        cache_dir = joinpath(ROOT, "tmp", "empty_cache")))
    SymDict(:status => offline[:status], :source => offline[:source],
        :freshness => offline[:freshness])
end

# ╔═╡ 7a7c1e03-daf6-45f2-9317-7d04697ededc
md"""
## The decision the feed justifies

A reevaluation round recalibrates from the freshest observations, compares them
with the model in use (relative change per parameter, and a two-sample
Kolmogorov--Smirnov test per series) and writes a verdict. The log is the audit
trail: when the model was checked, against what, and what was decided.
"""

# ╔═╡ 1bbfe695-8fc6-46c1-9e00-c13cd75d6aa0
begin
record = reevaluate(bundle[:calibration]; cfg = OnlineConfig(local_file = feed_file),
        model = Sym(get(bundle, :model, :mmc)), plan = ReevaluationPlan(7, :days),
        log_path = joinpath(ROOT, "data", "reevaluation_log.json"));
    SymDict(:verdict => record[:verdict], :reason => record[:reason],
        :source => record[:source], :worst_change => record[:worst_change],
        :ks_tests => length(record[:ks]))
end

# ╔═╡ 023e9501-3ac5-431c-aab3-fd9a62ba336c
begin
log_rows = reevaluation_log(joinpath(ROOT, "data", "reevaluation_log.json"))
    (last = isempty(log_rows) ? SymDict(:note => :empty) : feed_row(log_rows[end]),
        entries = length(log_rows))
end

# ╔═╡ abf9c284-5f3b-4052-a339-77e4d2531ceb
begin
plan = ReevaluationPlan(7, :days)
    SymDict(:plan => describe_plan(plan), :days => plan_days(plan),
        :due_after_3_days => due(plan, timestamp(Dates.now() - Dates.Day(3)), timestamp()),
        :due_after_30_days => due(plan, timestamp(Dates.now() - Dates.Day(30)), timestamp()))
end

# ╔═╡ 98d7426a-e166-425b-868c-f9e89d175b35
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_online.html` and
`reports/pdf/notebook_online.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ 97fca63c-829a-44cc-98fa-e62591df8636
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :online; root = ROOT)
end

# ╔═╡ cb299f79-c8ad-4e89-8802-e2a7afc9280c
begin
Markdown.parse(string("---\n",
        "*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed `",
        get(get(bundle, :config, SymDict()), :seed, 0),
        "`). Re-run `julia --project=. scripts/run_study.jl` to refresh every number ",
        "in this notebook.*"))
end

# ╔═╡ Cell order:
# ╠═b9ba93d7-7eb6-404f-bb4e-77f922d60830
# ╠═e90c2f22-a08f-4fd3-9e9f-bc61028a959a
# ╠═59f6a264-421e-4b91-82ee-c86d453fc4bb
# ╠═c414361d-a643-4539-8068-80eaf4eed8e8
# ╠═f228f369-fca4-4d36-a5f4-6ad6524fa807
# ╠═c240d2c1-cf37-4103-bc27-d6582133696d
# ╠═447d67aa-f572-49b8-bcd1-dfce5fe1de1b
# ╠═c593733d-f9a7-4255-b77d-3bc9ffa6e489
# ╠═612c97ff-6c86-41e8-995a-ea878d9b9474
# ╠═3b4639f3-9448-4421-a00a-dc0f70c535c2
# ╠═1a4b3a92-e386-490b-b2f7-41285849af9d
# ╠═74989b33-1c09-4404-a3d7-45d736f8a4c8
# ╠═0ec92ba5-62c6-4d08-97a7-8354c2290dca
# ╠═eb17ba2f-8719-4903-8f70-78a56169668c
# ╠═7a7c1e03-daf6-45f2-9317-7d04697ededc
# ╠═1bbfe695-8fc6-46c1-9e00-c13cd75d6aa0
# ╠═023e9501-3ac5-431c-aab3-fd9a62ba336c
# ╠═abf9c284-5f3b-4052-a339-77e4d2531ceb
# ╠═98d7426a-e166-425b-868c-f9e89d175b35
# ╠═97fca63c-829a-44cc-98fa-e62591df8636
# ╠═cb299f79-c8ad-4e89-8802-e2a7afc9280c
