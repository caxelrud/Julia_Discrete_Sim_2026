### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    #! format: off
    return quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
    #! format: on
end

# ╔═╡ 96759463-b11d-4690-9e0b-71ac6c003d7f
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ 8f048b6c-b310-4775-a4f4-7eb3ad8a4374
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ 8b74a6e7-5910-4f62-8fea-e5b767093409
md"""
# Queues, Erlang and capacity

A simulation is only credible when it agrees with queueing theory, and only useful when it says how much capacity to install.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ 6e76cb2d-b184-4f25-8ae4-27d36825ce61
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ beb93cff-00ec-4131-b877-97ed2d724e71
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ ac3e666b-5d53-4a64-8cd2-fb0db2ebbb9f
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ 74365f5a-f0ef-4ac6-a36d-ea1ff7f438ff
begin
bundle = load_study(ROOT);
end

# ╔═╡ afb1160f-f367-400a-9b86-0cc45be6527d
begin
TableOfContents()
end

# ╔═╡ 33d15616-3284-4128-bc12-3dbba5d9dec0
md"""
## The section: *Queues*
"""

# ╔═╡ 8e36d5d8-b9a8-4e2a-8d6c-f970b49f9c54
begin
HTML(preview_section(bundle, :queues))
end

# ╔═╡ d02d7012-547f-4d9e-981f-f62a407ce0c8
md"""
## Erlang C, live

The closed-form results the engine has to agree with are part of the package:
`theory(:mmc; λ, μ, c)` returns the whole stationary picture of an Erlang C queue.
Change the number of servers and watch the waiting time collapse.
"""

# ╔═╡ 2600075c-dd14-495d-8a2c-05cf316ce423
begin
@bind servers Slider(1:8; default = 2, show_value = true)
end

# ╔═╡ 515b0f94-d27b-4d95-b4d0-25a91cac5795
begin
λ = 0.75
    rows = [theory(:mmc; λ = λ, μ = 0.5, c = c) for c in 1:Int(servers)
            if λ / (0.5 * c) < 1]                    # only the stable configurations
    table_html([SymDict(:servers => r[:c], :rho => r[:rho], :pw => r[:pw], :Lq => r[:Lq],
            :Wq => r[:Wq], :W => r[:W], :L => r[:L]) for r in rows],
        [:servers, :rho, :pw, :Lq, :Wq, :W, :L]) |> HTML
end

# ╔═╡ 93fcc718-1038-4072-bdde-5e46d2538655
md"""
### The same system, simulated

The configuration on the slider, run `n` times, with the interval of the mean
waiting time -- and Erlang C for comparison. A configuration whose offered load
reaches the capacity (ρ ≥ 1) has no steady state, so the notebook says so instead
of producing a number.
"""

# ╔═╡ 8ff0342e-1819-4773-8e35-3f0dfe186047
begin
factor = model_params(:mmc, (arrival_rate = λ, service_rate = 0.5, servers = Int(servers)))
    stable = λ / (0.5 * Int(servers)) < 1
    study = stable ? experiment(opts -> build_model(:mmc, factor, opts),
        ExperimentConfig(replications = 6, horizon = 4000.0, warmup = 400.0);
        name = :mmc_live) : nothing;
    nothing
end

# ╔═╡ 1da909b5-6acd-4f1f-9073-c49095762b84
begin
ci = study === nothing ? nothing : metric_ci(study, :wait_mean)
    theory_wq = stable ? theory(:mmc; λ = λ, μ = 0.5, c = Int(servers))[:Wq] : NaN
    SymDict(:servers => Int(servers), :rho => round(λ / (0.5 * Int(servers)), digits = 3),
        :stable => stable, :wait_mean => ci === nothing ? NaN : ci[:mean],
        :half_width => ci === nothing ? NaN : ci[:half_width], :erlang_wq => theory_wq,
        :covered => ci === nothing ? false : ci[:lo] <= theory_wq <= ci[:hi])
end

# ╔═╡ 08f70762-37aa-4eef-9268-b79688950a70
begin
study === nothing ? nothing : fig_convergence(study)
end

# ╔═╡ 65567ef0-7b38-4912-8d2e-c0d30c1c4e53
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_queues.html` and
`reports/pdf/notebook_queues.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ a72636b9-6a5b-4f8c-9841-6a6ac4bef465
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :queues; root = ROOT)
end

# ╔═╡ 8f6f9707-c3de-4d11-ac47-e20c1dd7e553
begin
Markdown.parse(string("---\n",
        "*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed `",
        get(get(bundle, :config, SymDict()), :seed, 0),
        "`). Re-run `julia --project=. scripts/run_study.jl` to refresh every number ",
        "in this notebook.*"))
end

# ╔═╡ Cell order:
# ╠═8b74a6e7-5910-4f62-8fea-e5b767093409
# ╠═6e76cb2d-b184-4f25-8ae4-27d36825ce61
# ╠═96759463-b11d-4690-9e0b-71ac6c003d7f
# ╠═8f048b6c-b310-4775-a4f4-7eb3ad8a4374
# ╠═beb93cff-00ec-4131-b877-97ed2d724e71
# ╠═ac3e666b-5d53-4a64-8cd2-fb0db2ebbb9f
# ╠═74365f5a-f0ef-4ac6-a36d-ea1ff7f438ff
# ╠═afb1160f-f367-400a-9b86-0cc45be6527d
# ╠═33d15616-3284-4128-bc12-3dbba5d9dec0
# ╠═8e36d5d8-b9a8-4e2a-8d6c-f970b49f9c54
# ╠═d02d7012-547f-4d9e-981f-f62a407ce0c8
# ╠═2600075c-dd14-495d-8a2c-05cf316ce423
# ╠═515b0f94-d27b-4d95-b4d0-25a91cac5795
# ╠═93fcc718-1038-4072-bdde-5e46d2538655
# ╠═8ff0342e-1819-4773-8e35-3f0dfe186047
# ╠═1da909b5-6acd-4f1f-9073-c49095762b84
# ╠═08f70762-37aa-4eef-9268-b79688950a70
# ╠═65567ef0-7b38-4912-8d2e-c0d30c1c4e53
# ╠═a72636b9-6a5b-4f8c-9841-6a6ac4bef465
# ╠═8f6f9707-c3de-4d11-ac47-e20c1dd7e553
