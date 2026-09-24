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

# ╔═╡ 48cb8735-8147-4ef6-86c9-a7b6194a9078
md"""
# Inside the event engine

The calendar, the processes and the trace: how a discrete-event simulator decides what happens next.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ 98b571c3-6efd-4058-95ad-bede32826228
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ 5b3564cc-baf0-43a1-a8af-eb51d90c9e99
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ 2f33c137-bd9f-4601-a322-ef5c7d1ef906
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ 281a41db-ca5f-4b83-9b4c-38987efdade6
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ 14686546-832a-4da0-8c1b-cb03a82e7bc9
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ 3984515a-170f-4789-94a4-800c5b33a7b7
begin
bundle = load_study(ROOT);
end

# ╔═╡ 15c3cb18-d329-4aef-a960-3288bc783daa
begin
TableOfContents()
end

# ╔═╡ 6b82e4e4-37a6-427d-b807-004dfdccbef4
md"""
## The section: *Engine*
"""

# ╔═╡ 980c1c2b-e98d-489c-b128-f348101b1baa
begin
HTML(preview_section(bundle, :engine))
end

# ╔═╡ aadcca70-07af-4f5b-8419-4d9ad12d916e
md"""
## A live run, from scratch

The bundle shows the finished study; the cells below build a **new** simulation in
this notebook, with its own clock, calendar and processes, and check it against
the closed-form result of the same queue. Move the slider and re-run the cells
below it: the simulation and Erlang's formula move together.
"""

# ╔═╡ e4dbd944-19cd-4fbf-baf7-a404035fe651
begin
@bind rate Slider(0.2:0.05:0.95; default = 0.8, show_value = true)
end

# ╔═╡ 1038dad1-edfb-42c7-b20b-c869f8b1d263
md"""
### The model, in ten lines

An arrival process, one server per customer and a queue handled by the engine:
`request!` blocks the customer until a server is free, `hold!` occupies simulated
time and `release!` hands the server on.
"""

# ╔═╡ 0d891c53-5fef-43b8-a97b-55af748dbd88
begin
params = model_params(:mmc, (arrival_rate = Float64(rate), servers = 2))
    run = build_model(:mmc, params, SymDict(:seed => 20260101, :horizon => 4000.0, :trace => true))
    warmup!(run, 400.0)
    run!(run);
    observed = observed_summary(run, :server)
    theoretical = theory(:mmc; λ = params[:arrival_rate], μ = params[:service_rate],
        c = params[:servers])
    validation = validate_against_theory(observed, theoretical;
        key_map = [:wait => :Wq, :queue_length => :Lq, :utilisation => :utilisation])
    SymDict(:events => run.processed, :utilisation => utilisation(run[:server]),
        :wait_simulated => observed[:wait], :wait_erlang => theoretical[:Wq],
        :verdict => validation[:verdict])
end

# ╔═╡ 29229cfd-2e2f-4784-8264-07b6f1b61ae7
md"""
### The event trace

Every decision the engine made, in order: the trace is what the Gantt chart, the
throughput curve and every audit question are answered from. It also converts to a
table in one call, which is why the report can print a page of it.
"""

# ╔═╡ cdab88cc-9522-411d-8974-76fcd96f0346
begin
rowtable = first(trace_rows(run.trace; limit = 14), 14)
end

# ╔═╡ 4326ac8e-95be-404b-b220-1765222203ab
begin
fig_wip(run)
end

# ╔═╡ e835b153-a90c-43f9-be81-8186874a4f65
md"""
### The calendar, one event at a time

`step!` processes exactly one event, so an interactive session can look at the
system after every decision. `peek_event` says what is next without taking it.
"""

# ╔═╡ 8d40ceab-0d9e-4d0d-838e-fbd68f37fd44
begin
next_events = [peek_event(run.calendar) for _ in 1:1]
    (now = run.now, pending = pending(run), next = first(next_events))
end

# ╔═╡ 22636f55-fae4-4ab2-ba5d-4aad410c4e8f
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_engine.html` and
`reports/pdf/notebook_engine.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ f3a15885-a189-4de8-bfda-a744aaa95f35
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :engine; root = ROOT)
end

# ╔═╡ d221aff2-0672-45a7-a8c5-a410a1e475f6
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═48cb8735-8147-4ef6-86c9-a7b6194a9078
# ╠═98b571c3-6efd-4058-95ad-bede32826228
# ╠═5b3564cc-baf0-43a1-a8af-eb51d90c9e99
# ╠═2f33c137-bd9f-4601-a322-ef5c7d1ef906
# ╠═281a41db-ca5f-4b83-9b4c-38987efdade6
# ╠═14686546-832a-4da0-8c1b-cb03a82e7bc9
# ╠═3984515a-170f-4789-94a4-800c5b33a7b7
# ╠═15c3cb18-d329-4aef-a960-3288bc783daa
# ╠═6b82e4e4-37a6-427d-b807-004dfdccbef4
# ╠═980c1c2b-e98d-489c-b128-f348101b1baa
# ╠═aadcca70-07af-4f5b-8419-4d9ad12d916e
# ╠═e4dbd944-19cd-4fbf-baf7-a404035fe651
# ╠═1038dad1-edfb-42c7-b20b-c869f8b1d263
# ╠═0d891c53-5fef-43b8-a97b-55af748dbd88
# ╠═29229cfd-2e2f-4784-8264-07b6f1b61ae7
# ╠═cdab88cc-9522-411d-8974-76fcd96f0346
# ╠═4326ac8e-95be-404b-b220-1765222203ab
# ╠═e835b153-a90c-43f9-be81-8186874a4f65
# ╠═8d40ceab-0d9e-4d0d-838e-fbd68f37fd44
# ╠═22636f55-fae4-4ab2-ba5d-4aad410c4e8f
# ╠═f3a15885-a189-4de8-bfda-a744aaa95f35
# ╠═d221aff2-0672-45a7-a8c5-a410a1e475f6
