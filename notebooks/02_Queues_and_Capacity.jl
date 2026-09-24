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

# ╔═╡ d191cf07-41ba-49cf-aab3-1e06a73331a3
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ 5728df15-d4de-4c1e-a9c2-6198429a48d6
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ 518146b0-8d8c-4963-bb49-92f4168bbbda
md"""
# Queues, Erlang and capacity

A simulation is only credible when it agrees with queueing theory, and only useful when it says how much capacity to install.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ 37700504-7001-4a1c-9d16-aea6f2d9fe60
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ 8c6aaeb9-ee14-428d-b24b-9231a272c643
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ 55fee701-0375-4d32-baf2-50ebed3a618a
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ be6cdb5d-1420-4bad-ac9d-f1a5428c75ff
begin
bundle = load_study(ROOT);
end

# ╔═╡ f7ccd778-1ae5-4269-ba67-58a29a85f516
begin
TableOfContents()
end

# ╔═╡ 2e36b40c-93bf-459b-b79b-2b98c04e90c3
md"""
## The section: *Queues*
"""

# ╔═╡ a5f8b2d4-3969-44f0-8a35-41284c6e9ece
begin
HTML(preview_section(bundle, :queues))
end

# ╔═╡ 6c333174-1aec-4907-a0e0-3425c5e0d313
md"""
## Erlang C, live

The closed-form results the engine has to agree with are part of the package:
`theory(:mmc; λ, μ, c)` returns the whole stationary picture of an Erlang C queue.
Change the number of servers and watch the waiting time collapse.
"""

# ╔═╡ 9d19a475-e4c1-465f-92d2-ffac6d5d95d9
begin
@bind servers Slider(1:8; default = 2, show_value = true)
end

# ╔═╡ 2529a680-97eb-4e73-8681-faa4078192b1
begin
λ = 0.75
    rows = [theory(:mmc; λ = λ, μ = 0.5, c = c) for c in 1:Int(servers)
            if λ / (0.5 * c) < 1]                    # only the stable configurations
    table_html([SymDict(:servers => r[:c], :rho => r[:rho], :pw => r[:pw], :Lq => r[:Lq],
            :Wq => r[:Wq], :W => r[:W], :L => r[:L]) for r in rows],
        [:servers, :rho, :pw, :Lq, :Wq, :W, :L]) |> HTML
end

# ╔═╡ b310e31e-5a2e-4691-add3-95d4883f8769
md"""
### The same system, simulated

The configuration on the slider, run `n` times, with the interval of the mean
waiting time -- and Erlang C for comparison. A configuration whose offered load
reaches the capacity (ρ ≥ 1) has no steady state, so the notebook says so instead
of producing a number.
"""

# ╔═╡ 8536664e-6898-4863-829c-074ac8359474
begin
factor = model_params(:mmc, (arrival_rate = λ, service_rate = 0.5, servers = Int(servers)))
    stable = λ / (0.5 * Int(servers)) < 1
    study = stable ? experiment(opts -> build_model(:mmc, factor, opts),
        ExperimentConfig(replications = 6, horizon = 4000.0, warmup = 400.0);
        name = :mmc_live) : nothing;
    nothing
end

# ╔═╡ 9228dfc0-9290-4584-9bbd-187a41fb3ca2
begin
ci = study === nothing ? nothing : metric_ci(study, :wait_mean)
    theory_wq = stable ? theory(:mmc; λ = λ, μ = 0.5, c = Int(servers))[:Wq] : NaN
    SymDict(:servers => Int(servers), :rho => round(λ / (0.5 * Int(servers)), digits = 3),
        :stable => stable, :wait_mean => ci === nothing ? NaN : ci[:mean],
        :half_width => ci === nothing ? NaN : ci[:half_width], :erlang_wq => theory_wq,
        :covered => ci === nothing ? false : ci[:lo] <= theory_wq <= ci[:hi])
end

# ╔═╡ 8c932f79-ab31-422e-9d78-3bf58a6d7e43
begin
study === nothing ? nothing : fig_convergence(study)
end

# ╔═╡ a2bad0b1-d786-4b03-8675-0d40b52b2d22
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_queues.html` and
`reports/pdf/notebook_queues.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ ce39672e-6280-4d1a-9e19-6ae492717a72
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :queues; root = ROOT)
end

# ╔═╡ 052930b2-c42c-4780-b1ed-debc9ce78c5c
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═518146b0-8d8c-4963-bb49-92f4168bbbda
# ╠═37700504-7001-4a1c-9d16-aea6f2d9fe60
# ╠═d191cf07-41ba-49cf-aab3-1e06a73331a3
# ╠═5728df15-d4de-4c1e-a9c2-6198429a48d6
# ╠═8c6aaeb9-ee14-428d-b24b-9231a272c643
# ╠═55fee701-0375-4d32-baf2-50ebed3a618a
# ╠═be6cdb5d-1420-4bad-ac9d-f1a5428c75ff
# ╠═f7ccd778-1ae5-4269-ba67-58a29a85f516
# ╠═2e36b40c-93bf-459b-b79b-2b98c04e90c3
# ╠═a5f8b2d4-3969-44f0-8a35-41284c6e9ece
# ╠═6c333174-1aec-4907-a0e0-3425c5e0d313
# ╠═9d19a475-e4c1-465f-92d2-ffac6d5d95d9
# ╠═2529a680-97eb-4e73-8681-faa4078192b1
# ╠═b310e31e-5a2e-4691-add3-95d4883f8769
# ╠═8536664e-6898-4863-829c-074ac8359474
# ╠═9228dfc0-9290-4584-9bbd-187a41fb3ca2
# ╠═8c932f79-ab31-422e-9d78-3bf58a6d7e43
# ╠═a2bad0b1-d786-4b03-8675-0d40b52b2d22
# ╠═ce39672e-6280-4d1a-9e19-6ae492717a72
# ╠═052930b2-c42c-4780-b1ed-debc9ce78c5c
