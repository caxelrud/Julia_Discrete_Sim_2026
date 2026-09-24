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

# ╔═╡ d0508f3e-b88b-4b56-b038-6b28daf6cf58
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ ed196837-c632-4bda-82cc-13a54101174e
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ c01f9cb4-de62-4fa9-9302-58f9229f80ce
md"""
# Queues, Erlang and capacity

A simulation is only credible when it agrees with queueing theory, and only useful when it says how much capacity to install.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ 1087580c-72b6-4cc9-9dec-054370f6eb65
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ e465cbef-c8f4-4f12-8da9-245f79029236
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ 52c27014-5710-4454-b536-348605ea02b4
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ 21de28ac-2a1e-4a18-aeef-a5effd04cec7
begin
bundle = load_study(ROOT);
end

# ╔═╡ e3494fc0-985a-4325-b2af-01e9859ca1bc
begin
TableOfContents()
end

# ╔═╡ ff17cd30-bd3c-4896-a989-a4c1942d811e
md"""
## The section: *Queues*
"""

# ╔═╡ 4252acb7-5802-4673-8fee-a47c298c69c7
begin
HTML(preview_section(bundle, :queues))
end

# ╔═╡ 26a29d00-13ab-4d64-a956-3fa9d1bc033d
md"""
## Erlang C, live

The closed-form results the engine has to agree with are part of the package:
`theory(:mmc; λ, μ, c)` returns the whole stationary picture of an Erlang C queue.
Change the number of servers and watch the waiting time collapse.
"""

# ╔═╡ 704a4583-719f-47b5-a213-be843a7d5114
begin
@bind servers Slider(1:8; default = 2, show_value = true)
end

# ╔═╡ 6def799d-2c17-4b65-a5c9-3d4185461c2c
begin
λ = 0.75
    rows = [theory(:mmc; λ = λ, μ = 0.5, c = c) for c in 1:Int(servers)
            if λ / (0.5 * c) < 1]                    # only the stable configurations
    table_html([SymDict(:servers => r[:c], :rho => r[:rho], :pw => r[:pw], :Lq => r[:Lq],
            :Wq => r[:Wq], :W => r[:W], :L => r[:L]) for r in rows],
        [:servers, :rho, :pw, :Lq, :Wq, :W, :L]) |> HTML
end

# ╔═╡ 39709444-845e-4eaf-b36b-71b8a86c647b
md"""
### The same system, simulated

The configuration on the slider, run `n` times, with the interval of the mean
waiting time -- and Erlang C for comparison. A configuration whose offered load
reaches the capacity (ρ ≥ 1) has no steady state, so the notebook says so instead
of producing a number.
"""

# ╔═╡ bec259bb-ebd9-4eb8-bb09-63bfde12074e
begin
factor = model_params(:mmc, (arrival_rate = λ, service_rate = 0.5, servers = Int(servers)))
    stable = λ / (0.5 * Int(servers)) < 1
    study = stable ? experiment(opts -> build_model(:mmc, factor, opts),
        ExperimentConfig(replications = 6, horizon = 4000.0, warmup = 400.0);
        name = :mmc_live) : nothing;
    nothing
end

# ╔═╡ f72dba3f-eb12-4466-8cd5-d1fa6def475b
begin
ci = study === nothing ? nothing : metric_ci(study, :wait_mean)
    theory_wq = stable ? theory(:mmc; λ = λ, μ = 0.5, c = Int(servers))[:Wq] : NaN
    SymDict(:servers => Int(servers), :rho => round(λ / (0.5 * Int(servers)), digits = 3),
        :stable => stable, :wait_mean => ci === nothing ? NaN : ci[:mean],
        :half_width => ci === nothing ? NaN : ci[:half_width], :erlang_wq => theory_wq,
        :covered => ci === nothing ? false : ci[:lo] <= theory_wq <= ci[:hi])
end

# ╔═╡ 494666fe-4771-440d-a708-b041efc6350f
begin
study === nothing ? nothing : fig_convergence(study)
end

# ╔═╡ ea2447ac-7734-46eb-b8fe-dbab25cb34c4
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_queues.html` and
`reports/pdf/notebook_queues.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ a3799f92-41b6-4f72-b9bd-3ae16eb652fa
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :queues; root = ROOT)
end

# ╔═╡ 85feb516-84f8-4d79-9e5a-c8249afbfd12
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═c01f9cb4-de62-4fa9-9302-58f9229f80ce
# ╠═1087580c-72b6-4cc9-9dec-054370f6eb65
# ╠═d0508f3e-b88b-4b56-b038-6b28daf6cf58
# ╠═ed196837-c632-4bda-82cc-13a54101174e
# ╠═e465cbef-c8f4-4f12-8da9-245f79029236
# ╠═52c27014-5710-4454-b536-348605ea02b4
# ╠═21de28ac-2a1e-4a18-aeef-a5effd04cec7
# ╠═e3494fc0-985a-4325-b2af-01e9859ca1bc
# ╠═ff17cd30-bd3c-4896-a989-a4c1942d811e
# ╠═4252acb7-5802-4673-8fee-a47c298c69c7
# ╠═26a29d00-13ab-4d64-a956-3fa9d1bc033d
# ╠═704a4583-719f-47b5-a213-be843a7d5114
# ╠═6def799d-2c17-4b65-a5c9-3d4185461c2c
# ╠═39709444-845e-4eaf-b36b-71b8a86c647b
# ╠═bec259bb-ebd9-4eb8-bb09-63bfde12074e
# ╠═f72dba3f-eb12-4466-8cd5-d1fa6def475b
# ╠═494666fe-4771-440d-a708-b041efc6350f
# ╠═ea2447ac-7734-46eb-b8fe-dbab25cb34c4
# ╠═a3799f92-41b6-4f72-b9bd-3ae16eb652fa
# ╠═85feb516-84f8-4d79-9e5a-c8249afbfd12
