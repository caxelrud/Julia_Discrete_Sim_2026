### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 179385f2-1c79-4b30-8759-cd229602a7dd
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ 90dbf86c-167a-4eb2-98cf-1c998a117453
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ 786a3df7-1c2e-49d3-8571-5b6b9ff4745d
md"""
# Experiments, warmup and confidence

Why one run is not an answer: replications, Welch's warmup, batch means and common random numbers.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ ed8d72cf-3a64-4412-ae35-a600c66969c9
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ b096d20c-9fff-47c2-84c8-6c09c50e675e
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ 75d7ff51-a93e-4701-95c9-a7ca6a04a3d7
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ c8ef7236-3bfb-49b0-bee7-308e990f8b1c
begin
bundle = load_study(ROOT);
end

# ╔═╡ c6137533-bdeb-4ec3-8825-ddccda6ce69a
begin
TableOfContents()
end

# ╔═╡ 647d37a3-43e4-4553-97a5-65dfc4ef9f79
md"""
## The section: *Experiments*
"""

# ╔═╡ 2744b334-a4d9-4056-9aed-4893c988fad1
begin
HTML(preview_section(bundle, :experiments))
end

# ╔═╡ 55bb0af6-ea1f-4850-ac06-2aa7d6c014bb
md"""
## Warmup: how long the transient lasts

Welch's procedure, run live on a small queue: the moving average of the response
settles, and the time where it settles is the warmup the study should use.
"""

# ╔═╡ 1f0f0934-d93d-44f6-a70a-24293c9a481f
begin
demo = model_params(:mmc, (arrival_rate = 0.85, service_rate = 1.0, servers = 1))
    warming = warmup_analysis(opts -> build_model(:mmc, demo, opts),
        ExperimentConfig(replications = 5, horizon = 3000.0); series = :wip, window = 15)
    SymDict(:suggested_warmup => warming[:warmup], :plateau => warming[:plateau],
        :band => warming[:band])
end

# ╔═╡ 0f82b861-4f1b-4791-aa38-25e63814f7a0
begin
fig_warmup(warming)
end

# ╔═╡ 34d8e466-81d9-4523-84cb-fad48e576c82
md"""
## Replications and intervals

One run of a queue gives a number; several give a number *and* an interval. The
cell below runs six replications, reports the interval of the mean waiting time,
and asks how many replications a 5% relative precision would need.
"""

# ╔═╡ 3fae1f80-c101-4545-a70f-ee0b81393c86
begin
config = ExperimentConfig(replications = 6, horizon = 3000.0, warmup = 300.0)
    replicated = experiment(opts -> build_model(:mmc, demo, opts), config; name = :mmc_ci);
    wait_ci = metric_ci(replicated, :wait_mean)
    SymDict(:mean => wait_ci[:mean], :half_width => wait_ci[:half_width],
        :relative_half_width => wait_ci[:relative_half_width],
        :needed_for_5pct => required_replications(metric_series(replicated, :wait_mean)))
end

# ╔═╡ 638bfbbe-cbff-4dec-9d9f-62f0cb72ba3c
md"""
## Common random numbers

Two scenarios run with the *same* seeds in the same replication are paired, so the
difference of their means has a much tighter interval than either mean: that is
what makes a comparison of two designs decisive.
"""

# ╔═╡ e8931d0d-cdeb-408b-b586-ca6af60a3099
begin
paired = compare_scenarios([
            :baseline => (opts -> build_scenario(:mmc, :baseline, opts)),
            :capacity_up => (opts -> build_scenario(:mmc, :capacity_up, opts))],
        config; objective = :wait_mean);
    comparison = first(filter(c -> c[:metric] === :wait_mean, paired[:comparisons]))
    SymDict(:scenario => comparison[:label], :difference => comparison[:difference],
        :half_width => comparison[:half_width],
        :variance_removed => comparison[:variance_reduction],
        :verdict => comparison[:verdict])
end

# ╔═╡ 8f2b3c77-75cb-4c3a-abc7-8f80f2f6909c
begin
bundle[:batch_means]
end

# ╔═╡ 2e0b2791-5e75-47b3-950f-323de6774e9a
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_experiments.html` and
`reports/pdf/notebook_experiments.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ f3694e9c-b1a5-4d1b-ab2e-cd6317addc6d
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :experiments; root = ROOT)
end

# ╔═╡ 7676645b-ce39-4a2f-8c1e-2fd1cc72c5c3
begin
Markdown.parse(string("---\n",
        "*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed `",
        get(get(bundle, :config, SymDict()), :seed, 0),
        "`). Re-run `julia --project=. scripts/run_study.jl` to refresh every number ",
        "in this notebook.*"))
end

# ╔═╡ Cell order:
# ╠═786a3df7-1c2e-49d3-8571-5b6b9ff4745d
# ╠═ed8d72cf-3a64-4412-ae35-a600c66969c9
# ╠═179385f2-1c79-4b30-8759-cd229602a7dd
# ╠═90dbf86c-167a-4eb2-98cf-1c998a117453
# ╠═b096d20c-9fff-47c2-84c8-6c09c50e675e
# ╠═75d7ff51-a93e-4701-95c9-a7ca6a04a3d7
# ╠═c8ef7236-3bfb-49b0-bee7-308e990f8b1c
# ╠═c6137533-bdeb-4ec3-8825-ddccda6ce69a
# ╠═647d37a3-43e4-4553-97a5-65dfc4ef9f79
# ╠═2744b334-a4d9-4056-9aed-4893c988fad1
# ╠═55bb0af6-ea1f-4850-ac06-2aa7d6c014bb
# ╠═1f0f0934-d93d-44f6-a70a-24293c9a481f
# ╠═0f82b861-4f1b-4791-aa38-25e63814f7a0
# ╠═34d8e466-81d9-4523-84cb-fad48e576c82
# ╠═3fae1f80-c101-4545-a70f-ee0b81393c86
# ╠═638bfbbe-cbff-4dec-9d9f-62f0cb72ba3c
# ╠═e8931d0d-cdeb-408b-b586-ca6af60a3099
# ╠═8f2b3c77-75cb-4c3a-abc7-8f80f2f6909c
# ╠═2e0b2791-5e75-47b3-950f-323de6774e9a
# ╠═f3694e9c-b1a5-4d1b-ab2e-cd6317addc6d
# ╠═7676645b-ce39-4a2f-8c1e-2fd1cc72c5c3
