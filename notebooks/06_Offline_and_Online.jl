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

# ╔═╡ 333e35e6-d4af-46ab-8f69-e14920dbca29
md"""
# Offline first, online for periodic reevaluation

A feed that never breaks the pipeline, and the decision it justifies.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ a6dc70e4-7635-47fe-a763-e7ee8eff459e
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ 2ded2965-e509-4af2-9c0d-89578794b789
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ afe119ea-051b-495a-8a7f-14f84d7fca77
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ ede5abc5-7cbb-4fec-bc18-ee97f87a7f68
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ ce61b177-68c8-48b6-a781-0bd242f32a42
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ d7c1b360-226e-49a3-b7a8-1a483d43b80b
begin
bundle = load_study(ROOT);
end

# ╔═╡ 301e469b-de94-4bfe-9740-ab10c5f54d6f
begin
TableOfContents()
end

# ╔═╡ bd68f55c-3155-4d0e-ad87-b49a8ad41d8a
md"""
## The section: *Online*
"""

# ╔═╡ 03611bca-1bcb-41b3-9fcb-7c81d3d9f16b
begin
HTML(preview_section(bundle, :online))
end

# ╔═╡ 4b5b12a1-7ad3-4758-ab6f-81b5e1046f02
md"""
## The fallback chain, live

The data layer never fails. Ask for the periodic feed and it walks down the chain:
the online source, the local copy of the same feed, the last cached reply, and
finally offline with whatever the model already knows.
"""

# ╔═╡ 315e3056-d670-4861-b634-11a2adc45b2c
begin
reachable = fetch_online(OnlineConfig())
    SymDict(:url => reachable[:url], :status => reachable[:status], :source => reachable[:source],
        :freshness => reachable[:freshness], :attempts => reachable[:attempts],
        :age_days => get(reachable, :age_days, NaN))
end

# ╔═╡ 9d2687c4-52a8-4426-a445-827da54e6f25
begin
feed_file = joinpath(ROOT, "data", "online_feed.json")
    blocked = fetch_online(OnlineConfig(url = "http://127.0.0.1:9/nothing",
        local_file = feed_file, timeout = 1.0, retries = 0))
    counts = get(blocked, :observations, nothing)
    SymDict(:status => blocked[:status], :source => blocked[:source],
        :fallback => get(blocked, :fallback, :none),
        :series => counts === nothing ? 0 : length(counts))
end

# ╔═╡ bf4fd19b-be2b-461a-96b3-7e8e018c06eb
begin
offline = fetch_online(OnlineConfig(url = "http://127.0.0.1:9/nothing",
        local_file = joinpath(ROOT, "data", "missing.json"), timeout = 1.0, retries = 0,
        cache_dir = joinpath(ROOT, "tmp", "empty_cache")))
    SymDict(:status => offline[:status], :source => offline[:source],
        :freshness => offline[:freshness])
end

# ╔═╡ 27b02e61-5b9d-493a-abad-0a70eb122646
md"""
## The decision the feed justifies

A reevaluation round recalibrates from the freshest observations, compares them
with the model in use (relative change per parameter, and a two-sample
Kolmogorov--Smirnov test per series) and writes a verdict. The log is the audit
trail: when the model was checked, against what, and what was decided.
"""

# ╔═╡ fc77d23e-89c7-4a74-b4ec-1438822c8abc
begin
record = reevaluate(bundle[:calibration]; history = bundle[:history],
        cfg = OnlineConfig(local_file = feed_file), model = Sym(get(bundle, :model, :mmc)),
        plan = ReevaluationPlan(7, :days), log_path = joinpath(ROOT, "data", "reevaluation_log.json"));
    SymDict(:verdict => record[:verdict], :reason => record[:reason],
        :source => record[:source], :worst_change => record[:worst_change],
        :ks_tests => length(record[:ks]))
end

# ╔═╡ e1512072-9d08-4847-9c5d-29fc9127e51f
begin
log_rows = reevaluation_log(joinpath(ROOT, "data", "reevaluation_log.json"))
    (last = isempty(log_rows) ? SymDict(:note => :empty) : feed_row(log_rows[end]),
        entries = length(log_rows))
end

# ╔═╡ 69d991a4-cbe8-48c3-9d63-f744c8a58ec3
begin
plan = ReevaluationPlan(7, :days)
    SymDict(:plan => describe_plan(plan), :days => plan_days(plan),
        :due_after_3_days => due(plan, timestamp(Dates.now() - Dates.Day(3)), timestamp()),
        :due_after_30_days => due(plan, timestamp(Dates.now() - Dates.Day(30)), timestamp()))
end

# ╔═╡ 1ea320e9-875f-4b63-88ed-62e547cfeeed
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_online.html` and
`reports/pdf/notebook_online.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ 74075d75-9030-4b53-83ce-a90850ae5615
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :online; root = ROOT)
end

# ╔═╡ 9899beec-1c27-4cdc-acdb-954dace459bd
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═333e35e6-d4af-46ab-8f69-e14920dbca29
# ╠═a6dc70e4-7635-47fe-a763-e7ee8eff459e
# ╠═2ded2965-e509-4af2-9c0d-89578794b789
# ╠═afe119ea-051b-495a-8a7f-14f84d7fca77
# ╠═ede5abc5-7cbb-4fec-bc18-ee97f87a7f68
# ╠═ce61b177-68c8-48b6-a781-0bd242f32a42
# ╠═d7c1b360-226e-49a3-b7a8-1a483d43b80b
# ╠═301e469b-de94-4bfe-9740-ab10c5f54d6f
# ╠═bd68f55c-3155-4d0e-ad87-b49a8ad41d8a
# ╠═03611bca-1bcb-41b3-9fcb-7c81d3d9f16b
# ╠═4b5b12a1-7ad3-4758-ab6f-81b5e1046f02
# ╠═315e3056-d670-4861-b634-11a2adc45b2c
# ╠═9d2687c4-52a8-4426-a445-827da54e6f25
# ╠═bf4fd19b-be2b-461a-96b3-7e8e018c06eb
# ╠═27b02e61-5b9d-493a-abad-0a70eb122646
# ╠═fc77d23e-89c7-4a74-b4ec-1438822c8abc
# ╠═e1512072-9d08-4847-9c5d-29fc9127e51f
# ╠═69d991a4-cbe8-48c3-9d63-f744c8a58ec3
# ╠═1ea320e9-875f-4b63-88ed-62e547cfeeed
# ╠═74075d75-9030-4b53-83ce-a90850ae5615
# ╠═9899beec-1c27-4cdc-acdb-954dace459bd
