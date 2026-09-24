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

# ╔═╡ b773697a-49cf-4750-b605-93e5b587aa26
md"""
# Experiments, warmup and confidence

Why one run is not an answer: replications, Welch's warmup, batch means and common random numbers.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ 7d2f867a-8bc3-400b-863a-ab51973e6c6c
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ 717bfa85-cef5-434e-9514-8755402d21c8
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ 0936c9f5-1d8c-4318-906a-8ec64c9ebcb7
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ 61e39b7f-083b-4e3f-8204-33e01050f472
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ 0b9a1741-043e-4564-87b3-044f8225b1f3
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ 57ad6687-64dc-4362-b3ee-c5576efad51a
begin
bundle = load_study(ROOT);
end

# ╔═╡ 3165ba74-0546-4f6b-894f-7c09e69f522b
begin
TableOfContents()
end

# ╔═╡ bdfac292-41eb-4f71-a73f-165af12a0337
md"""
## The section: *Experiments*
"""

# ╔═╡ 392b7789-2f96-48e8-ba78-2a29e8edc3b6
begin
HTML(preview_section(bundle, :experiments))
end

# ╔═╡ 29d6f9dd-556c-4e06-b1bf-2d0bacb1635a
md"""
## Warmup: how long the transient lasts

Welch's procedure, run live on a small queue: the moving average of the response
settles, and the time where it settles is the warmup the study should use.
"""

# ╔═╡ 692cf5a8-6d7e-4486-a3ff-40c1d5a219d9
begin
demo = model_params(:mmc, (arrival_rate = 0.85, service_rate = 1.0, servers = 1))
    warming = warmup_analysis(opts -> build_model(:mmc, demo, opts),
        ExperimentConfig(replications = 5, horizon = 3000.0); series = :wip, window = 15)
    SymDict(:suggested_warmup => warming[:warmup], :plateau => warming[:plateau],
        :band => warming[:band])
end

# ╔═╡ b1e2b428-ad5e-481d-8044-359031cbfb41
begin
fig_warmup(warming)
end

# ╔═╡ 8e7b88b2-c72f-4389-afa4-364d397f9640
md"""
## Replications and intervals

One run of a queue gives a number; several give a number *and* an interval. The
cell below runs six replications, reports the interval of the mean waiting time,
and asks how many replications a 5% relative precision would need.
"""

# ╔═╡ 90c9e2cb-07de-42f3-887d-bd7522bd2253
begin
config = ExperimentConfig(replications = 6, horizon = 3000.0, warmup = 300.0)
    replicated = experiment(opts -> build_model(:mmc, demo, opts), config; name = :mmc_ci);
    wait_ci = metric_ci(replicated, :wait_mean)
    SymDict(:mean => wait_ci[:mean], :half_width => wait_ci[:half_width],
        :relative_half_width => wait_ci[:relative_half_width],
        :needed_for_5pct => required_replications(metric_series(replicated, :wait_mean)))
end

# ╔═╡ 1fb6bc48-2916-4eb7-bfe4-4164b4e296e0
md"""
## Common random numbers

Two scenarios run with the *same* seeds in the same replication are paired, so the
difference of their means has a much tighter interval than either mean: that is
what makes a comparison of two designs decisive.
"""

# ╔═╡ ee73036b-1b32-4c55-8e50-9cba429b62dc
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

# ╔═╡ a673b248-3f69-492f-90c3-9c036437e2d8
begin
bundle[:batch_means]
end

# ╔═╡ cdbcebc1-c87c-4386-97fb-59d106d7b0a8
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_experiments.html` and
`reports/pdf/notebook_experiments.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ 8d53310b-1c94-4956-a6d2-a012b2a2c6f9
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :experiments; root = ROOT)
end

# ╔═╡ b92020fb-d68f-43a8-ad59-cadb45280572
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═b773697a-49cf-4750-b605-93e5b587aa26
# ╠═7d2f867a-8bc3-400b-863a-ab51973e6c6c
# ╠═717bfa85-cef5-434e-9514-8755402d21c8
# ╠═0936c9f5-1d8c-4318-906a-8ec64c9ebcb7
# ╠═61e39b7f-083b-4e3f-8204-33e01050f472
# ╠═0b9a1741-043e-4564-87b3-044f8225b1f3
# ╠═57ad6687-64dc-4362-b3ee-c5576efad51a
# ╠═3165ba74-0546-4f6b-894f-7c09e69f522b
# ╠═bdfac292-41eb-4f71-a73f-165af12a0337
# ╠═392b7789-2f96-48e8-ba78-2a29e8edc3b6
# ╠═29d6f9dd-556c-4e06-b1bf-2d0bacb1635a
# ╠═692cf5a8-6d7e-4486-a3ff-40c1d5a219d9
# ╠═b1e2b428-ad5e-481d-8044-359031cbfb41
# ╠═8e7b88b2-c72f-4389-afa4-364d397f9640
# ╠═90c9e2cb-07de-42f3-887d-bd7522bd2253
# ╠═1fb6bc48-2916-4eb7-bfe4-4164b4e296e0
# ╠═ee73036b-1b32-4c55-8e50-9cba429b62dc
# ╠═a673b248-3f69-492f-90c3-9c036437e2d8
# ╠═cdbcebc1-c87c-4386-97fb-59d106d7b0a8
# ╠═8d53310b-1c94-4956-a6d2-a012b2a2c6f9
# ╠═b92020fb-d68f-43a8-ad59-cadb45280572
