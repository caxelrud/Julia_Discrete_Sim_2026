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

# ╔═╡ 5c11900e-efa8-455f-9de4-dbb1d26500af
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ 7d7fdabf-9856-40b8-83fa-f9f12486c1d9
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ def8d05c-561f-4ac7-894e-5c4022d54b1d
md"""
# Inside the event engine

The calendar, the processes and the trace: how a discrete-event simulator decides what happens next.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ a149e5af-c6a7-46e8-8fff-3435e706a1e4
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ 91660168-68c6-4270-9b0a-0a878fc54020
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ d4900c3f-83ee-47cf-9484-84b65cabb440
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ 2a7bb51a-c6e0-4303-9aff-32b1464c3aa7
begin
bundle = load_study(ROOT);
end

# ╔═╡ 3bc9a062-2859-4f28-9c21-ded8c6a3a2cc
begin
TableOfContents()
end

# ╔═╡ ee081308-bdf5-41f7-bf3c-05da1e608b98
md"""
## The section: *Engine*
"""

# ╔═╡ 9fb7f60d-bea3-4367-af20-64ced2dd1981
begin
HTML(preview_section(bundle, :engine))
end

# ╔═╡ f7f569ae-a272-4b0f-8c1f-a92df731b067
md"""
## A live run, from scratch

The bundle shows the finished study; the cells below build a **new** simulation in
this notebook, with its own clock, calendar and processes, and check it against
the closed-form result of the same queue. Move the slider and re-run the cells
below it: the simulation and Erlang's formula move together.
"""

# ╔═╡ 2e12eede-562a-4de9-84cf-45390d66a5f6
begin
@bind rate Slider(0.2:0.05:0.95; default = 0.8, show_value = true)
end

# ╔═╡ 01915902-329e-438f-8785-2d793d907e09
md"""
### The model, in ten lines

An arrival process, one server per customer and a queue handled by the engine:
`request!` blocks the customer until a server is free, `hold!` occupies simulated
time and `release!` hands the server on.
"""

# ╔═╡ 20e66c19-7a09-4833-a20c-7fad78caf8d1
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

# ╔═╡ 4029aea4-200d-45c8-ab7d-d1b5109f516b
md"""
### The event trace

Every decision the engine made, in order: the trace is what the Gantt chart, the
throughput curve and every audit question are answered from. It also converts to a
table in one call, which is why the report can print a page of it.
"""

# ╔═╡ 6d8a13cb-d91b-4e1e-b183-f4e43e024271
begin
rowtable = first(trace_rows(run.trace; limit = 14), 14)
end

# ╔═╡ d4516707-73d9-4ce2-ad8b-b727a239bf01
begin
fig_wip(run)
end

# ╔═╡ f04e7537-5ae1-4249-b0ae-eaf285bf86ef
md"""
### The calendar, one event at a time

`step!` processes exactly one event, so an interactive session can look at the
system after every decision. `peek_event` says what is next without taking it.
"""

# ╔═╡ 31ceb2e3-67fb-42d3-b449-f0ccdf99fee5
begin
next_events = [peek_event(run.calendar) for _ in 1:1]
    (now = run.now, pending = pending(run), next = first(next_events))
end

# ╔═╡ 4569e12d-b4d7-474d-bfa9-209fe571a33b
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_engine.html` and
`reports/pdf/notebook_engine.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ 9d81dc4f-bc59-437c-8a49-c84136f89a06
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :engine; root = ROOT)
end

# ╔═╡ 3f701dd7-26fd-492b-a202-c8abd67c2229
begin
Markdown.parse(string("---\n",
        "*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed `",
        get(get(bundle, :config, SymDict()), :seed, 0),
        "`). Re-run `julia --project=. scripts/run_study.jl` to refresh every number ",
        "in this notebook.*"))
end

# ╔═╡ Cell order:
# ╠═def8d05c-561f-4ac7-894e-5c4022d54b1d
# ╠═a149e5af-c6a7-46e8-8fff-3435e706a1e4
# ╠═5c11900e-efa8-455f-9de4-dbb1d26500af
# ╠═7d7fdabf-9856-40b8-83fa-f9f12486c1d9
# ╠═91660168-68c6-4270-9b0a-0a878fc54020
# ╠═d4900c3f-83ee-47cf-9484-84b65cabb440
# ╠═2a7bb51a-c6e0-4303-9aff-32b1464c3aa7
# ╠═3bc9a062-2859-4f28-9c21-ded8c6a3a2cc
# ╠═ee081308-bdf5-41f7-bf3c-05da1e608b98
# ╠═9fb7f60d-bea3-4367-af20-64ced2dd1981
# ╠═f7f569ae-a272-4b0f-8c1f-a92df731b067
# ╠═2e12eede-562a-4de9-84cf-45390d66a5f6
# ╠═01915902-329e-438f-8785-2d793d907e09
# ╠═20e66c19-7a09-4833-a20c-7fad78caf8d1
# ╠═4029aea4-200d-45c8-ab7d-d1b5109f516b
# ╠═6d8a13cb-d91b-4e1e-b183-f4e43e024271
# ╠═d4516707-73d9-4ce2-ad8b-b727a239bf01
# ╠═f04e7537-5ae1-4249-b0ae-eaf285bf86ef
# ╠═31ceb2e3-67fb-42d3-b449-f0ccdf99fee5
# ╠═4569e12d-b4d7-474d-bfa9-209fe571a33b
# ╠═9d81dc4f-bc59-437c-8a49-c84136f89a06
# ╠═3f701dd7-26fd-492b-a202-c8abd67c2229
