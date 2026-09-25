# The case this repository demonstrates

**A job shop, measured, modelled, and then asked what it should do.** The plant is a
five-machine shop with routings, rework, scrap, breakdowns and a limit on the work it
will take. The measurements are 45 days of its arrivals, service times, failures,
repairs and order sizes. The model is calibrated from those measurements, validated
against the identities that must hold, and then used to answer four questions:

1. **What does the shop do today?** -- throughput, lead time and work in progress,
   each with a confidence interval (report section *Overview*).
2. **Is the engine right?** -- the same engine reproduces Erlang C and Little's law
   where closed forms exist (sections *Queues*, *Engine*).
3. **What would make it better?** -- four scenarios compared in pairs, a sweep of the
   arrival rate, and a two-level factorial design (sections *Queues*, *Experiments*).
4. **Is the model still the plant?** -- a periodic reevaluation against a fresh feed,
   with a verdict written to an append-only log (section *Online*).

Every number below is produced by `julia --project=. scripts/run_study.jl` and is in
`data/analysis.json`. How to run things is in [`HOW_TO_USE.md`](HOW_TO_USE.md).

---

## 1. The plant, as measured

The history in `data/` is *generated* (`generate_history`), which is what makes the
whole repository reproducible from one seed -- and it is generated so as **not** to be
an exponential in disguise: a calibration that assumed it was would fail its own test.

```text
45 days = 64 800 minutes        seed 20260101
54 127 arrivals     48 780 services     354 failures     82 orders      2 large orders
```

| The generator does this | Parameter | Value |
|---|---|---|
| arrivals drift linearly upwards over the window | `drift` | +25% |
| weekends are slower | weekend factor | x0.75 |
| service times improve after a maintenance event | `maintenance_day`, `service_improvement` | day 45, -12% |
| failures arrive with a Weibull interval | `failure_mtbf` | 180 min |
| demand sizes are lognormal with occasional large orders | `demand_mean` | 12 units |

## 2. The measurement: five series, four families each

`calibrate` fits maximum likelihood to four families per series, tests every fit with
Kolmogorov--Smirnov, ranks them by AIC, and keeps the winner:

| Series | Best family | Mean | Sample mean | CV | n | KS stat | KS p |
|---|---|---|---|---|---|---|---|
| `interarrival` | gamma | 1.197 | 1.197 | 1.005 | 54 127 | 0.003 | 0.741 |
| `service` | lognormal | 1.329 | 1.328 | 0.473 | 48 780 | 0.003 | 0.798 |
| `failure_interval` | weibull | 172.25 | 172.34 | 0.663 | 354 | 0.024 | 0.988 |
| `repair` | lognormal | 11.07 | 11.11 | 0.529 | 354 | 0.044 | 0.488 |
| `demand_size` | lognormal | 14.34 | 14.44 | 0.488 | 82 | 0.056 | 0.957 |

The interesting row is `service`. Ranked by AIC the lognormal wins by a mile, and the
exponential is *last*:

```text
lognormal    rank 1   KS p 0.798    AIC  78 241
gamma        rank 2   KS p 1.7e-46  AIC  79 797
weibull      rank 3   KS p 2.6e-163 AIC  86 040
exponential  rank 4   KS p 0        AIC 125 269

## 3. From the measurements to the model

`model_params_from_calibration` starts from the catalogue's reference parameters and
replaces what the data can actually speak about:

| Model parameter | Comes from | Value in this study |
|---|---|---|
| `arrival_rate` | the `interarrival` fit | 0.8353 jobs/min |
| `cycles` (per machine) | the `service` fit, **scaled** | 0.65 / 0.47 / 0.56 / 0.56 / 0.47 min |
| `mtbf`, `mttr` | the `failure_interval` and `repair` fits | 172.25 min, 11.07 min |
| `machines`, `routing`, `mix`, `setup_time`, `scrap_rate`, `rework_rate`, `wip_limit` | the catalogue (the plant data does not measure them) | mill/drill/grinder/lathe/press, 2 min setup, 2% scrap, 6% rework, WIP limit 80 |

The `cycles` row is what keeps the model honest. The reference shop's routing needs
28.5 minutes of machine time per job; the plant's measured service time is 1.329
minutes. Calibrating the arrival rate from the plant and leaving the processing times
at their reference values would describe **two different plants** -- and the shop would
survive only by refusing most of its demand. The cycles are therefore scaled until the
work content of an average job *is* the measured service time, so the arrival rate and
the processing times belong to the same system: same 45 days, same machines, same work.

## 4. The model

`build_model(:machine_shop, params, opts)` -- five single-capacity machines, a product
mix with a routing, rework and scrap per operation, and breakdowns that *interrupt* the
job:

* a breakdown interrupts the job on the machine: the job releases what it holds, keeps
  its remaining work and queues again, and the repair must finish before the machine
  can be granted again (`shop_hold!`). That is why availability, not just utilisation,
  shows up in the lead time;
* the shop refuses work beyond `:wip_limit` and counts it (`:lost_orders`,
  `:status => :refused`), so an overloaded configuration is a *result* rather than a
  runaway run;
* each job carries a due date derived from its standard work content, so tardiness is
  measured rather than assumed.

## 5. The design

| | |
|---|---|
| replications | 8 |
| horizon | 4000 minutes each |
| warmup | 400 minutes discarded |
| seed | 20260101 |
| randomness | named streams: two scenarios in the same replication draw the same variates, so a paired comparison is sharp by construction |

Intervals are Student-t intervals over the replications; a comparison is an interval

---

## 6. What the shop does (8 replications, 3600 measured minutes each)

| Metric | Mean ± half width | Unit | Reading |
|---|---|---|---|
| Throughput | 0.807 ± 0.019 | items/min | about 48 jobs an hour |
| Completed | 2904.75 ± 69.66 | count | per replication |
| Cycle time (mean) | 14.772 ± 1.575 | minutes | sojourn in the shop |
| Wait (mean) | 14.772 ± 1.575 | minutes | the same statistic: every minute a job is in the shop is a minute of queuing for a machine |
| Wait (p95) | 45.472 ± 7.774 | minutes | the tail is three times the mean |
| WIP (mean) | 11.891 ± 1.522 | count | jobs in the shop at any moment |
| Utilisation | 0.566 ± 0.013 | ratio | average over the five machines |
| Availability | 0.915 ± 0.013 | ratio | a machine is down 8.5% of the time |
| Scrapped | 141.5 ± 13.9 | count | 4.6% of the jobs started fail quality |
| Reworked | 427.75 ± 17.34 | count | 13.6% of the jobs visit an operation twice |
| Tardiness (mean) | 9.855 ± 1.548 | minutes | against due dates from the standard work content |

Two cross-checks are printed next to those numbers, and both hold:

* **Little's law across the whole shop**: `wip ≈ throughput × cycle time` gives
  11.891 against `0.807 × 14.772 = 11.92` -- **0.2% apart**. (The same identity is
  checked per machine: `validate_model` reports the busiest resource, `:grinder`, at
  2.4% error against a 10% tolerance -- verdict `:validated`.)
* **Availability against the measurements**: 172.25 / (172.25 + 11.07) = 0.940 from the
  fits, 0.915 ± 0.013 measured over the eight windows. The two agree to within a couple
  of percent; the small gap is what a ratio of means and a mean of ratios do on finite
  windows.

A machine is busy 57% of the time, the shop works on about twelve jobs at once, a job
is in the shop for a quarter of an hour, and a fifth of the lead time is the tail
beyond the 95th percentile. That is a shop with slack, and every question below is
asked at that operating point.

## 7. What would make it better (paired comparisons against the baseline)

Four scenarios change one thing each -- demand (-10%), reliability (MTBF +50%),
quality (half the scrap and half the rework), or nothing (`:baseline`) -- and each is
compared with the baseline *in the same replication*, so the comparison is of
differences and the common random numbers cancel the noise:

| Scenario | Cycle time (mean ± hw) | Verdict on cycle time | Throughput | Completed |
|---|---|---|---|---|
| `reliability_up` | 12.463 ± 1.227 | **better** (-2.31 [-3.50, -1.11]) | indistinguishable | indistinguishable |
| `demand_down` | 12.680 ± 1.420 | better (-2.09 [-3.46, -0.73]) | worse (-0.081) | worse (-290) |
| `baseline` | 14.772 ± 1.575 | -- | -- | -- |
| `quality_up` | 14.415 ± 1.480 | better (-0.36 [-0.51, -0.20]) | **better** (+0.019) | **better** (+68) |

Read the table for what it says and not more:

* **Reliability buys lead time, not throughput.** A 50% longer MTBF shortens every
  job's wait by 2.3 minutes (an interval that excludes zero) while the output stays
  where it was: the shop has spare capacity, so fewer breakdowns shorten the waiting
  without adding to the output. This is the kind of sentence a paired comparison earns
  and an unpaired one does not.
* **Cutting demand shortens the lead time and costs output.** `:demand_down` moves the
  whole distribution left; the verdicts say "better" for time and "worse" for volume,
  which is exactly the trade a planner is being asked to make.
* **Quality is the only scenario that improves both** the throughput and the number of
  jobs completed (+68 jobs, +2.4%), at a slightly better cycle time. Halving rework
  removes work from the shop instead of moving it around.
* **`:utilisation` verdicts point the other way on purpose**: a scenario that makes the

## 9. The diagnostics, including the one that says "I cannot tell"

* **Warmup (Welch).** Over 4 replications the WIP series suggests discarding the first
  **3829.6** minutes, with a plateau of 13.31 and a band of ±1.91 -- that is, *almost the
  whole horizon*. Read that as a refusal, not as a recommendation: the shop's work in
  progress wanders by about three jobs around thirteen all the way to the end, so no
  window is flat within its own band. The report says so in words, and the study's 400
  minutes are a *design decision* -- the shop fills up in a couple of cycle times and
  the arrival process is stationary from the start -- not a measurement.
* **Batch means (one long run).** The same cycle time from a single run: 14.772 ± 2.031
  over 4 batches, lag-1 autocorrelation 0.219, `:adequate => false`. Eight independent
  replications give ±1.575; one run cut into four batches gives ±2.031 and admits the
  batch length is short. The two answers agree, and the tool says which one to trust.

## 10. The model is still the plant (the periodic reevaluation)

Running the study fetches the published feed (this repository's own
`data/online_feed.json`), recalibrates from the freshest observations it can reach and
compares them with the model in use:

```text
source    :online (status :ok, freshness :fresh, 165 884 bytes)
verdict   :keep (within_threshold)
worst change of a parameter: 4.7%   against a threshold of 10%
log       data/reevaluation_log.json, one append-only record per run, plan: every 7 days
```

The comparison is per parameter (arrival rate, service rate, MTBF, MTTR, demand mean)
and per sample (a Kolmogorov--Smirnov test between the two windows), and the verdict is
`:recalibrate`, `:keep` or `:escalate`. Here the fresh window moves the arrival rate by
less than 5%, so the model stays. With the network unplugged the same command still
works: the feed comes from a local copy or the last cached reply, `:source` says which
one answered, and the verdict says `:escalate`/`:stale_source` when the data is too old
to decide with.

## 11. What this case does not claim

The honest list, so the numbers above are not read for more than they are:

* **The history is generated, not observed.** It is generated to be awkward (a drift,
  a weekday pattern, a maintenance event, Weibull failures) and the calibration code is
  the real one, but no real plant produced these 54 127 arrivals. Replace
  `generate_history` with your own observations and nothing else changes.
* **Only arrivals, services, failures, repairs and order sizes are measured.** The
  routing, the mix, the setup time, the scrap and rework rates, the machine set and the
  WIP limit come from the catalogue. A real study would measure them too; the report
  says which parameters came from data (`data/calibration.json` -> `:parameters`) and
  which did not.
* **The plant data is not used to drive demand beyond its rate and variability.** The
  service series is one observation per job, so it calibrates the *work content* of a
  job, not the distribution of time per operation.
* **There is exactly one periodic reevaluation per study run.** `ReevaluationPlan(7, :days)`
  and `due(plan, last)` are what a scheduler asks; the study itself reevaluates once and
  appends one record.
* **The comparison is pairwise and sharp; the sweep is not.** A sweep point costs
  `replications ÷ 2` runs, which is why the sweep's intervals are wider than the
  comparison's. Both are printed with their intervals for exactly that reason.
* **Four scenarios and one objective are a demonstration, not a decision.** The
  machinery (any number of scenarios, any objective, any sweep parameter) is what the
  repository is offering; the study is one use of it.

## 12. Where each number lives

| You want | Read |
|---|---|
| the observations | `data/observations_*.csv`, `data/history.json` |
| the fits, the tests, the ranking | `data/calibration.json`, notebook `05_Calibration.jl` |
| the headline numbers of the shop | `data/analysis.json` (`:experiment`), notebook `00_Study_Overview.jl` |
| the comparison, the sweep, the factorial | `data/analysis.json` (`:comparison`, `:sweep`, `:factorial`), notebook `02_Queues_and_Capacity.jl`, `04_Experiments_and_Confidence.jl` |
| the validation and Little's law | `data/analysis.json` (`:validation`), notebook `01_The_Engine.jl` |
| the feed and the reevaluation log | `data/online_feed.json`, `data/reevaluation_log.json`, notebook `06_Offline_and_Online.jl` |
| the figures | `reports/figures/*.png` |
| the whole thing, printed | `reports/pdf/discrete_sim_report.pdf` |
| the same thing, section by section | `reports/pdf/notebook_*.pdf`, one per notebook |

  shop *less* loaded (or shorter-lead-time) has "worse" utilisation, because
  utilisation is not the objective -- cycle time is (`:objective => :cycle_time_mean`).

## 8. Where the knee is (sweep and factorial)

The sweep walks the arrival rate around the operating point the calibration produced
(0.6x to 1.4x of 0.835/min):

| `arrival_rate` | Throughput | Cycle time | Utilisation |
|---|---|---|---|
| 0.501 | 0.490 ± 0.028 | 8.862 | 0.343 |
| 0.668 | 0.645 ± 0.032 | 12.202 | 0.454 |
| 0.835 | 0.806 ± 0.044 | 15.709 | 0.565 |
| 1.002 | 0.963 ± 0.049 | 22.179 | 0.676 |
| 1.169 | 1.103 ± 0.044 | 41.067 | 0.773 |

Throughput grows almost linearly -- the shop has slack -- while the cycle time starts
to bend upwards between 1.00 and 1.17, the queueing knee. The two-level factorial on
the same factor gives the effect of moving to the top of that range on the lead time:
**+32.2 ± 13.9 minutes, verdict `:hurts`** -- the interaction-free statement of the same
finding, with an interval.

This is also why the sweep has to be defined *relative to the calibrated value*: a
sweep of absolute numbers around 0.1/min would sit ten times below the operating point
and come out perfectly flat, which looks like a finding and is an artefact.

of the *differences*, which is what makes a two-minute improvement visible at all.

```

That is the point of the exercise: **the data is not exponential, and the calibration
says so with a p-value**, not with an opinion. (It is also the row that justifies
building the whole random layer on named streams and inversion sampling: any family
the fit chooses can be sampled.)

From the fits, `inferred_parameters` produces what a model needs:

```text
arrival_rate  0.8353 /min      service_rate  0.7527 /min
mtbf          172.25 min       mttr          11.07 min        availability  0.940
arrival_cv2   1.011            service_cv2   0.224            demand_mean   14.34
```

Each of those numbers carries a bootstrap interval when you ask for one
(`bootstrap_ci`), and the calibration section of the report prints the fits, the
ranking and the tests side by side.
