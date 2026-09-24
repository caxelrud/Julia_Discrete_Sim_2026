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

# ╔═╡ 2bea88ca-465a-4be1-b19c-a1135be3e111
md"""
# Inside the event engine

The calendar, the processes and the trace: how a discrete-event simulator decides what happens next.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ 7c28e6c1-2b2e-4a7c-b84d-68e89cdbb50e
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ 491897e7-2689-445f-98ed-e163c20982d2
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ de85ed70-e1a3-435a-a370-58b851035979
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ e40131b7-2b27-4488-83ff-5965f3b2ee77
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ 1b72f2e1-bd8e-4d4f-bbec-4aaf07a6b973
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ 4362346e-21c7-424f-a958-660abc233da3
begin
bundle = load_study(ROOT);
end

# ╔═╡ f68cff8e-f376-4c4f-8c2f-5eb06dbd7925
begin
TableOfContents()
end

# ╔═╡ f4702de9-cb97-48aa-8ab1-c17bfe512507
md"""
## The section: *Engine*
"""

# ╔═╡ 5d843288-bb62-4da5-8230-37d8980c6024
begin
HTML(preview_section(bundle, :engine))
end

# ╔═╡ 330dfd02-a2c6-41ab-9c83-042a35411cfd
md"""
## A live run, from scratch

The bundle shows the finished study; the cells below build a **new** simulation in
this notebook, with its own clock, calendar and processes, and check it against
the closed-form result of the same queue. Move the slider and re-run the cells
below it: the simulation and Erlang's formula move together.
"""

# ╔═╡ 04cdcd31-b410-4187-a673-d6833b461488
begin
@bind rate Slider(0.2:0.05:0.95; default = 0.8, show_value = true)
end

# ╔═╡ 931bb981-48da-4a4d-a48b-b5f1d35f1277
md"""
### The model, in ten lines

An arrival process, one server per customer and a queue handled by the engine:
`request!` blocks the customer until a server is free, `hold!` occupies simulated
time and `release!` hands the server on.
"""

# ╔═╡ e4f04f8e-11e1-409f-ae34-8ecb57c5227b
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

# ╔═╡ b8718cca-72aa-4010-b2f7-f649bac2d1dc
md"""
### The event trace

Every decision the engine made, in order: the trace is what the Gantt chart, the
throughput curve and every audit question are answered from. It also converts to a
table in one call, which is why the report can print a page of it.
"""

# ╔═╡ df8e1269-abb1-4b1c-92d1-d5c684a47a5c
begin
rowtable = first(trace_rows(run.trace; limit = 14), 14)
end

# ╔═╡ 539fc442-2553-4a1e-b6ab-9bacf1c68ff0
begin
fig_wip(run)
end

# ╔═╡ 8f2afbf5-c06c-4c23-86e9-5020aaa748dd
md"""
### The calendar, one event at a time

`step!` processes exactly one event, so an interactive session can look at the
system after every decision. `peek_event` says what is next without taking it.
"""

# ╔═╡ da89d67b-6eed-4ba5-b52f-ec113f69c1d1
begin
next_events = [peek_event(run.calendar) for _ in 1:1]
    (now = run.now, pending = pending(run), next = first(next_events))
end

# ╔═╡ 247b6514-eda2-42ef-a838-8613ea56bba1
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_engine.html` and
`reports/pdf/notebook_engine.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ be6f0b44-a567-4af3-af33-8530ac6b52f1
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :engine; root = ROOT)
end

# ╔═╡ 37cc8e8a-cbc5-478b-84ea-27e2c13aac4c
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═2bea88ca-465a-4be1-b19c-a1135be3e111
# ╠═7c28e6c1-2b2e-4a7c-b84d-68e89cdbb50e
# ╠═491897e7-2689-445f-98ed-e163c20982d2
# ╠═de85ed70-e1a3-435a-a370-58b851035979
# ╠═e40131b7-2b27-4488-83ff-5965f3b2ee77
# ╠═1b72f2e1-bd8e-4d4f-bbec-4aaf07a6b973
# ╠═4362346e-21c7-424f-a958-660abc233da3
# ╠═f68cff8e-f376-4c4f-8c2f-5eb06dbd7925
# ╠═f4702de9-cb97-48aa-8ab1-c17bfe512507
# ╠═5d843288-bb62-4da5-8230-37d8980c6024
# ╠═330dfd02-a2c6-41ab-9c83-042a35411cfd
# ╠═04cdcd31-b410-4187-a673-d6833b461488
# ╠═931bb981-48da-4a4d-a48b-b5f1d35f1277
# ╠═e4f04f8e-11e1-409f-ae34-8ecb57c5227b
# ╠═b8718cca-72aa-4010-b2f7-f649bac2d1dc
# ╠═df8e1269-abb1-4b1c-92d1-d5c684a47a5c
# ╠═539fc442-2553-4a1e-b6ab-9bacf1c68ff0
# ╠═8f2afbf5-c06c-4c23-86e9-5020aaa748dd
# ╠═da89d67b-6eed-4ba5-b52f-ec113f69c1d1
# ╠═247b6514-eda2-42ef-a838-8613ea56bba1
# ╠═be6f0b44-a567-4af3-af33-8530ac6b52f1
# ╠═37cc8e8a-cbc5-478b-84ea-27e2c13aac4c
