### A Pluto.jl notebook ###
# v0.20.23

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
end

# ╔═╡ ddaa7791-7a71-4aa7-a8d1-7fcfac7ab4b4
md"""
# Offline first, online for periodic reevaluation

A feed that never breaks the pipeline, and the decision it justifies.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ 9763d229-2881-41df-b784-ed0301bc579d
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ e24aff4f-254a-491f-8c9a-2d0d5bf496c5
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ bc479d34-b8eb-44d9-ab26-67d08aaf77bf
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ c676ea5e-de15-4d96-8cd0-52eccbcd8e16
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ b9edc3fc-92ec-4304-a12c-634cbc50cb86
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ 78d25ded-5344-406c-af7f-e509b316cbbc
begin
bundle = load_study(ROOT);
end

# ╔═╡ c3b1d149-215d-4255-82b0-f2798a0140f7
begin
TableOfContents()
end

# ╔═╡ f528082e-506e-4c17-a615-2ab6cb2a2842
md"""
## The section: *Online*
"""

# ╔═╡ 8f00703d-6faa-47bc-85d0-8d3c591cc7db
begin
HTML(preview_section(bundle, :online))
end

# ╔═╡ fda3800b-4aa9-415e-92cc-cc040be164a7
md"""
## The fallback chain, live

The data layer never fails. Ask for the periodic feed and it walks down the chain:
the online source, the local copy of the same feed, the last cached reply, and
finally offline with whatever the model already knows.
"""

# ╔═╡ a47cd416-e3e7-420a-b3d1-e9fce95a6d3d
begin
reachable = fetch_online(OnlineConfig())
    SymDict(:url => reachable[:url], :status => reachable[:status], :source => reachable[:source],
        :freshness => reachable[:freshness], :attempts => reachable[:attempts],
        :age_days => get(reachable, :age_days, NaN))
end

# ╔═╡ 572817ec-3e09-41db-9d0c-840245f896c5
begin
feed_file = joinpath(ROOT, "data", "online_feed.json")
    blocked = fetch_online(OnlineConfig(url = "http://127.0.0.1:9/nothing",
        local_file = feed_file, timeout = 1.0, retries = 0))
    counts = get(blocked, :observations, nothing)
    SymDict(:status => blocked[:status], :source => blocked[:source],
        :fallback => get(blocked, :fallback, :none),
        :series => counts === nothing ? 0 : length(counts))
end

# ╔═╡ b4bade80-4628-4ba4-81a6-ebbe30caf89f
begin
offline = fetch_online(OnlineConfig(url = "http://127.0.0.1:9/nothing",
        local_file = joinpath(ROOT, "data", "missing.json"), timeout = 1.0, retries = 0,
        cache_dir = joinpath(ROOT, "tmp", "empty_cache")))
    SymDict(:status => offline[:status], :source => offline[:source],
        :freshness => offline[:freshness])
end

# ╔═╡ 6ee4356e-713d-4bb8-8278-3e0fc5866a26
md"""
## The decision the feed justifies

A reevaluation round recalibrates from the freshest observations, compares them
with the model in use (relative change per parameter, and a two-sample
Kolmogorov--Smirnov test per series) and writes a verdict. The log is the audit
trail: when the model was checked, against what, and what was decided.
"""

# ╔═╡ dc5cbf39-b5b7-4af3-8a46-f719fccc9648
begin
record = reevaluate(bundle[:calibration]; cfg = OnlineConfig(local_file = feed_file),
        model = Sym(get(bundle, :model, :mmc)), plan = ReevaluationPlan(7, :days),
        log_path = joinpath(ROOT, "data", "reevaluation_log.json"));
    SymDict(:verdict => record[:verdict], :reason => record[:reason],
        :source => record[:source], :worst_change => record[:worst_change],
        :ks_tests => length(record[:ks]))
end

# ╔═╡ 7dad8973-099f-4bdd-b149-a565449a32aa
begin
log_rows = reevaluation_log(joinpath(ROOT, "data", "reevaluation_log.json"))
    (last = isempty(log_rows) ? SymDict(:note => :empty) : feed_row(log_rows[end]),
        entries = length(log_rows))
end

# ╔═╡ ee34c746-0774-48e3-bb3d-f4d790ba14a0
begin
plan = ReevaluationPlan(7, :days)
    SymDict(:plan => describe_plan(plan), :days => plan_days(plan),
        :due_after_3_days => due(plan, timestamp(Dates.now() - Dates.Day(3)), timestamp()),
        :due_after_30_days => due(plan, timestamp(Dates.now() - Dates.Day(30)), timestamp()))
end

# ╔═╡ 6375bc52-1ce9-452f-984b-9c7f544781b5
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_online.html` and
`reports/pdf/notebook_online.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ 21e79a43-685d-480a-b930-25ff1dc22539
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :online; root = ROOT)
end

# ╔═╡ 94c7e0ea-d4d7-4365-b98c-e135c70ff323
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═ddaa7791-7a71-4aa7-a8d1-7fcfac7ab4b4
# ╠═9763d229-2881-41df-b784-ed0301bc579d
# ╠═e24aff4f-254a-491f-8c9a-2d0d5bf496c5
# ╠═bc479d34-b8eb-44d9-ab26-67d08aaf77bf
# ╠═c676ea5e-de15-4d96-8cd0-52eccbcd8e16
# ╠═b9edc3fc-92ec-4304-a12c-634cbc50cb86
# ╠═78d25ded-5344-406c-af7f-e509b316cbbc
# ╠═c3b1d149-215d-4255-82b0-f2798a0140f7
# ╠═f528082e-506e-4c17-a615-2ab6cb2a2842
# ╠═8f00703d-6faa-47bc-85d0-8d3c591cc7db
# ╠═fda3800b-4aa9-415e-92cc-cc040be164a7
# ╠═a47cd416-e3e7-420a-b3d1-e9fce95a6d3d
# ╠═572817ec-3e09-41db-9d0c-840245f896c5
# ╠═b4bade80-4628-4ba4-81a6-ebbe30caf89f
# ╠═6ee4356e-713d-4bb8-8278-3e0fc5866a26
# ╠═dc5cbf39-b5b7-4af3-8a46-f719fccc9648
# ╠═7dad8973-099f-4bdd-b149-a565449a32aa
# ╠═ee34c746-0774-48e3-bb3d-f4d790ba14a0
# ╠═6375bc52-1ce9-452f-984b-9c7f544781b5
# ╠═21e79a43-685d-480a-b930-25ff1dc22539
# ╠═94c7e0ea-d4d7-4365-b98c-e135c70ff323
