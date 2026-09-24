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

# ╔═╡ 44a2c7bc-afb1-4de1-a73b-deac6bc66c0c
md"""
# Calibration from plant data

Where the numbers in the model come from, and how well they fit.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ 2b9658f5-acae-4398-bf19-55f28f496a80
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ 45478bcb-596f-4954-a13c-cd935aa56abf
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ c74df7f4-1d9e-4367-b9e4-359b39748582
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ d5eed130-935b-4c52-937d-9920937192f4
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ 041a35d0-fd17-403b-9d30-0cff15854444
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ 2896e23b-2f0b-4d98-86e6-05640d140690
begin
bundle = load_study(ROOT);
end

# ╔═╡ 2e994dd6-d9cf-4ab9-95b5-37a36126d093
begin
TableOfContents()
end

# ╔═╡ 2c513327-74e1-4e2c-b939-74f17e05cc20
md"""
## The section: *Calibration*
"""

# ╔═╡ 7e30fc87-4f45-4742-9944-1dcef3961d64
begin
HTML(preview_section(bundle, :calibration))
end

# ╔═╡ 6afe5771-aca3-45df-9405-97463b60bdc6
md"""
## Fitting by hand

The pipeline fitted every series of the plant history. Here is the same work done
in the open: take a sample, fit four families by maximum likelihood, and let the
Kolmogorov--Smirnov statistic decide which one can be defended.
"""

# ╔═╡ 31dcd56a-f285-4231-940c-3826a6600d17
begin
truth = SymDict(:mean => 3.0, :shape => 4.0)
    γ_sample = let σ = Sim(:fit_demo; seed = 20260101)
        sample_n(σ, :demo, :gamma => (truth[:shape], truth[:mean] / truth[:shape]), 400)
    end
    best_fit(γ_sample; kinds = (:exponential, :lognormal, :gamma, :weibull))[:kind]
end

# ╔═╡ f3065f9b-980f-4ba1-941d-38f5cf59c7b9
begin
fitted = best_fit(γ_sample)
    table_html([SymDict(:family => k, :rank => rank[:rank], :ks_stat => rank[:ks_stat],
            :ks_p => rank[:ks_p], :aic => rank[:aic]) for (k, rank) in fitted[:ranking]],
        [:family, :rank, :ks_stat, :ks_p, :aic]) |> HTML
end

# ╔═╡ 7ac71d19-bf3e-44d5-9eb2-676e4048536e
begin
fig_calibration(γ_sample, fitted; series = :demo)
end

# ╔═╡ 09efac7f-2e82-48c1-bcd8-5145cc192ea1
md"""
## How uncertain is a parameter?

The bootstrap resamples the observations, refits and reports the percentiles: that
is the interval a calibration report quotes for every fitted parameter.
"""

# ╔═╡ 004ae270-8ab2-4581-bccb-3b9a3700f542
begin
interval = bootstrap_ci(γ_sample, fitted[:kind], 1; reps = 80)
    SymDict(:family => fitted[:kind], :parameter => fitted[:params][1],
        :median => interval[:median], :lo => interval[:lo], :hi => interval[:hi])
end

# ╔═╡ e746be87-ead0-464a-8908-c10bd34ee39b
md"""
## What the plant data says about the model

`calibrate` does all of the above for every measured series, and
`model_params_from_calibration` turns the result into model parameters -- the ones
the pipeline then simulated.
"""

# ╔═╡ a6fa0245-65a1-48d0-85e8-f969f885591a
begin
from_data = bundle[:calibration][:parameters]
    SymDict(:arrival_rate => get(from_data, :arrival_rate, NaN),
        :service_rate => get(from_data, :service_rate, NaN),
        :mtbf => get(from_data, :mtbf, NaN), :mttr => get(from_data, :mttr, NaN),
        :availability => get(from_data, :availability, NaN))
end

# ╔═╡ b2fdd573-dbdc-4342-917d-987b2811642f
begin
bundle[:history][:summary]
end

# ╔═╡ 3f4b1065-9116-4a92-9277-9f305c24c461
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_calibration.html` and
`reports/pdf/notebook_calibration.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ 1356707a-88b2-403f-a78f-85ba1c90606f
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :calibration; root = ROOT)
end

# ╔═╡ 9cf34db8-4053-4e99-9d0d-9e79d2582707
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═44a2c7bc-afb1-4de1-a73b-deac6bc66c0c
# ╠═2b9658f5-acae-4398-bf19-55f28f496a80
# ╠═45478bcb-596f-4954-a13c-cd935aa56abf
# ╠═c74df7f4-1d9e-4367-b9e4-359b39748582
# ╠═d5eed130-935b-4c52-937d-9920937192f4
# ╠═041a35d0-fd17-403b-9d30-0cff15854444
# ╠═2896e23b-2f0b-4d98-86e6-05640d140690
# ╠═2e994dd6-d9cf-4ab9-95b5-37a36126d093
# ╠═2c513327-74e1-4e2c-b939-74f17e05cc20
# ╠═7e30fc87-4f45-4742-9944-1dcef3961d64
# ╠═6afe5771-aca3-45df-9405-97463b60bdc6
# ╠═31dcd56a-f285-4231-940c-3826a6600d17
# ╠═f3065f9b-980f-4ba1-941d-38f5cf59c7b9
# ╠═7ac71d19-bf3e-44d5-9eb2-676e4048536e
# ╠═09efac7f-2e82-48c1-bcd8-5145cc192ea1
# ╠═004ae270-8ab2-4581-bccb-3b9a3700f542
# ╠═e746be87-ead0-464a-8908-c10bd34ee39b
# ╠═a6fa0245-65a1-48d0-85e8-f969f885591a
# ╠═b2fdd573-dbdc-4342-917d-987b2811642f
# ╠═3f4b1065-9116-4a92-9277-9f305c24c461
# ╠═1356707a-88b2-403f-a78f-85ba1c90606f
# ╠═9cf34db8-4053-4e99-9d0d-9e79d2582707
