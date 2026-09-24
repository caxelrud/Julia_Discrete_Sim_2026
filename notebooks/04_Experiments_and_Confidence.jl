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

# ╔═╡ ac3a043e-050f-497c-96ac-c4f1f157b7d3
md"""
# Experiments, warmup and confidence

Why one run is not an answer: replications, Welch's warmup, batch means and common random numbers.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ 15618257-69e3-45a7-bba3-858726835989
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ 2688a88d-7a7b-4a9e-8d43-89be627e534d
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ 22b1037c-34e1-4f2f-b9f8-369184f0dfc5
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ b2e73c55-1e81-4049-a990-c951b1d8b0b4
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ 75b9c753-a0d6-4101-98f5-83b75276e31a
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ 3041b0b5-3fa4-4e6d-bd3c-4f895cc3cf70
begin
bundle = load_study(ROOT);
end

# ╔═╡ 9feb0980-9ad8-4c2a-bf99-f4e00c4ab5f6
begin
TableOfContents()
end

# ╔═╡ a5306761-efba-4b0f-b125-e5c04bb886e5
md"""
## The section: *Experiments*
"""

# ╔═╡ ede75e86-eeac-4505-9d3d-22e86e3dd0aa
begin
HTML(preview_section(bundle, :experiments))
end

# ╔═╡ 2e78b8cb-b452-4f07-a1e9-db42eb05a502
md"""
## Warmup: how long the transient lasts

Welch's procedure, run live on a small queue: the moving average of the response
settles, and the time where it settles is the warmup the study should use.
"""

# ╔═╡ 873a828a-935b-4619-a74b-5bb8e88cc1a6
begin
demo = model_params(:mmc, (arrival_rate = 0.85, service_rate = 1.0, servers = 1))
    warming = warmup_analysis(opts -> build_model(:mmc, demo, opts),
        ExperimentConfig(replications = 5, horizon = 3000.0); series = :wip, window = 15)
    SymDict(:suggested_warmup => warming[:warmup], :plateau => warming[:plateau],
        :band => warming[:band])
end

# ╔═╡ 471594f3-a3b4-4a22-92ae-b2acd02d7208
begin
fig_warmup(warming)
end

# ╔═╡ 78f8d4b9-9744-4409-a1fb-33ba9451d302
md"""
## Replications and intervals

One run of a queue gives a number; several give a number *and* an interval. The
cell below runs six replications, reports the interval of the mean waiting time,
and asks how many replications a 5% relative precision would need.
"""

# ╔═╡ 12f5b7a5-b6ad-4d1f-a915-dc718049be1c
begin
config = ExperimentConfig(replications = 6, horizon = 3000.0, warmup = 300.0)
    replicated = experiment(opts -> build_model(:mmc, demo, opts), config; name = :mmc_ci);
    wait_ci = metric_ci(replicated, :wait_mean)
    SymDict(:mean => wait_ci[:mean], :half_width => wait_ci[:half_width],
        :relative_half_width => wait_ci[:relative_half_width],
        :needed_for_5pct => required_replications(metric_series(replicated, :wait_mean)))
end

# ╔═╡ c8b4f28f-2e5f-4935-89ef-6c0c6d91ae29
md"""
## Common random numbers

Two scenarios run with the *same* seeds in the same replication are paired, so the
difference of their means has a much tighter interval than either mean: that is
what makes a comparison of two designs decisive.
"""

# ╔═╡ 33c2dab1-b6d6-47be-9436-6f15652bc4f3
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

# ╔═╡ ea3cf2e0-722d-40d9-97ab-97f44bc1bc4f
begin
bundle[:batch_means]
end

# ╔═╡ ca9689ad-5994-49b5-85eb-d971ce581cb9
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_experiments.html` and
`reports/pdf/notebook_experiments.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ 442fb02f-515f-4cae-8c12-3f6a170b6dae
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :experiments; root = ROOT)
end

# ╔═╡ a4bd23b6-5286-4616-8541-829883f076ee
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═ac3a043e-050f-497c-96ac-c4f1f157b7d3
# ╠═15618257-69e3-45a7-bba3-858726835989
# ╠═2688a88d-7a7b-4a9e-8d43-89be627e534d
# ╠═22b1037c-34e1-4f2f-b9f8-369184f0dfc5
# ╠═b2e73c55-1e81-4049-a990-c951b1d8b0b4
# ╠═75b9c753-a0d6-4101-98f5-83b75276e31a
# ╠═3041b0b5-3fa4-4e6d-bd3c-4f895cc3cf70
# ╠═9feb0980-9ad8-4c2a-bf99-f4e00c4ab5f6
# ╠═a5306761-efba-4b0f-b125-e5c04bb886e5
# ╠═ede75e86-eeac-4505-9d3d-22e86e3dd0aa
# ╠═2e78b8cb-b452-4f07-a1e9-db42eb05a502
# ╠═873a828a-935b-4619-a74b-5bb8e88cc1a6
# ╠═471594f3-a3b4-4a22-92ae-b2acd02d7208
# ╠═78f8d4b9-9744-4409-a1fb-33ba9451d302
# ╠═12f5b7a5-b6ad-4d1f-a915-dc718049be1c
# ╠═c8b4f28f-2e5f-4935-89ef-6c0c6d91ae29
# ╠═33c2dab1-b6d6-47be-9436-6f15652bc4f3
# ╠═ea3cf2e0-722d-40d9-97ab-97f44bc1bc4f
# ╠═ca9689ad-5994-49b5-85eb-d971ce581cb9
# ╠═442fb02f-515f-4cae-8c12-3f6a170b6dae
# ╠═a4bd23b6-5286-4616-8541-829883f076ee
