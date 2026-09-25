# DiscreteSim -- discrete-event simulation in Julia and Pluto

**Best-in-class discrete-event simulation**: a next-event calendar, coroutines for
processes, resources with queues, statistics that know what they measure,
experiments with confidence intervals, models calibrated from plant data, a
periodic online reevaluation that never breaks the pipeline, and a printout that
becomes a PDF.

Five models ship with the engine -- a service pool, a transfer line, a job shop,
an inventory position and a contact centre -- and every number in the report
carries the interval, the design and the seed that produced it.

```julia
using DiscreteSim

σ = build_model(:machine_shop, model_params(:machine_shop),
                SymDict(:seed => 20260101, :horizon => 4000.0, :trace => true))
run!(σ)

utilisation(σ[:grinder])        # time-weighted utilisation of the bottleneck
mean_wait(σ[:grinder])          # the queue's own waiting statistic
σ[:completed][:total]           # a symbol-keyed counter
validate_model(σ, :machine_shop, default_params(:machine_shop))[:verdict]   # :validated
```

Everything categorical is a **`Symbol`**: entities (`:job`), events (`:arrival`),
resources (`:server`, `:grinder`), disciplines (`:fifo`, `:spt`, `:edd`), the
distribution families (`:lognormal`, `:weibull`), the metrics (`:wait`,
`:queue_length`, `:utilisation`) and the verdicts (`:validated`, `:recalibrate`).
The containers are symbol-keyed and ordered (`SymDict`), so a model, a scenario, an
experiment, a notebook and the printed report all speak the same language -- and a
typo is an error, never a silently missing number.

---

## What it does

| Capability | Functions |
|---|---|
| Vocabulary, symbol-keyed records, formatting | `SymDict`, `@syms`, `Sym`, `metric_unit`, `title_string` |
| Next-event calendar and the run loop | `Calendar`, `step!`, `run!`, `advance!`, `callback!`, `stop!` |
| Coroutine processes | `@process`, `spawn!`, `hold!`, `block!`, `activate!`, `interrupt!`, `cancel!` |
| Servers, bulk stores, item stores | `Resource`, `Container`, `Store`, `request!`, `release!`, `use!`, `fill!`, `retrieve!` |
| Statistics that know their kind | `Tally`, `TimeWeighted`, `Counter`, `Histogram`, `Recorder`, `mean_ci` |
| Reproducible randomness | `stream!`, `dist`, `sample_rv`, `antithetic!`, common random numbers by construction |
| Analytical cross-checks | `theory` (M/M/1, M/M/c, M/D/1, M/G/1, G/G/1, M/M/1/K, M/M/c/K, Erlang B/C), `little_law` |
| Experiments | `experiment`, `warmup_analysis`, `batch_means`, `sweep`, `compare_scenarios`, `factorial_design` |
| Models and scenarios | `build_model`, `MODEL_CATALOGUE`, `default_params`, `scenario_params` |
| Calibration from data | `generate_history`, `fit_distribution`, `ks_test`, `best_fit`, `bootstrap_ci`, `calibrate` |
| Offline first, online periodically | `fetch_online`, `reevaluate`, `ReevaluationPlan`, `reevaluation_log` |
| The report and the PDFs | `report_html`, `preview_section`, `print_section_pdf`, `print_report_pdf` |
| The study in one call | `run_study`, `load_study`, `report_manifest` |
| Notebooks as deliverables | `validate_notebooks`, `run_notebook` |

## Documentation

| Document | What it is for |
|---|---|
| **[docs/HOW_TO_USE.md](docs/HOW_TO_USE.md)** | how to install it, run the study, open the notebooks, print the PDFs, write your own model, and what to do when something goes wrong |
| **[docs/THE_CASE.md](docs/THE_CASE.md)** | what this repository simulates: the plant, the measurements, the model, the design, every result, and what the case does not claim |
| the file headers in `src/` | each file explains itself: `src/` is one file per layer, ~8 000 lines, no hidden machinery |

## Quick start

```julia
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -e 'using Pkg; Pkg.test()'                 # the test suite
julia --project=. scripts/run_study.jl                       # data + experiments + PDFs
julia --project=. scripts/validate_notebooks.jl              # static notebook checks
julia --project=. scripts/run_notebooks.jl                   # run every notebook headless
```

Open the notebooks with Pluto:

```julia
julia --project=. -e 'import Pluto; Pluto.run()'
```

then open `notebooks/00_Study_Overview.jl`. Each notebook loads the study from disk,
shows its section of the report and **prints that section to PDF in its last cell** --
so `reports/pdf/notebook_*.pdf` is what the notebooks themselves produced. The details
(what every notebook shows, what the print cell returns, how to print your own
analysis) are in [docs/HOW_TO_USE.md](docs/HOW_TO_USE.md).

### A first session in the REPL

```julia
using DiscreteSim

σ = Sim(:clinic; seed = 20260101, horizon = 4000.0, time_unit = :minutes)   # a run is a function of its seed
warmup!(σ, 400.0)                                     # discard the transient
doctors = resource!(σ, Resource(:doctor; capacity = 3))

"""The generator: one patient every 1.6 minutes."""
function arrivals(σ)
    while σ.now <= σ.config.horizon
        hold!(σ, exp_rv(σ, :interarrival, 1 / 1.6))
        spawn!(σ, () -> visit(σ, doctors), name = :patient)
    end
end

"""One patient: wait for a doctor, be seen, leave."""
function visit(σ, doctors)
    request!(σ, doctors)
    hold!(σ, sample_rv(σ, :service, :lognormal => (log(3.5), 0.6)))  # median 3.5 min
    release!(σ, doctors)
    count!(σ, :completed)
end

@process σ arrivals(σ)                                # @process spawns a call
run!(σ)

(utilisation = round(utilisation(σ[:doctor]), digits = 3),
    wait = round(mean_wait(σ[:doctor]), digits = 2),
    completed = σ[:completed][:total], little_law = little_law(σ, :doctor)[:holds])
# (utilisation = 0.859, wait = 4.52, completed = 2240, little_law = true)
```

`@process` *spawns* a call: the body of a process is an ordinary function, and
`@process σ name(σ)` starts it. `hold!` suspends the process and the calendar keeps the
loop, so a model reads like sequential code.

### A study in three lines

```julia
bundle = run_study(PipelineConfig(featured = :machine_shop, replications = 12,
    horizon = 6000.0, warmup = 600.0))
report_manifest(bundle[:manifest])
```

`run_study` writes `data/*.json`, `data/*.csv`, `reports/figures/*.png`,
`reports/html/*.html` and `reports/pdf/*.pdf` -- including one PDF per section and the
whole study as one document. `load_study(root)` reads it back in a second, so a
notebook shows the same numbers without re-running anything.


## The engine

* **The calendar** is a binary min-heap of `(time, priority, seq)`: the earliest
  event first, ties broken by priority and then by insertion, which is what makes a
  run reproducible.
* **Processes** are Julia tasks that suspend on two channels each -- the classic
  coroutine hand-off, with no macros to expand and no stacks to rewrite. A model
  reads like sequential code; the engine keeps one event loop.
* **Everything is recorded**: the trace (a `Tables.jl` source), the time-weighted
  statistics, the counters, the calendar itself. `little_law(σ, :server)` checks
  `L = λW` on the run you just made, and `validate_against_theory` compares it with
  the closed form.
* **A model bug cannot hang a pipeline**: `max_events`, `max_seconds` and a strict
  error policy stop a run and name the process that failed -- including an
  *uncaught* `SimInterrupt`, which would otherwise leak a machine silently.

## The five models

| Model | Question | What makes it interesting |
|---|---|---|
| `:mmc` | how many servers do we need? | Erlang C in the same units, a balking threshold, any discipline |
| `:transfer_line` | where is the bottleneck? | buffers, blocking, starvation, MTBF/MTTR per station |
| `:machine_shop` | what is the OEE? | routings, rework, scrap, breakdowns that *interrupt* a job, a WIP limit |
| `:inventory` | what service level does this stock buy? | an `(s, S)` policy with lead time and backorders, written with callbacks |
| `:call_center` | do we meet the service level? | shifts, VIP priority, abandonment through a real interruption |

## Experiments

One run is not an answer. The package gives the honest tools:

* **replications** with Student-t intervals (`experiment`);
* **Welch's warmup detection** (`warmup_analysis`), so the transient is discarded
  deliberately rather than by habit;
* **batch means** for the interval of a single long run (`batch_means`);
* **paired comparisons** with confidence intervals, made sharp by common random
  numbers (`compare_scenarios`);
* **sweeps** and **two-level factorial designs** with main effects and
  interactions (`sweep`, `factorial_design`).

## Calibration and the periodic reevaluation

The plant history in `data/` is a *generated* one (drifting arrivals, a weekday
pattern, a maintenance event that changes the service time, Weibull failures), so
the whole repository is reproducible -- but the calibration code is the real one:
maximum-likelihood fitting of four families per series, a Kolmogorov--Smirnov test
of each fit, a bootstrap interval of every parameter, and a map from the
observations to the model parameters.

The data layer is **offline first**:

```
online HTTP  ->  the local copy of the same feed  ->  the last cached reply  ->  offline
```

Nothing throws when the network is down; the feed is timestamped, its freshness is
reported (`:fresh`, `:stale`, `:expired`) and `reevaluate` writes a verdict
(`:recalibrate`, `:keep`, `:escalate`) into an append-only log
(`data/reevaluation_log.json`) -- which is what makes a *periodic* reevaluation
auditable rather than mysterious. `ReevaluationPlan(7, :days)` and `due(plan, last)`
are what a scheduled job asks before it does anything.

## Repository layout

```
Project.toml              the package
src/                      the engine, the analysis and the report (one file per layer)
notebooks/                eight Pluto notebooks + their own environment
scripts/run_study.jl      the whole study: data, experiments, printouts, PDFs
scripts/run_notebooks.jl  run every notebook headless
scripts/validate_notebooks.jl  static checks of the notebooks
scripts/make_notebooks.jl      author (or re-author) the notebooks
test/                     the test suite (one file per layer)
docs/HOW_TO_USE.md        how to use the package, the notebooks and the PDFs
docs/THE_CASE.md          the case this repository demonstrates, with every number
data/                     generated observations, calibration, analysis, reevaluation log
reports/figures/          the charts, as PNG
reports/html/             the printouts (self-contained: CSS and figures embedded)
reports/pdf/              the PDFs, printed from those printouts by headless Chrome
```

## Notebooks

| Notebook | Section of the report |
|---|---|
| `00_Study_Overview.jl` | what was simulated, with which design |
| `01_The_Engine.jl` | the calendar, the processes, the trace (with live demos) |
| `02_Queues_and_Capacity.jl` | Erlang C against the simulation, and a capacity sweep |
| `03_The_Models.jl` | the five models, one at a time |
| `04_Experiments_and_Confidence.jl` | warmup, replications, paired comparison |
| `05_Calibration.jl` | fitting, testing and the bootstrap |
| `06_Offline_and_Online.jl` | the fallback chain and the reevaluation log |
| `07_Artefacts_and_PDF.jl` | every artefact, and the whole report as one PDF |

Every notebook loads the study from disk, shows its section, and **prints that
section to PDF in its last cell** (`print_section_pdf`): the notebook *is* the
report, and the PDF is its printout -- the same HTML, printed.

## Method and assumptions

* **Determinism.** A run is a pure function of its seed: streams are named (so two
  scenarios in the same replication draw the same variates) and calendar ties are
  broken by insertion order.
* **Adequate statistics.** `TimeWeighted` for queue lengths, work in progress and
  utilizations; `Tally` for waits, services and sojourns; `Counter` for outcomes;
  `Recorder` for the shape over time. The report says which is which.
* **Warmup.** Discarded by an ordinary callback that resets every statistic, so the
  measured window is explicit (`measured_span`) and the throughput denominators are
  right.
* **Validation.** A model is only trusted when it reproduces the closed form
  (Erlang C for the queues) or satisfies the identities that must hold (Little's law
  per resource, a demand-size generator that matches its own expectation).
* **Units.** Each model counts in its own unit (`:minutes` for the plant models,
  `:days` for the inventory) and every statistic carries the unit it measures.
* **The WIP limit.** The job shop refuses work beyond `:wip_limit` (counted in
  `:lost_orders`), which is what keeps an overloaded scenario a *result* instead of
  a runaway run.

## Testing

```julia
julia --project=. -e 'using Pkg; Pkg.test()'
```

The suite covers the vocabulary and the container, the calendar, the processes
(holds, blocks, interruptions, the error policy), the resources (capacities,
disciplines, containers, stores, breakdowns), the statistics, the streams and the
distribution vocabulary, the analytical formulas **and the engine against them**,
the experiment designs, the five models, the calibration, the offline/online data
layer, the printout and the PDF printing, the notebooks (static checks, plus a
headless Pluto run when `DISCRETESIM_TEST_PLUTO=true`) and the pipeline with a
`study_json`/`load_study` round trip.

## Publishing

The repository is `https://github.com/caxelrud/Julia_Discrete_Sim_2026` and the
branch is `main`:

```sh
git add -A
git commit -m "message"
git push
```

To refresh the published artefacts (data, figures, printouts and PDFs) before
pushing:

```sh
julia --project=. scripts/run_study.jl --parallel
julia --project=. scripts/run_notebooks.jl --no-save
```

## License

MIT -- see `LICENSE`.

