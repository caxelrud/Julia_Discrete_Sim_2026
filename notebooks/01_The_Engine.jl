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

# ╔═╡ 95e3ba0b-c99c-4341-8966-cb7a2eed2a98
md"""
# Inside the event engine

The calendar, the processes and the trace: how a discrete-event simulator decides what happens next.

This notebook belongs to the study in this repository: it loads the artefacts the
pipeline produced (`data/analysis.json` and `reports/figures/*.png`), shows the
section of the report it is about, and prints that section to PDF in its last
cell. Nothing here is a copy of a number typed by hand -- every value comes from
the bundle, and the bundle comes from `scripts/run_study.jl`.
"""

# ╔═╡ 22de0bd6-67ca-40cf-9dc2-884d83d4cdc6
md"""
## The environment

The first cell activates `notebooks/Project.toml`, which has `DiscreteSim` (this
repository, developed in place) together with `PlutoUI` and `Plots`. Activating it
explicitly means the notebook runs the same environment interactively and headless
(`scripts/run_notebooks.jl`), with no package installation in the middle.
"""

# ╔═╡ 37ae656a-a0cf-4e0b-91ca-8e815c642104
begin
import Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ cf5df661-6ca5-427e-8c57-d86dc90b922b
begin
using DiscreteSim
    using PlutoUI
    using Plots
    using Statistics
    using Printf
    using Dates
end

# ╔═╡ 33f15719-d1c9-45c4-bace-5de648a92027
begin
ROOT = dirname(@__DIR__)
end

# ╔═╡ 2ed20ffe-8fe0-4c5d-9d35-e63b56f6fb9f
md"""
## The study, loaded from disk

`load_study` reads the JSON the pipeline wrote and turns it back into the
symbol-keyed records the package uses, so the notebook and the printed report
show the same numbers without re-running the study.
"""

# ╔═╡ fc17819d-8786-4b8c-9705-ed08b451b567
begin
bundle = load_study(ROOT);
end

# ╔═╡ c3d5c5a0-02ac-4920-8739-657a407559a5
begin
TableOfContents()
end

# ╔═╡ 44981c46-c8c4-4d5f-9055-f17f6c8dd0c5
md"""
## The section: *Engine*
"""

# ╔═╡ 57f48746-364e-42a6-9714-d197a8d2f744
begin
HTML(preview_section(bundle, :engine))
end

# ╔═╡ 9af2a3c7-ca59-4450-8f17-befb219cef63
md"""
## A live run, from scratch

The bundle shows the finished study; the cells below build a **new** simulation in
this notebook, with its own clock, calendar and processes, and check it against
the closed-form result of the same queue. Move the slider and re-run the cells
below it: the simulation and Erlang's formula move together.
"""

# ╔═╡ 162c4c3f-42cd-4147-80ef-d17ff21ad229
begin
@bind rate Slider(0.2:0.05:0.95; default = 0.8, show_value = true)
end

# ╔═╡ 60c628a3-8a74-43b5-bd02-5684400380f1
md"""
### The model, in ten lines

An arrival process, one server per customer and a queue handled by the engine:
`request!` blocks the customer until a server is free, `hold!` occupies simulated
time and `release!` hands the server on.
"""

# ╔═╡ b6796c52-318f-40c5-a79c-1c7d7ece72ea
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

# ╔═╡ 27066f9c-a616-4a1b-bd4f-ce0ba69add20
md"""
### The event trace

Every decision the engine made, in order: the trace is what the Gantt chart, the
throughput curve and every audit question are answered from. It also converts to a
table in one call, which is why the report can print a page of it.
"""

# ╔═╡ f6ec8df3-c1e3-4bc9-88da-121e463dc65c
begin
rowtable = first(trace_rows(run.trace; limit = 14), 14)
end

# ╔═╡ e0eaed88-e876-480c-b5c8-44f4413e8171
begin
fig_wip(run)
end

# ╔═╡ dd261143-bed8-4c4c-b1fa-459ccd36689b
md"""
### The calendar, one event at a time

`step!` processes exactly one event, so an interactive session can look at the
system after every decision. `peek_event` says what is next without taking it.
"""

# ╔═╡ e328a9cb-fa6b-4c39-bd06-54930fa7f057
begin
next_events = [peek_event(run.calendar) for _ in 1:1]
    (now = run.now, pending = pending(run), next = first(next_events))
end

# ╔═╡ 6b4af924-9c54-41a4-8950-02867cecc606
md"""
## The printout, and its PDF

The cell below writes the section as a self-contained HTML printout and prints it
with a headless browser: `reports/html/notebook_engine.html` and
`reports/pdf/notebook_engine.pdf`. The notebook *is* the report -- the PDF is its
printout.
"""

# ╔═╡ 513e20f8-34ea-4459-8776-79bd92b87ed3
begin
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
    print_section_pdf(bundle, :engine; root = ROOT)
end

# ╔═╡ 1c34baf4-43ec-4f24-b1f9-3322d2fe1b84
md"""
---
*Generated by `DiscreteSim.jl` from `data/analysis.json` (seed
`$(get(get(bundle, :config, SymDict()), :seed, 0))`). Re-run
`julia --project=. scripts/run_study.jl` to refresh every number in this notebook.*
"""

# ╔═╡ Cell order:
# ╠═95e3ba0b-c99c-4341-8966-cb7a2eed2a98
# ╠═22de0bd6-67ca-40cf-9dc2-884d83d4cdc6
# ╠═37ae656a-a0cf-4e0b-91ca-8e815c642104
# ╠═cf5df661-6ca5-427e-8c57-d86dc90b922b
# ╠═33f15719-d1c9-45c4-bace-5de648a92027
# ╠═2ed20ffe-8fe0-4c5d-9d35-e63b56f6fb9f
# ╠═fc17819d-8786-4b8c-9705-ed08b451b567
# ╠═c3d5c5a0-02ac-4920-8739-657a407559a5
# ╠═44981c46-c8c4-4d5f-9055-f17f6c8dd0c5
# ╠═57f48746-364e-42a6-9714-d197a8d2f744
# ╠═9af2a3c7-ca59-4450-8f17-befb219cef63
# ╠═162c4c3f-42cd-4147-80ef-d17ff21ad229
# ╠═60c628a3-8a74-43b5-bd02-5684400380f1
# ╠═b6796c52-318f-40c5-a79c-1c7d7ece72ea
# ╠═27066f9c-a616-4a1b-bd4f-ce0ba69add20
# ╠═f6ec8df3-c1e3-4bc9-88da-121e463dc65c
# ╠═e0eaed88-e876-480c-b5c8-44f4413e8171
# ╠═dd261143-bed8-4c4c-b1fa-459ccd36689b
# ╠═e328a9cb-fa6b-4c39-bd06-54930fa7f057
# ╠═6b4af924-9c54-41a4-8950-02867cecc606
# ╠═513e20f8-34ea-4459-8776-79bd92b87ed3
# ╠═1c34baf4-43ec-4f24-b1f9-3322d2fe1b84
