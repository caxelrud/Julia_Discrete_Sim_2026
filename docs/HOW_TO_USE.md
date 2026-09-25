# How to use this repository

`DiscreteSim` is a discrete-event simulation package for Julia. This repository is
both the package and one complete study built with it: the plant data, the
calibrated models, the experiments, eight Pluto notebooks and the PDFs the
notebooks print.

This document is the practical one. If you want to know *what* is being simulated
and what the numbers mean, read [`THE_CASE.md`](THE_CASE.md). If you want to look at
the architecture, read the file headers in `src/` (each file explains itself) and
`../README.md`.

* [What you need](#what-you-need)
* [Five minutes end to end](#five-minutes-end-to-end)
* [The notebooks, one by one](#the-notebooks-one-by-one)
* [How a notebook works](#how-a-notebook-works)
* [How a notebook prints its PDF](#how-a-notebook-prints-its-pdf)
* [Running the notebooks without a browser](#running-the-notebooks-without-a-browser)
* [Printing your own analysis to PDF](#printing-your-own-analysis-to-pdf)
* [Using the package as a library](#using-the-package-as-a-library)
* [Changing the study](#changing-the-study)
* [When something goes wrong](#when-something-goes-wrong)
* [Where everything is](#where-everything-is)

---

## What you need

| | |
|---|---|
| Julia | 1.10 or newer (`julia --version`) |
| A Chromium browser | Chrome, Edge, Chromium or Brave, for the PDFs. The HTML printouts need nothing. |
| Disk | about 20 MB for the artefacts, 1 GB for the package cache Julia builds on first use |

Checked with Julia 1.12 on Windows; nothing in the package is platform specific.

```sh
git clone https://github.com/caxelrud/Julia_Discrete_Sim_2026.git
cd Julia_Discrete_Sim_2026
julia --project=. -e 'using Pkg; Pkg.instantiate()'    # once, installs the dependencies
```

`Pkg.instantiate()` takes a few minutes the first time (it downloads and
precompiles Plots, Pluto, Distributions, HTTP, JSON3). After that every command in
this document is seconds.

## Five minutes end to end

Three commands, in this order:

```sh
julia --project=. -e 'using Pkg; Pkg.test()'        # ~1 minute: 1128 tests
julia --project=. scripts/run_study.jl --parallel   # ~40 seconds: the whole study
julia --project=. scripts/run_notebooks.jl --no-save # ~4 minutes: the 8 notebooks, each printing its PDF
```

What you get:

| Where | What | Produced by |
|---|---|---|
| `data/*.json`, `data/*.csv` | the plant history, the calibration, the study, the online feed, the reevaluation log | `run_study.jl` |
| `reports/figures/*.png` | 12 figures | `run_study.jl` |
| `reports/html/*.html` | self-contained printouts (CSS and figures inlined) | `run_study.jl` and the notebooks |
| `reports/pdf/*.pdf` | 9 PDFs: the whole study, and one per section | the notebooks' own last cells |

`run_study.jl` prints a manifest at the end; the same record is in
`data/manifest.json`. If you only want to look at a result, read
`data/analysis.json` or open a notebook -- both come from the same bundle.

```text
manifest
  title          DiscreteEventSimulation
  seed           20260101
  days           45
  featured       machine_shop
  replications   8
  horizon        4000
  warmup         400
  validation     validated
  reevaluation   keep
  n_data 9   n_figures 12   n_html 9   n_pdf 9   status ok
```


---

## The notebooks, one by one

Open them with Pluto (a browser opens on its own):

```sh
julia --project=. -e 'import Pluto; Pluto.run()'
```

and click a file in `notebooks/`. **Run the study first** (`run_study.jl`): every
notebook *loads* the artefacts from `data/` instead of recomputing them, so each one
opens in about a second.

| Notebook | Section of the report | What you see | Its PDF |
|---|---|---|---|
| `00_Study_Overview.jl` | Overview | the design, the headline numbers, the model catalogue | `notebook_overview.pdf` |
| `01_The_Engine.jl` | Engine | the calendar, processes, a live queue built from scratch, the trace, Little's law | `notebook_engine.pdf` |
| `02_Queues_and_Capacity.jl` | Queues | Erlang C live (slider: number of servers) against a re-run simulation, and the capacity sweep | `notebook_queues.pdf` |
| `03_The_Models.jl` | Models | the five models, one at a time, with their metrics | `notebook_models.pdf` |
| `04_Experiments_and_Confidence.jl` | Experiments | warmup, replications, batch means, paired comparison, factorial design | `notebook_experiments.pdf` |
| `05_Calibration.jl` | Calibration | the observed series, the four fitted families, the KS test, the bootstrap | `notebook_calibration.pdf` |
| `06_Offline_and_Online.jl` | Online | the fallback chain, the feed's freshness, the reevaluation log | `notebook_online.pdf` |
| `07_Artefacts_and_PDF.jl` | Reports | every artefact, and the whole study as one PDF | `notebook_reports.pdf`, `discrete_sim_report.pdf` |

To read the report without a browser, open the HTML in `reports/html/` or the PDFs in
`reports/pdf/`.

## How a notebook works

Every notebook has the same five parts, in the same order. Once you know them, you
know all eight.

1. **The environment.** The first cell runs `Pkg.activate(@__DIR__)`, which activates
   `notebooks/Project.toml`: `DiscreteSim` (developed in place), `PlutoUI` and `Plots`.
   Activating it explicitly is what makes the notebook run the same way interactively
   and headless, with no package installation in the middle.
2. **`ROOT`.** `ROOT = dirname(@__DIR__)` -- the repository root, taken from the
   notebook's own location, so the notebook works whatever the working directory is.
3. **The study, loaded from disk.** `bundle = load_study(ROOT)` reads
   `data/analysis.json` and turns it back into the symbol-keyed records the package
   uses. Nothing in a notebook is a number typed by hand.
4. **The section.** `HTML(preview_section(bundle, :queues))` shows exactly the part of
   the report the notebook is about -- the same HTML the PDF is printed from.
5. **Live cells (some notebooks).** Where a notebook can teach something by
   computing, it does: a `@bind` slider changes the number of servers and the cell
   below re-runs a small simulation and compares it with Erlang C. Those cells use the
   *library*, not the loaded study, so they are where to experiment.

## How a notebook prints its PDF

The **last code cell** of each notebook is:

```julia
println("run the study first if this file is missing: julia --project=. scripts/run_study.jl")
print_section_pdf(bundle, :queues; root = ROOT)
```

`print_section_pdf` builds the section's HTML, writes it and prints that file with the
browser it finds:

```text
print_section_pdf(bundle, :queues)  ->  reports/html/notebook_queues.html
                                    ->  reports/pdf/notebook_queues.pdf
```

It returns a record, so a cell can also report what happened:

```julia
out = print_section_pdf(bundle, :queues; root = ROOT)
(out[:printed], filesize(out[:pdf]))      # (true, 181900)

---

## Printing your own analysis to PDF

You do not need the study to use the printout: any symbol-keyed bundle with a
`:config` will do. This is a complete, working example -- run it from the repository
root:

```julia
using DiscreteSim

## 1. a question and a design: an M/M/1 queue, six replications
build(opts) = build_model(:mmc, model_params(:mmc, (arrival_rate = 0.8, servers = 1)), opts)
σ = build(SymDict(:seed => 7, :horizon => 4000.0, :trace => true))
warmup!(σ, 400.0)
run!(σ)
res = experiment(build, ExperimentConfig(replications = 6, horizon = 4000.0,
    warmup = 400.0, seed = 7))

## 2. the bundle the printout reads: the run, the experiment, the model, the design
bundle = SymDict(
    :model => :mmc,
    :run => σ,
    :experiment => res,
    :config => SymDict(:title => :MyQueue, :seed => 7, :replications => 6,
        :horizon => 4000.0, :warmup => 400.0),
    :observed => observed_summary(σ, :server),
    :theory => theory(:mmc; λ = 0.8, μ = 1.0, c = 1),
    :figures => figure_set(SymDict(:run => σ, :model => :mmc)))

## 3. the printout: the HTML always, the PDF when a browser is there
out = print_section_pdf(bundle, :queues; root = ".")
(out[:html], out[:printed])         # ("reports\\html\\notebook_queues.html", true)
```

Every section works on any bundle that carries the records it reads, and a section
that finds nothing prints nothing instead of failing: `:overview`, `:engine`,
`:queues`, `:models`, `:experiments`, `:calibration`, `:online`, `:reports`. The
`reports/html/*.html` a study already wrote are the same documents.

For a document of your own shape, build the HTML yourself and print it:

---

## Using the package as a library

`@process` *spawns* a call: the body of a process is an ordinary function, and
`@process σ name(σ)` starts it.

```julia
using DiscreteSim

σ = Sim(:clinic; seed = 20260101, horizon = 4000.0, time_unit = :minutes)
warmup!(σ, 400.0)                                     # discard the transient
doctors = resource!(σ, Resource(:doctor; capacity = 3))

"""The generator: one patient every 1.6 minutes, each with a visit of its own."""
function arrivals(σ)
    while σ.now <= σ.config.horizon
        hold!(σ, exp_rv(σ, :interarrival, 1 / 1.6))
        spawn!(σ, () -> visit(σ, doctors), name = :patient)
    end
end

"""One patient's visit: wait for a doctor, be seen, leave."""
function visit(σ, doctors)
    request!(σ, doctors)                              # waits in the queue
    hold!(σ, sample_rv(σ, :service, :lognormal => (log(3.5), 0.6)))   # median 3.5 min
    release!(σ, doctors)
    count!(σ, :completed)
end

@process σ arrivals(σ)                                # start the generator
run!(σ)
```

```text
utilisation(σ[:doctor])    0.859        # time-weighted, over the whole pool
mean_wait(σ[:doctor])      4.52         # minutes, the queue's own statistic
σ[:completed][:total]      2240         # a symbol-keyed counter
little_law(σ, :doctor)[:holds]   true    # L = λW, checked on the run you just made
```

A model reads like sequential code because `hold!` *suspends* the process and the
calendar keeps the loop; `spawn!` is how a process starts another one (one per patient
here, one per job in the job shop).

Worth knowing when you write your own model:

* **Time is yours.** `hold!` suspends a process; the calendar keeps one event loop, so
  a process reads like sequential code.
* **Blocking is the point.** `request!` blocks while the resource is busy, `fill!`
  while a container would overflow, `retrieve!` while a store is empty.
* **Interruptions are catchable.** `interrupt!` is how a breakdown, a shift change or
  an impatient caller reaches a process in the middle of work; the process can finish
  what it holds, keep the remainder and queue again (see `shop_hold!` in

## Changing the study

`scripts/run_study.jl` takes flags; everything else has a default that makes sense.

| Flag | Default | What it does |
|---|---|---|
| `--seed=20260101` | `20260101` | the seed of the history, the experiments and the reevaluation |
| `--days=90` | `90` | length of the plant history |
| `--reps=12` | `12` | replications per experiment |
| `--horizon=6000` | `6000` | length of one run, in the model's time unit |
| `--warmup=600` | `600` | time discarded at the start of every run |
| `--model=machine_shop` | `machine_shop` | the model the study is built around |
| `--objective=cycle_time_mean` | `cycle_time_mean` | the metric the comparison and the sweep optimise |
| `--online=offline_first` | `offline_first` | `offline_first`, `online_first` or `cache_only` |
| `--url=...` | this repository's raw feed | where the periodic feed lives |
| `--no-data`, `--no-figures`, `--no-pdf` | off | skip the CSV/JSON, the figures, the PDFs |
| `--parallel` | off | spread the replications over the available threads |

The same options are fields of `PipelineConfig`, which is what a script drives:

```julia
bundle = run_study(PipelineConfig(featured = :call_center, replications = 20,
    horizon = 8000.0, warmup = 800.0, parallel = true))
```

Two things to know about the study's design:

* **The sweep walks around the model, not around a hard-coded number.** Unless
  `sweep_values` is set, the five points are `sweep_factors` (0.6, 0.8, 1.0, 1.2, 1.4)
  times the value the model has *after calibration*: a sweep of absolute values would
  sit far from the operating point of a model whose parameters came from data, and
  would answer a question nobody asked.
* **The pipeline calibrates; it does not take parameter overrides.** The study *is*
  the calibration. To drive a model by hand, build it yourself and use the library --

## When something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `no study found at .../data/analysis.json` | the notebooks were opened before the study was run | `julia --project=. scripts/run_study.jl` |
| The print cell prints but `:printed` is `false` | no Chromium browser | install Chrome or Edge, or pass `chrome = "C:\\path\\chrome.exe"`; the HTML is still written |
| `print_section_pdf` writes a nearly empty document | the bundle has no records for that section (a section prints nothing rather than failing) | give the bundle what the section reads (see the example above) |
| A notebook errors on `using DiscreteSim` | the notebook environment is not activated | run its first cell (`Pkg.activate(@__DIR__)`), once |
| `run_notebooks.jl` reports `FAIL` | a cell errored; the first lines of its error are printed | open that notebook in Pluto and look at the cell |
| The online record says `:offline_cache` or `:cached` | no network, or the feed is unreachable | nothing -- that is the design; the `:error` field says what happened |
| The reevaluation says `:escalate` with `:stale_source` | the feed is older than `ttl_days` | refresh the feed, or read the log entry: it names the reason |
| A sweep comes out completely flat | the values sit far from the operating point, or the parameter is not varied | check `sweep_values_of`/`sweep_values`; a flat sweep is a *finding* when the system is capacity-bound |
| The validation says `:marginal` | the run disagrees with the closed form within tolerance, not tightly | more replications (`--reps`), a longer horizon, or a longer warmup |

## Where everything is

```text
Project.toml                    the package
Manifest.toml                   the exact dependency versions used here
src/                            the engine, the analysis and the report (one file per layer)
  symbols.jl  symdict.jl  errors.jl      the vocabulary: everything categorical is a Symbol
  calendar.jl  clock.jl  types.jl        the next-event loop
  process.jl  resources.jl               processes and the things they wait for
  stats.jl  trace.jl  random.jl          statistics, the trace, the named streams
  analytical.jl  experiments.jl  models.jl  closed forms, designs, the five models
  data.jl  online.jl                     the plant history, the calibration, the feed
  figures.jl  printout.jl  pdf.jl        the report and its printouts
  notebooks.jl  pipeline.jl              notebook checks, headless runs, the one-command study
notebooks/                      the eight Pluto notebooks and their own Project.toml
scripts/run_study.jl            the study: data, experiments, printouts, PDFs
scripts/run_notebooks.jl        run every notebook headless (and print its PDF)
scripts/validate_notebooks.jl   the static checks of the notebooks
scripts/make_notebooks.jl       author (or re-author) the notebooks
test/                           the test suite, one file per layer
docs/HOW_TO_USE.md              this document
docs/THE_CASE.md                what is being simulated, and what the numbers mean
data/                           generated observations, calibration, analysis, reevaluation log
reports/figures/                the charts, as PNG
reports/html/                   the printouts (self-contained: CSS and figures embedded)
reports/pdf/                    the PDFs, printed from those printouts by headless Chromium
```

  that is what the notebooks' live cells do.

  `src/models.jl`).
* **Statistics are registered by name and know their kind**: `Tally` for durations,
  `TimeWeighted` for levels and utilisations, `Counter` for outcomes, `Recorder` for a
  series, `Histogram` for a shape.
* **A run cannot hang.** `max_events`, `max_seconds` and the strict error policy stop
  it and name the process that failed.


```julia
rows = [SymDict(:metric => :wait_mean, :value => mean(σ[:wait]), :unit => :minutes),
        SymDict(:metric => :utilisation, :value => utilisation(σ[:server]), :unit => :ratio)]
doc = document_html("My queue", "M/M/1 at rho = 0.8",
    [:result => section_html(:result, "The run", table_html(rows, [:metric, :value, :unit]))];
    meta = SymDict(:model => :mmc, :seed => 7), footer = "printed from my own cell")
write_printout("reports/html/my.html", doc)
html_to_pdf("reports/html/my.html", "reports/pdf/my.pdf")      # returns the PDF path
```

```

Notebook `07` prints the whole study as well, with the table of contents:

```julia
full = print_report_pdf(bundle; root = ROOT)   # reports/pdf/discrete_sim_report.pdf
```

Worth knowing:

* **The PDF is a print of the notebook's own printout**, not a second document: the
  HTML you see in the cell and the HTML that is printed are the same document.
  Re-running the cell reprints it, with a new `Generated:` stamp in the header.
* **Opening a notebook prints nothing.** The print cell is an ordinary cell: it
  prints when it runs.
* **No browser, no PDF.** The HTML is still written and the record says
  `:printed => false`; `pdf_available()` and `find_chrome()` tell you why (Windows:
  Chrome, Edge, Chromium and Brave are looked for in their usual places). Pass
  `chrome = "C:\\path\\to\\chrome.exe"` to be explicit.
* **Everything in a printout is a function of the seed, except the stamp** it carries
  of the moment it was printed. Pin it with
  `config[:generated] = "2026-09-24 07:21:20"` (or set it to `""` to omit it) if you
  need byte-identical documents.

## Running the notebooks without a browser

```sh
julia --project=. scripts/validate_notebooks.jl        # static: structure, bindings, printout cells
julia --project=. scripts/run_notebooks.jl --no-save   # headless: run each notebook, print its PDF
julia --project=. scripts/run_notebooks.jl --only=00_Study,03_The_Models --no-save
```

`validate_notebooks.jl` is fast and checks what can be checked without running
anything: the Pluto header, unique cell ids, the `Cell order` section, every code cell
parsing to one top-level expression, no cell referring to a global that is not defined
earlier, at least one cell writing the printout, and markdown cells that interpolate
inside a code span (Julia prints those literally, which is a way for a notebook to
tell the reader something that is not true). A notebook that fails lists its problems.

`run_notebooks.jl` is the honest one: it starts Pluto in this repository, runs every
cell of every notebook, and reports `PASS` or `FAIL` with the first lines of the cell
that errored -- the way a reader would find out. It is also what produces the PDFs, so
if the PDFs are there, the notebooks ran.
