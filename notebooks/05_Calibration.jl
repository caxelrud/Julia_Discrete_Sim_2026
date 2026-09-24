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

# ╔═╡ 6b5e253c-83d0-426d-925d-8828fd99ddcb
md"""
# Calibration from plant data

Where the numbers in the model come from, and how well they fit.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ bee414b9-1283-4146-9da2-61eca5a4dda1
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ 1f3781cf-c2fd-4e52-a34b-5e2642a67ab6
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ bb3aea0b-fd69-47ac-969b-e86e19660898
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ 11c3d7b5-02ff-43fe-85ef-f0130ab5d4ad
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ 661d8943-eab7-4731-829f-857ab4355271
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ a7e26416-c57b-4c99-856c-b370c24bcc58
begin
bundle = load_study(ROOT);
end

# ╔═╡ 1801fc32-9b94-434e-92b0-732e9e576372
begin
TableOfContents()
end

# ╔═╡ bf870850-0794-4a08-a255-5799393487ff
md"""
## The section: *Calibration*
"""

# ╔═╡ de745089-8136-4cff-8c71-98de4fb37769
begin
HTML(preview_section(bundle, :calibration))
end

# ╔═╡ d5d60e17-44ce-4fc4-ba32-7b6d1dcbb9ca
md"""
## Fitting by hand

The pipeline fitted every series of the plant history. Here is the same work done
in the open: take a sample, fit four families by maximum likelihood, and let the
Kolmogorov--Smirnov statistic decide which one can be defended.
"""

# ╔═╡ dd87cd83-5c32-4bc3-8cb0-c3d1c29736b4
begin
truth = SymDict(:mean => 3.0, :shape => 4.0)
    γ_sample = let σ = Sim(:fit_demo; seed = 20260101)
        sample_n(σ, :demo, :gamma => (truth[:shape], truth[:mean] / truth[:shape]), 400)
    end
    best_fit(γ_sample; kinds = (:exponential, :lognormal, :gamma, :weibull))[:kind]
end

# ╔═╡ 592219db-042a-4a53-b7a4-5c9eb4f26ddc
begin
fitted = best_fit(γ_sample)
    table_html([SymDict(:family => k, :rank => rank[:rank], :ks_stat => rank[:ks_stat],
            :ks_p => rank[:ks_p], :aic => rank[:aic]) for (k, rank) in fitted[:ranking]],
        [:family, :rank, :ks_stat, :ks_p, :aic]) |> HTML
end

# ╔═╡ 27669edb-ee24-4466-9aac-f3c18b4787b5
begin
fig_calibration(γ_sample, fitted; series = :demo)
end

# ╔═╡ c5dc3931-d725-4521-a28b-846e973f714a
md"""
## How uncertain is a parameter?

The bootstrap resamples the observations, refits and reports the percentiles: that
is the interval a calibration report quotes for every fitted parameter.
"""

# ╔═╡ 9bb958c9-03e2-4650-90de-382705fe85e2
begin
interval = bootstrap_ci(γ_sample, fitted[:kind], 1; reps = 80)
    SymDict(:family => fitted[:kind], :parameter => fitted[:params][1],
        :median => interval[:median], :lo => interval[:lo], :hi => interval[:hi])
end

# ╔═╡ a75e5df6-cde4-47f3-86dc-72b0f5fdc2c5
md"""
## What the plant data says about the model

`calibrate` does all of the above for every measured series, and
`model_params_from_calibration` turns the result into model parameters -- the ones
the pipeline then simulated.
"""

# ╔═╡ 36766eb8-ae77-480c-ac16-1eb273e4201e
begin
from_data = bundle[:calibration][:parameters]
    SymDict(:arrival_rate => get(from_data, :arrival_rate, NaN),
        :service_rate => get(from_data, :service_rate, NaN),
        :mtbf => get(from_data, :mtbf, NaN), :mttr => get(from_data, :mttr, NaN),
        :availability => get(from_data, :availability, NaN))
end

# ╔═╡ 29d28d44-bbdb-4eed-8f2d-decbaf93a2e6
begin
bundle[:history][:summary]
end

# ╔═╡ 9c93f5c7-f82e-4b9e-a565-49e48787a176
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_calibration.html` and
`reports/pdf/notebook_calibration.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ d83194fe-a2d4-4311-ad4b-800b42c96e7e
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :calibration; root = ROOT)
end

# ╔═╡ 9948df70-d4fe-49c6-8dc0-fee525da79ea
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═6b5e253c-83d0-426d-925d-8828fd99ddcb
# ╠═bee414b9-1283-4146-9da2-61eca5a4dda1
# ╠═1f3781cf-c2fd-4e52-a34b-5e2642a67ab6
# ╠═bb3aea0b-fd69-47ac-969b-e86e19660898
# ╠═11c3d7b5-02ff-43fe-85ef-f0130ab5d4ad
# ╠═661d8943-eab7-4731-829f-857ab4355271
# ╠═a7e26416-c57b-4c99-856c-b370c24bcc58
# ╠═1801fc32-9b94-434e-92b0-732e9e576372
# ╠═bf870850-0794-4a08-a255-5799393487ff
# ╠═de745089-8136-4cff-8c71-98de4fb37769
# ╠═d5d60e17-44ce-4fc4-ba32-7b6d1dcbb9ca
# ╠═dd87cd83-5c32-4bc3-8cb0-c3d1c29736b4
# ╠═592219db-042a-4a53-b7a4-5c9eb4f26ddc
# ╠═27669edb-ee24-4466-9aac-f3c18b4787b5
# ╠═c5dc3931-d725-4521-a28b-846e973f714a
# ╠═9bb958c9-03e2-4650-90de-382705fe85e2
# ╠═a75e5df6-cde4-47f3-86dc-72b0f5fdc2c5
# ╠═36766eb8-ae77-480c-ac16-1eb273e4201e
# ╠═29d28d44-bbdb-4eed-8f2d-decbaf93a2e6
# ╠═9c93f5c7-f82e-4b9e-a565-49e48787a176
# ╠═d83194fe-a2d4-4311-ad4b-800b42c96e7e
# ╠═9948df70-d4fe-49c6-8dc0-fee525da79ea
