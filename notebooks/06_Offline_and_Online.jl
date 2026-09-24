### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 36acdd1a-fb8e-4ad6-b59f-98641f41d148
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ 27ff5599-a085-4d7f-ab43-bb2fd0de058b
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ 37cd9a8c-ef0a-415b-b564-a0f55fbdde92
md"""
# Offline first, online for periodic reevaluation

A feed that never breaks the pipeline, and the decision it justifies.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ 240e3e7a-bac9-4e13-9caa-ce597766f1a9
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ b1dcc384-34a1-4583-93d4-f4fc1c824301
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ d4ef8728-7b8d-404e-ad08-6406357384ce
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ aa52736a-46a5-415d-8e32-0aacc9fce769
begin
bundle = load_study(ROOT);
end

# ╔═╡ 5ba8b9d3-c085-4911-ad28-1fcc3054186d
begin
TableOfContents()
end

# ╔═╡ 81b0d553-93c9-4c45-b9f2-a388e0575dce
md"""
## The section: *Online*
"""

# ╔═╡ 1b887bee-719f-4318-a530-893ce315c539
begin
HTML(preview_section(bundle, :online))
end

# ╔═╡ 696631ee-02b5-4c14-b54b-f111ff592625
md"""
## The fallback chain, live

The data layer never fails. Ask for the periodic feed and it walks down the chain:
the online source, the local copy of the same feed, the last cached reply, and
finally offline with whatever the model already knows.
"""

# ╔═╡ d402ce05-a4ce-4c7a-a1ac-7a2c8b50aef3
begin
reachable = fetch_online(OnlineConfig())
    SymDict(:url => reachable[:url], :status => reachable[:status], :source => reachable[:source],
        :freshness => reachable[:freshness], :attempts => reachable[:attempts],
        :age_days => get(reachable, :age_days, NaN))
end

# ╔═╡ b54e4b43-4c55-4aa0-8583-8f0c01a125ee
begin
feed_file = joinpath(ROOT, "data", "online_feed.json")
    blocked = fetch_online(OnlineConfig(url = "http://127.0.0.1:9/nothing",
        local_file = feed_file, timeout = 1.0, retries = 0))
    counts = get(blocked, :observations, nothing)
    SymDict(:status => blocked[:status], :source => blocked[:source],
        :fallback => get(blocked, :fallback, :none),
        :series => counts === nothing ? 0 : length(counts))
end

# ╔═╡ cc40f289-a88a-482b-8fca-7719f99f3771
begin
offline = fetch_online(OnlineConfig(url = "http://127.0.0.1:9/nothing",
        local_file = joinpath(ROOT, "data", "missing.json"), timeout = 1.0, retries = 0,
        cache_dir = joinpath(ROOT, "tmp", "empty_cache")))
    SymDict(:status => offline[:status], :source => offline[:source],
        :freshness => offline[:freshness])
end

# ╔═╡ ec028d2b-f834-4e26-8063-b425a7b58b3b
md"""
## The decision the feed justifies

A reevaluation round recalibrates from the freshest observations, compares them
with the model in use (relative change per parameter, and a two-sample
Kolmogorov--Smirnov test per series) and writes a verdict. The log is the audit
trail: when the model was checked, against what, and what was decided.
"""

# ╔═╡ df0913ba-e0c7-4726-98b8-316fe2a8d7f0
begin
record = reevaluate(bundle[:calibration]; cfg = OnlineConfig(local_file = feed_file),
        model = Sym(get(bundle, :model, :mmc)), plan = ReevaluationPlan(7, :days),
        log_path = joinpath(ROOT, "data", "reevaluation_log.json"));
    SymDict(:verdict => record[:verdict], :reason => record[:reason],
        :source => record[:source], :worst_change => record[:worst_change],
        :ks_tests => length(record[:ks]))
end

# ╔═╡ 541c3c9f-d062-4888-8ffd-aae8bef4da3d
begin
log_rows = reevaluation_log(joinpath(ROOT, "data", "reevaluation_log.json"))
    (last = isempty(log_rows) ? SymDict(:note => :empty) : feed_row(log_rows[end]),
        entries = length(log_rows))
end

# ╔═╡ bb7e5823-c3cd-4383-b0d3-4182916cd34c
begin
plan = ReevaluationPlan(7, :days)
    SymDict(:plan => describe_plan(plan), :days => plan_days(plan),
        :due_after_3_days => due(plan, timestamp(Dates.now() - Dates.Day(3)), timestamp()),
        :due_after_30_days => due(plan, timestamp(Dates.now() - Dates.Day(30)), timestamp()))
end

# ╔═╡ 71f1ca1e-a5ec-4fc1-8de9-7597c11b9a7e
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_online.html` and
`reports/pdf/notebook_online.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ cd034489-76a1-4290-aea4-27d2f86e847f
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :online; root = ROOT)
end

# ╔═╡ 619dcd70-c6eb-4bc6-9da7-8d1fafa0dec3
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═37cd9a8c-ef0a-415b-b564-a0f55fbdde92
# ╠═240e3e7a-bac9-4e13-9caa-ce597766f1a9
# ╠═36acdd1a-fb8e-4ad6-b59f-98641f41d148
# ╠═27ff5599-a085-4d7f-ab43-bb2fd0de058b
# ╠═b1dcc384-34a1-4583-93d4-f4fc1c824301
# ╠═d4ef8728-7b8d-404e-ad08-6406357384ce
# ╠═aa52736a-46a5-415d-8e32-0aacc9fce769
# ╠═5ba8b9d3-c085-4911-ad28-1fcc3054186d
# ╠═81b0d553-93c9-4c45-b9f2-a388e0575dce
# ╠═1b887bee-719f-4318-a530-893ce315c539
# ╠═696631ee-02b5-4c14-b54b-f111ff592625
# ╠═d402ce05-a4ce-4c7a-a1ac-7a2c8b50aef3
# ╠═b54e4b43-4c55-4aa0-8583-8f0c01a125ee
# ╠═cc40f289-a88a-482b-8fca-7719f99f3771
# ╠═ec028d2b-f834-4e26-8063-b425a7b58b3b
# ╠═df0913ba-e0c7-4726-98b8-316fe2a8d7f0
# ╠═541c3c9f-d062-4888-8ffd-aae8bef4da3d
# ╠═bb7e5823-c3cd-4383-b0d3-4182916cd34c
# ╠═71f1ca1e-a5ec-4fc1-8de9-7597c11b9a7e
# ╠═cd034489-76a1-4290-aea4-27d2f86e847f
# ╠═619dcd70-c6eb-4bc6-9da7-8d1fafa0dec3
