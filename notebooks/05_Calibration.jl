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

# ╔═╡ 983beb22-c102-463b-a9d7-6fe7ed35928a
md"""
# Calibration from plant data

Where the numbers in the model come from, and how well they fit.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ 3f002958-bc36-4e8a-90ab-5e13b82e8bcb
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ 008b9e3f-43b7-4198-9e6a-3cff17206889
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ 5bdd5d5e-b54b-4dbf-a5cd-2c6416d30a3d
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ 08a6c8b7-3cc3-40a6-a40c-b0b5a971328d
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ d2e4e1c5-38ec-46d3-a5b7-971c6a242443
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ 9d4b0d3e-b414-4f04-8cbc-fecb802bcb05
begin
bundle = load_study(ROOT);
end

# ╔═╡ 76dc12f7-b102-4db4-a1cc-8631b47cace6
begin
TableOfContents()
end

# ╔═╡ 3807ed65-5909-4a95-9667-50d0b2fee65c
md"""
## The section: *Calibration*
"""

# ╔═╡ ce2e6aac-cc3f-4c93-aa19-899623e46593
begin
HTML(preview_section(bundle, :calibration))
end

# ╔═╡ a685d1ec-4692-42aa-ae07-0df141ff2933
md"""
## Fitting by hand

The pipeline fitted every series of the plant history. Here is the same work done
in the open: take a sample, fit four families by maximum likelihood, and let the
Kolmogorov--Smirnov statistic decide which one can be defended.
"""

# ╔═╡ 11201262-f7fd-4c1a-a808-73e1f6d91b9f
begin
truth = SymDict(:mean => 3.0, :shape => 4.0)
    γ_sample = let σ = Sim(:fit_demo; seed = 20260101)
        sample_n(σ, :demo, :gamma => (truth[:shape], truth[:mean] / truth[:shape]), 400)
    end
    best_fit(γ_sample; kinds = (:exponential, :lognormal, :gamma, :weibull))[:kind]
end

# ╔═╡ 7d435eed-8e74-4e4f-9a08-203cdf12c6d0
begin
fitted = best_fit(γ_sample)
    table_html([SymDict(:family => k, :rank => rank[:rank], :ks_stat => rank[:ks_stat],
            :ks_p => rank[:ks_p], :aic => rank[:aic]) for (k, rank) in fitted[:ranking]],
        [:family, :rank, :ks_stat, :ks_p, :aic]) |> HTML
end

# ╔═╡ 68d54d20-d530-4c6a-ae22-14fdde6d5feb
begin
fig_calibration(γ_sample, fitted; series = :demo)
end

# ╔═╡ 61608992-b4ca-4ba9-bc8c-839f3d56a573
md"""
## How uncertain is a parameter?

The bootstrap resamples the observations, refits and reports the percentiles: that
is the interval a calibration report quotes for every fitted parameter.
"""

# ╔═╡ 45aa04cc-2ad3-43af-991d-d95fad55179b
begin
interval = bootstrap_ci(γ_sample, fitted[:kind], 1; reps = 80)
    SymDict(:family => fitted[:kind], :parameter => fitted[:params][1],
        :median => interval[:median], :lo => interval[:lo], :hi => interval[:hi])
end

# ╔═╡ fa5f1371-d735-4f11-bcc2-a327cd112cfb
md"""
## What the plant data says about the model

`calibrate` does all of the above for every measured series, and
`model_params_from_calibration` turns the result into model parameters -- the ones
the pipeline then simulated.
"""

# ╔═╡ f3807940-c3a6-4f11-bac7-9318e2494575
begin
from_data = bundle[:calibration][:parameters]
    SymDict(:arrival_rate => get(from_data, :arrival_rate, NaN),
        :service_rate => get(from_data, :service_rate, NaN),
        :mtbf => get(from_data, :mtbf, NaN), :mttr => get(from_data, :mttr, NaN),
        :availability => get(from_data, :availability, NaN))
end

# ╔═╡ 95e5d9a1-a156-4ad0-a07e-63c30b949446
begin
bundle[:history][:summary]
end

# ╔═╡ 31ed2d93-38d5-4842-8575-107bc58a145a
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_calibration.html` and
`reports/pdf/notebook_calibration.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ 26dedd01-28eb-4b88-b813-0ea527ef7d51
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :calibration; root = ROOT)
end

# ╔═╡ efa2d340-3322-4da9-80f1-c6f6cb66944b
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═983beb22-c102-463b-a9d7-6fe7ed35928a
# ╠═3f002958-bc36-4e8a-90ab-5e13b82e8bcb
# ╠═008b9e3f-43b7-4198-9e6a-3cff17206889
# ╠═5bdd5d5e-b54b-4dbf-a5cd-2c6416d30a3d
# ╠═08a6c8b7-3cc3-40a6-a40c-b0b5a971328d
# ╠═d2e4e1c5-38ec-46d3-a5b7-971c6a242443
# ╠═9d4b0d3e-b414-4f04-8cbc-fecb802bcb05
# ╠═76dc12f7-b102-4db4-a1cc-8631b47cace6
# ╠═3807ed65-5909-4a95-9667-50d0b2fee65c
# ╠═ce2e6aac-cc3f-4c93-aa19-899623e46593
# ╠═a685d1ec-4692-42aa-ae07-0df141ff2933
# ╠═11201262-f7fd-4c1a-a808-73e1f6d91b9f
# ╠═7d435eed-8e74-4e4f-9a08-203cdf12c6d0
# ╠═68d54d20-d530-4c6a-ae22-14fdde6d5feb
# ╠═61608992-b4ca-4ba9-bc8c-839f3d56a573
# ╠═45aa04cc-2ad3-43af-991d-d95fad55179b
# ╠═fa5f1371-d735-4f11-bcc2-a327cd112cfb
# ╠═f3807940-c3a6-4f11-bac7-9318e2494575
# ╠═95e5d9a1-a156-4ad0-a07e-63c30b949446
# ╠═31ed2d93-38d5-4842-8575-107bc58a145a
# ╠═26dedd01-28eb-4b88-b813-0ea527ef7d51
# ╠═efa2d340-3322-4da9-80f1-c6f6cb66944b
