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

# ╔═╡ cf3131ce-5c42-4715-b97a-3fb1282c54aa
md"""
# Experiments, warmup and confidence

Why one run is not an answer: replications, Welch's warmup, batch means and common random numbers.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ d85b6182-f3d7-4588-8dcc-dc47f3947a7e
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ 09cdc635-cc18-43e4-8857-babf36db5f2f
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ 2724f95e-89a5-4318-8a58-27b31d82b9c8
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ 99a3f48a-5ac9-4b44-a631-f4fb04af867d
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ 9966d148-c3c5-4a98-819a-b56649fa9b38
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ f8add668-012e-4f51-84c6-8147051919cb
begin
bundle = load_study(ROOT);
end

# ╔═╡ b01aa22f-ebf1-4996-91ea-85e1ee9c22e7
begin
TableOfContents()
end

# ╔═╡ 42006254-d8b7-417c-90f4-a0415dc91253
md"""
## The section: *Experiments*
"""

# ╔═╡ 9c3c002b-6324-433d-9432-8f281045b138
begin
HTML(preview_section(bundle, :experiments))
end

# ╔═╡ a9899ceb-ee5b-4fd6-895e-82e998e6da3e
md"""
## Warmup: how long the transient lasts

Welch's procedure, run live on a small queue: the moving average of the response
settles, and the time where it settles is the warmup the study should use.
"""

# ╔═╡ 786062ab-fe10-4411-9fa9-ac3e33e31d0f
begin
demo = model_params(:mmc, (arrival_rate = 0.85, service_rate = 1.0, servers = 1))
    warming = warmup_analysis(opts -> build_model(:mmc, demo, opts),
        ExperimentConfig(replications = 5, horizon = 3000.0); series = :wip, window = 15)
    SymDict(:suggested_warmup => warming[:warmup], :plateau => warming[:plateau],
        :band => warming[:band])
end

# ╔═╡ 8cb0a1bc-490a-4ffe-8c72-eed79687915f
begin
fig_warmup(warming)
end

# ╔═╡ c5025cda-36f7-47e0-af0c-ced70db8c09a
md"""
## Replications and intervals

One run of a queue gives a number; several give a number *and* an interval. The
cell below runs six replications, reports the interval of the mean waiting time,
and asks how many replications a 5% relative precision would need.
"""

# ╔═╡ bf3ac475-d548-4daf-be70-f6e7edcd7be5
begin
config = ExperimentConfig(replications = 6, horizon = 3000.0, warmup = 300.0)
    replicated = experiment(opts -> build_model(:mmc, demo, opts), config; name = :mmc_ci);
    wait_ci = metric_ci(replicated, :wait_mean)
    SymDict(:mean => wait_ci[:mean], :half_width => wait_ci[:half_width],
        :relative_half_width => wait_ci[:relative_half_width],
        :needed_for_5pct => required_replications(metric_series(replicated, :wait_mean)))
end

# ╔═╡ fd13a4ef-288d-4728-a897-a2eba578911e
md"""
## Common random numbers

Two scenarios run with the *same* seeds in the same replication are paired, so the
difference of their means has a much tighter interval than either mean: that is
what makes a comparison of two designs decisive.
"""

# ╔═╡ 83914eae-b9f3-4d24-82ac-054c9fe9523e
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

# ╔═╡ e93bc7f8-ccfc-4c72-96c4-7b36d0cb7e77
begin
bundle[:batch_means]
end

# ╔═╡ 45d0a1a0-65d0-4fe8-847d-1bdb3cd39d55
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_experiments.html` and
`reports/pdf/notebook_experiments.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ 55493c22-4de0-4a4d-b7a3-66d0267cc072
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :experiments; root = ROOT)
end

# ╔═╡ 1f71f9b6-0ce9-4e01-82aa-a39a4fde4cf6
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═cf3131ce-5c42-4715-b97a-3fb1282c54aa
# ╠═d85b6182-f3d7-4588-8dcc-dc47f3947a7e
# ╠═09cdc635-cc18-43e4-8857-babf36db5f2f
# ╠═2724f95e-89a5-4318-8a58-27b31d82b9c8
# ╠═99a3f48a-5ac9-4b44-a631-f4fb04af867d
# ╠═9966d148-c3c5-4a98-819a-b56649fa9b38
# ╠═f8add668-012e-4f51-84c6-8147051919cb
# ╠═b01aa22f-ebf1-4996-91ea-85e1ee9c22e7
# ╠═42006254-d8b7-417c-90f4-a0415dc91253
# ╠═9c3c002b-6324-433d-9432-8f281045b138
# ╠═a9899ceb-ee5b-4fd6-895e-82e998e6da3e
# ╠═786062ab-fe10-4411-9fa9-ac3e33e31d0f
# ╠═8cb0a1bc-490a-4ffe-8c72-eed79687915f
# ╠═c5025cda-36f7-47e0-af0c-ced70db8c09a
# ╠═bf3ac475-d548-4daf-be70-f6e7edcd7be5
# ╠═fd13a4ef-288d-4728-a897-a2eba578911e
# ╠═83914eae-b9f3-4d24-82ac-054c9fe9523e
# ╠═e93bc7f8-ccfc-4c72-96c4-7b36d0cb7e77
# ╠═45d0a1a0-65d0-4fe8-847d-1bdb3cd39d55
# ╠═55493c22-4de0-4a4d-b7a3-66d0267cc072
# ╠═1f71f9b6-0ce9-4e01-82aa-a39a4fde4cf6
