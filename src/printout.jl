# =============================================================================
# printout.jl -- the printout that becomes the PDF.
#
# One document serves three purposes: it is what a Pluto notebook shows, it is
# what the headless browser prints to PDF, and it is what a reader opens in a
# browser. To make that possible the printout is self-contained -- every figure is
# embedded as a base-64 PNG, there is no external stylesheet and no script -- and
# it is built from the same symbol-keyed records the rest of the package uses, so
# a section never has to know which model produced it.
#
# The building blocks (`table_html`, `cards_html`, `badge`, `section_html`, ...)
# are deliberately small and composable: a notebook preview and the printed report
# are the same call with the same arguments.
# =============================================================================

"""Print stylesheet: A4, sensible margins, nothing breaks across a page badly."""
const PRINTOUT_CSS = """
:root { --ink:#1b1b1b; --muted:#6b6b6b; --line:#d8dee4; --good:#2e7d32; --warn:#ef8b1b;
        --bad:#c62828; --primary:#1f5c8b; --band:#f4f7fa; }
* { box-sizing: border-box; }
body { font-family: "Segoe UI", Roboto, Helvetica, Arial, sans-serif; color: var(--ink);
       margin: 0; padding: 0; font-size: 10.5pt; line-height: 1.45; }
.page { max-width: 190mm; margin: 0 auto; padding: 10mm 6mm; }
h1 { font-size: 20pt; margin: 0 0 2mm 0; color: var(--primary); }
h2 { font-size: 13pt; margin: 7mm 0 2mm 0; padding-bottom: 1mm;
     border-bottom: 0.6mm solid var(--line); color: var(--primary); }
h3 { font-size: 11pt; margin: 5mm 0 1.5mm 0; }
p { margin: 1.5mm 0; }
.subtitle { color: var(--muted); font-size: 11pt; margin-bottom: 4mm; }
.meta { color: var(--muted); font-size: 8.5pt; }
.section { margin-bottom: 6mm; }
.lead { font-size: 11pt; }
table { border-collapse: collapse; width: 100%; margin: 2mm 0 3mm 0; font-size: 9pt; }
th, td { border-bottom: 0.2mm solid var(--line); padding: 1.2mm 2mm; text-align: left; }
th { background: var(--band); font-weight: 600; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
.cards { display: flex; flex-wrap: wrap; gap: 3mm; margin: 2mm 0 4mm 0; }
.card { flex: 1 1 30mm; border: 0.2mm solid var(--line); border-radius: 1.5mm;
        padding: 2mm 3mm; background: var(--band); }
.card .label { color: var(--muted); font-size: 8pt; text-transform: uppercase;
               letter-spacing: 0.2mm; }
.card .value { font-size: 14pt; font-weight: 600; }
.card .unit { color: var(--muted); font-size: 8.5pt; margin-left: 1mm; }
.badge { display: inline-block; border-radius: 2mm; padding: 0.3mm 1.6mm; font-size: 8pt;
         font-weight: 600; color: #fff; background: var(--muted); }
.badge.good { background: var(--good); } .badge.warn { background: var(--warn); }
.badge.bad { background: var(--bad); } .badge.info { background: var(--primary); }
figure { margin: 3mm 0; page-break-inside: avoid; }
figure img { width: 100%; border: 0.2mm solid var(--line); border-radius: 1.5mm; }
figcaption { color: var(--muted); font-size: 8.5pt; margin-top: 1mm; }
.callout { border-left: 1mm solid var(--primary); background: var(--band); padding: 2mm 3mm;
           margin: 2mm 0 4mm 0; }
.callout.good { border-color: var(--good); } .callout.warn { border-color: var(--warn); }
.callout.bad { border-color: var(--bad); }
ul, ol { margin: 1.5mm 0 2mm 5mm; padding: 0; } li { margin: 0.8mm 0; }
code, pre, .mono { font-family: "Cascadia Mono", Consolas, "Courier New", monospace;
                   font-size: 8.5pt; }
pre { background: var(--band); padding: 2mm 3mm; border-radius: 1.5mm; overflow-x: auto; }
.toc { columns: 2; font-size: 9.5pt; }
.toc a { color: var(--primary); text-decoration: none; }
.pagebreak { page-break-before: always; }
footer { margin-top: 8mm; border-top: 0.2mm solid var(--line); padding-top: 2mm;
         color: var(--muted); font-size: 8pt; }
@page { size: A4; margin: 14mm 12mm; }
@media print { .noprint { display: none; } body { font-size: 10pt; } }
"""

## ---- formatting -----------------------------------------------------------------

"""Escape the five characters that would break HTML."""
html_escape(s) = replace(string(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;",
    '"' => "&quot;", '\'' => "&#39;")

"""Format a number the way a report reads it (`NaN` becomes an em dash)."""
function fmt_number(x; digits::Integer = 3)
    x === nothing && return "—"
    x isa Symbol && return html_escape(code_string(x))
    x isa AbstractString && return html_escape(x)
    x isa Bool && return x ? "yes" : "no"
    x isa Integer && return string(x)
    x isa Real || return html_escape(x)
    isfinite(Float64(x)) || return "—"
    a = abs(Float64(x))
    a >= 1000 && return string(round(Int, x))
    a >= 10 && return round(x, digits = 1) == round(x) ? string(round(Int, x)) :
                           string(round(x, digits = 1))
    a >= 0.01 && return round(x, digits = 3) == round(x) ? string(round(Int, x)) :
                           string(round(x, digits = 3))
    a == 0 && return "0"
    return string(round(x, sigdigits = 3))
end

"""Format a value with its unit (`12.4 /h` rather than `12.4 items_per_hour`)."""
function fmt_metric(value::Real, unit::Symbol)
    u = Sym(unit)
    suffix = u === :items_per_hour ? " /h" :
             u === :items_per_minute ? " /min" :
             u === :items_per_second ? " /s" :
             u === :items_per_week ? " /wk" :
             u === :items_per_day ? " /d" :
             u === :per_hour ? " /h" :
             u === :per_minute ? " /min" :
             u === :per_second ? " /s" :
             u === :per_week ? " /wk" :
             u in (:ratio, :none) ? "" :
             u === :percent ? "%" :
             u === :currency ? " \$" : string(" ", code_string(u))
    return string(fmt_number(value), suffix)
end

"""A metric value with its unit, formatted for a table cell."""
fmt_value(x, unit::Symbol) = x isa Real ? fmt_metric(Float64(x), unit) : fmt_number(x)

"""`mean ± half width`, the way an experiment is quoted."""
function fmt_interval(ci::AbstractDict; digits::Integer = 3)
    half = num(get(ci, :half_width, NaN))
    return string(fmt_number(ci[:mean], digits = digits),
        isfinite(half) ? string(" ± ", fmt_number(half, digits = digits + 1)) : "")
end

"""A number out of a record that may have lost its `NaN` on the way through JSON."""
num(x, default = NaN) = x isa Real ? Float64(x) : Float64(default)

"""A coloured badge (`:good`, `:warn`, `:bad`, `:info`)."""
badge(text, kind::Symbol = :info) =
    string("<span class=\"badge ", code_string(kind), "\">", html_escape(text), "</span>")

"""Badge class of a verdict or a status symbol."""
function verdict_class(v::Symbol)
    v in (:validated, :keep, :fresh, :ok, :compliant, :good, :helps, :better,
        :same_process, :on_time, :served, :shipped, :measured, :online,
        :within_threshold) && return :good
    v in (:marginal, :stale, :cached, :at_risk, :warn, :late, :interrupted, :shared,
        :keep_watching) && return :warn
    v in (:failed, :recalibrate, :escalate, :expired, :offline, :noncompliant, :bad,
        :hurts, :worse, :scrapped, :abandoned, :error, :timeout, :parameter_moved,
        :sample_shifted, :no_observations_and_stale_source) && return :bad
    return :info
end

## ---- building blocks -------------------------------------------------------------

"""A paragraph of text."""
paragraph_html(text) = string("<p>", html_escape(text), "</p>")

"""A bulleted (or numbered) list; items may already be HTML."""
function list_html(items::AbstractVector; ordered::Bool = false)
    tag = ordered ? "ol" : "ul"
    body = join([string("<li>", x isa AbstractString ? x : html_escape(x), "</li>")
                 for x in items])
    return string("<", tag, ">", body, "</", tag, ">")
end

"""A boxed remark (`:info`, `:good`, `:warn`, `:bad`) with an optional title."""
function callout_html(body, kind::Symbol = :info; title = nothing)
    head = title === nothing ? "" : string("<strong>", html_escape(title), "</strong><br>")
    return string("<div class=\"callout ", code_string(kind), "\">", head, body, "</div>")
end

"""The cards above a report section: `(; label, value, unit)` records."""
function cards_html(cards::AbstractVector)
    parts = String[]
    for c in cards
        label = get(c, :label, nothing)
        value = get(c, :value, nothing)
        unit = get(c, :unit, nothing)
        label === nothing && continue
        unit_html = unit === nothing || unit === :ratio ? "" :
                    string("<span class=\"unit\">", html_escape(code_string(unit)), "</span>")
        push!(parts, string("<div class=\"card\"><div class=\"label\">",
            html_escape(title_string(label)), "</div><div class=\"value\">",
            fmt_number(value), unit_html, "</div></div>"))
    end
    return string("<div class=\"cards\">", join(parts), "</div>")
end

"""A table from symbol-keyed records: `columns` says which keys to show.

```julia
table_html(rows, [:metric, :mean, :half_width, :unit]; caption = :metrics)
```
"""
function table_html(rows::AbstractVector, columns::AbstractVector;
    caption = nothing, units::AbstractDict = Dict{Symbol,Symbol}())
    isempty(rows) && return ""
    ks = [Sym(c) for c in columns]
    head = join([string("<th>", html_escape(title_string(k)), "</th>") for k in ks])
    body = String[]
    for row in rows
        cells = String[]
        for k in ks
            value = row isa AbstractDict ? get(row, k, nothing) :
                    haskey(row, k) ? getproperty(row, k) : nothing
            unit = get(units, k, nothing)
            text = unit === nothing ? fmt_number(value) : fmt_value(value, unit)
            numeric = value isa Real ? " class=\"num\"" : ""
            push!(cells, string("<td", numeric, ">", text, "</td>"))
        end
        push!(body, string("<tr>", join(cells), "</tr>"))
    end
    cap = caption === nothing ? "" :
          string("<caption style=\"caption-side:top;text-align:left;color:#6b6b6b;\">",
              html_escape(title_string(caption)), "</caption>")
    return string("<table>", cap, "<thead><tr>", head, "</tr></thead><tbody>",
        join(body), "</tbody></table>")
end

"""A definition list of a symbol-keyed record."""
function kv_html(d::AbstractDict; keys = nothing)
    ks = keys === nothing ? collect(Symbol[k for k in Base.keys(d)]) : [Sym(k) for k in keys]
    parts = String[]
    for k in ks
        haskey(d, k) || continue
        v = d[k]
        text = v isa Real ? fmt_number(v) :
               v isa AbstractDict ? join([string(code_string(k2), "=", fmt_number(v2))
                                          for (k2, v2) in v], ", ") : html_escape(v)
        push!(parts, string("<div><span class=\"meta\">", html_escape(title_string(k)),
            "</span>&nbsp;", text, "</div>"))
    end
    return string("<div>", join(parts), "</div>")
end

"""A figure with its caption (from a `figure_of` bundle, or `nothing`)."""
function figure_html(f)
    f === nothing && return ""
    uri = f isa NamedTuple ? get(f, :uri, "") :
          f isa AbstractDict ? get(f, :uri, "") : ""
    isempty(uri) && return ""
    caption = f isa NamedTuple ? get(f, :caption, :figure) :
              f isa AbstractDict ? get(f, :caption, :figure) : :figure
    return string("<figure><img src=\"", uri, "\" alt=\"",
        html_escape(code_string(caption)), "\"><figcaption>",
        html_escape(title_string(caption)), "</figcaption></figure>")
end

"""One titled section of a report (with a stable anchor for the table of contents)."""
section_html(id::Symbol, title, body; lead = nothing) =
    string("<section class=\"section\" id=\"", code_string(id), "\">",
        "<h2>", html_escape(title), "</h2>",
        lead === nothing ? "" : string("<p class=\"lead\">", html_escape(lead), "</p>"),
        body, "</section>")

"""Write a printout to disk (creating the directory if needed)."""
function write_printout(path::AbstractString, html::AbstractString)
    mkpath(dirname(path))
    open(path, "w") do io
        write(io, html)
    end
    return path
end

## ---- the sections of the report --------------------------------------------------

"""The analysis sections a notebook, a PDF or the full report can be built from."""
const ANALYSIS_KEYS = (:overview, :engine, :queues, :models, :experiments, :calibration,
    :online, :reports)

"""The model a bundle is about, or `:mmc` when the bundle does not say."""
function bundle_model(bundle::AbstractDict)
    m = get(bundle, :model, :mmc)
    return m isa Symbol ? m : Sym(m)
end

"""Cards of the headline numbers of a bundle."""
function headline_cards(bundle::AbstractDict)
    exp = get(bundle, :experiment, nothing)
    unit = model_time_unit(bundle_model(bundle))
    cards = NamedTuple[]
    push!(cards, (label = :models, value = length(get(bundle, :models, SymDict())),
        unit = nothing))
    if exp isa ExperimentResult
        ci = metric_ci(exp, :throughput)
        ci === nothing || push!(cards, (label = :throughput, value = ci[:mean],
            unit = metric_unit(:throughput; time_unit = unit)))
        ci = metric_ci(exp, :cycle_time_mean)
        ci === nothing || push!(cards, (label = :cycle_time_mean, value = ci[:mean],
            unit = metric_unit(:cycle_time_mean; time_unit = unit)))
        ci = metric_ci(exp, :utilisation)
        ci === nothing || push!(cards, (label = :utilisation, value = ci[:mean],
            unit = :ratio))
        ci = metric_ci(exp, :completed)
        ci === nothing || push!(cards, (label = :completed, value = ci[:mean],
            unit = nothing))
    end
    haskey(bundle, :validation) &&
        push!(cards, (label = :validation, value = get(bundle[:validation], :verdict,
            :not_applicable), unit = nothing))
    haskey(bundle, :online) &&
        push!(cards, (label = :reevaluation, value = get(bundle[:online], :verdict, :keep),
            unit = nothing))
    return cards
end

"""The experiment table of one model: every metric with its interval, in the catalogue order."""
function metrics_table_html(res::ExperimentResult; only = nothing,
    time_unit::Symbol = :minutes)
    order = only === nothing ? metric_keys(res) : [Sym(k) for k in only]
    rows = SymDict[]
    for k in order
        ci = metric_ci(res, k)
        ci === nothing && continue
        isnan(num(ci[:mean])) && continue      # a statistic the model never fired
        row = SymDict()
        row[:metric] = k
        row[:mean] = ci[:mean]
        row[:half_width] = ci[:half_width]
        row[:lo] = ci[:lo]
        row[:hi] = ci[:hi]
        row[:n] = ci[:n]
        row[:rel_hw_pct] = 100 * num(get(ci, :relative_half_width, NaN))
        row[:unit] = metric_unit(k; time_unit = time_unit)
        push!(rows, row)
    end
    return table_html(rows, [:metric, :mean, :half_width, :unit, :rel_hw_pct];
        caption = string(code_string(res.name), " over ", res.config.replications,
            " replications"))
end

"""The resource table of one run: queueing performance of every resource."""
function resources_table_html(run::Sim)
    rows = SymDict[]
    for (name, r) in run.resources
        r isa Resource || continue
        row = SymDict()
        row[:resource] = name
        row[:kind] = r.kind
        row[:servers] = r.capacity
        row[:discipline] = r.discipline
        row[:utilisation] = utilisation(r)
        row[:availability] = availability(r)
        row[:queue_length] = mean_queue_length(r)
        row[:wait] = mean_wait(r)
        row[:service] = mean_service(r)
        row[:served] = count_of(r.granted, :release)
        row[:breakdowns] = total_of(r.breakdowns)
        push!(rows, row)
    end
    isempty(rows) && return ""
    return table_html(rows, [:resource, :kind, :servers, :discipline, :utilisation,
        :availability, :queue_length, :wait, :service, :served, :breakdowns];
        caption = :resources)
end

"""The overview section: what was simulated, with which design, and the headline numbers."""
function overview_section(bundle::AbstractDict)
    cfg = get(bundle, :config, SymDict())
    body = cards_html(headline_cards(bundle))
    body *= string("<h3>Design of the study</h3>",
        kv_html(cfg; keys = [:seed, :days, :replications, :horizon, :warmup, :models,
            :objective, :online_policy]))
    catalogue_rows = SymDict[]
    for name in MODELS
        c = catalogue(name)
        push!(catalogue_rows, SymDict(:model => name, :title => c.title, :entity => c.entity,
            :resource => c.resource, :answers => c.description,
            :parameters => join(code_string.(c.params), ", ")))
    end
    body *= string("<h3>The models</h3>",
        table_html(catalogue_rows, [:model, :title, :entity, :resource, :answers];
            caption = :catalogue))
    run = get(bundle, :run, nothing)
    run isa Sim && (body *= resources_table_html(run))
    exp = get(bundle, :experiment, nothing)
    exp isa ExperimentResult &&
        (body *= metrics_table_html(exp; time_unit = model_time_unit(bundle_model(bundle))))
    return section_html(:overview, "Overview", body;
        lead = "A discrete-event simulation study: the engine, the calibration and the " *
               "experiments, with every number carrying its confidence interval.")
end

"""The figures of a bundle (`SymDict`, empty when there are none)."""
figures_of(bundle::AbstractDict) = get(bundle, :figures, SymDict())

"""The engine section: what the event loop did and whether the books balance."""
function engine_section(bundle::AbstractDict)
    run = get(bundle, :run, nothing)
    body = ""
    if run isa Sim
        facts = SymDict()
        facts[:model] = run.name
        facts[:time_unit] = run.config.time_unit
        facts[:seed] = run.config.seed
        facts[:events] = run.processed
        facts[:clock] = run.now
        facts[:processes] = length(run.processes)
        facts[:statistics] = n_statistics(run)
        facts[:streams] = length(run.rngs)
        facts[:trace_rows] = n_of(run.trace)
        facts[:trace_dropped] = run.trace.dropped
        facts[:stop_reason] = run.stop_reason
        body *= string("<h3>The run</h3>",
            kv_html(facts; keys = [:model, :time_unit, :seed, :events, :clock, :processes,
                :statistics, :streams, :trace_rows, :trace_dropped, :stop_reason]))
        states = process_states(run)
        body *= string("<h3>Where the processes ended up</h3>",
            cards_html([(label = k, value = v, unit = nothing) for (k, v) in states]))
        laws = SymDict[]
        for (name, r) in run.resources
            r isa Resource || continue
            law = little_law(run, name)
            push!(laws, SymDict(:resource => name, :L => law[:L], :λ => law[:λ],
                :W => law[:W], :λW => law[:λW], :relative_error => law[:relative_error],
                :holds => law[:holds] ? :yes : :no))
        end
        isempty(laws) || (body *= string("<h3>Little's law, checked on every resource</h3>",
            table_html(laws, [:resource, :L, :λ, :W, :λW, :relative_error, :holds];
                caption = :little_law)))
        body *= figure_html(get(figures_of(bundle), :gantt, nothing))
    end
    if haskey(bundle, :validation)
        v = bundle[:validation]
        body *= string("<h3>Against theory</h3>",
            callout_html(string("Verdict: ", badge(code_string(v[:verdict]),
                    verdict_class(v[:verdict])), " &nbsp; worst relative error ",
                fmt_number(100 * num(get(v, :worst_relative_error, NaN))),
                "% against a tolerance of ",
                fmt_number(100 * num(get(v, :tolerance, 0.1))), "%."),
                verdict_class(v[:verdict])))
        body *= figure_html(get(figures_of(bundle), :validation, nothing))
        comparisons = collect(get(v, :comparisons, SymDict[]))
        isempty(comparisons) ||
            (body *= table_html(comparisons,
                [:observed_key, :theory_key, :observed, :theory, :relative_error,
                    :within_tolerance]; caption = :cross_checks))
    end
    return section_html(:engine, "The engine", body;
        lead = "A next-event calendar, coroutines that suspend on two channels, and " *
               "statistics that know whether they are adequate.")
end

"""The body of a scenario comparison (table, verdicts and figure)."""
function comparison_body(cmp::SymDict, figs::AbstractDict = SymDict())
    rows = SymDict[]
    for c in cmp[:comparisons]
        push!(rows, SymDict(:scenario => c[:label], :metric => c[:metric],
            :baseline => c[:baseline_mean], :scenario_mean => c[:scenario_mean],
            :difference => c[:difference], :half_width => c[:half_width],
            :relative_pct => 100 * c[:relative_difference], :verdict => c[:verdict]))
    end
    best = get(cmp, :best, :none)
    return string("<h3>Scenarios against the baseline</h3>",
        table_html(rows, [:scenario, :metric, :baseline, :scenario_mean, :difference,
            :half_width, :relative_pct, :verdict]; caption = :scenarios),
        figure_html(get(figs, :scenarios, nothing)),
        callout_html(string("Best by ", code_string(cmp[:objective]), ": ",
            badge(code_string(best), :good), " (compared with ", code_string(cmp[:baseline]),
            ", common random numbers on every replication)."), :good))
end

"""The queues section: the Erlang C comparison and the capacity sweep."""
function queues_section(bundle::AbstractDict)
    body = ""
    theo = get(bundle, :theory, nothing)
    obs = get(bundle, :observed, nothing)
    if theo isa AbstractDict && obs isa AbstractDict
        rows = SymDict[]
        for (key, label) in ((:rho, :utilisation), (:Lq, :queue_length), (:Wq, :wait),
            (:W, :sojourn), (:L, :in_system))
            haskey(theo, key) || continue
            push!(rows, SymDict(:quantity => label, :theory => theo[key],
                :simulation => get(obs, label, NaN),
                :relative_error => haskey(obs, label) ?
                    relative_error(obs[label], theo[key]) : NaN))
        end
        body *= string("<h3>Against Erlang C</h3>",
            table_html(rows, [:quantity, :theory, :simulation, :relative_error];
                caption = :mmc_theory))
    end
    if haskey(bundle, :sweep)
        sw = bundle[:sweep]
        body *= string("<h3>Widening the bottleneck</h3>",
            figure_html(get(figures_of(bundle), :sweep, nothing)),
            table_html(get_rows(sw), [:value, :throughput_mean, :wait_mean,
                    :utilisation_mean, :cycle_time_mean]; caption = sw[:param]),
            paragraph_html(string("The best ", code_string(sw[:param]), " by ",
                code_string(sw[:objective]), " is ", sw[:best_value], " (mean ",
                fmt_number(sw[:best_ci][:mean]), " ± ",
                fmt_number(sw[:best_ci][:half_width]), ").")))
    end
    cmp = get(bundle, :comparison, nothing)
    cmp isa SymDict && (body *= comparison_body(cmp, figures_of(bundle)))
    return section_html(:queues, "Queues and capacity", body;
        lead = "The first thing to check in a queueing model is that it agrees with " *
               "Erlang, and the second is what happens when the load moves.")
end

"""The rows of a sweep record, as a table body."""
get_rows(sw::AbstractDict) = get(sw, :rows, SymDict[])

"""One row per model: the headline metrics of every model of the study."""
function models_section(bundle::AbstractDict)
    models = get(bundle, :models, SymDict())
    isempty(models) && return ""
    rows = SymDict[]
    for (name, res) in models
        res isa ExperimentResult || continue
        row = SymDict()
        row[:model] = name
        row[:entity] = model_entity(name)
        row[:completed] = metric_value(res, :completed)
        row[:throughput] = metric_value(res, :throughput)
        row[:cycle_time] = metric_value(res, :cycle_time_mean)
        row[:wait] = metric_value(res, :wait_mean)
        row[:utilisation] = metric_value(res, :utilisation)
        row[:availability] = metric_value(res, :availability)
        row[:rel_hw_pct] = 100 * num(get(metric_ci(res, :throughput) === nothing ?
            SymDict(:relative_half_width => NaN) : metric_ci(res, :throughput),
            :relative_half_width, NaN))
        push!(rows, row)
    end
    validation = get(bundle, :validation, SymDict())
    verdicts = [get(validation, name, SymDict()) for name in keys(models)]
    body = table_html(rows, [:model, :entity, :completed, :throughput, :cycle_time, :wait,
        :utilisation, :availability]; caption = :models)
    vrows = SymDict[]
    for (i, name) in enumerate(keys(models))
        i > length(verdicts) && break
        v = verdicts[i]
        isempty(v) && continue
        push!(vrows, SymDict(:model => name, :check => get(v, :system, :unknown),
            :verdict => get(v, :verdict, :not_applicable),
            :worst_relative_error => get(v, :worst_relative_error, NaN),
            :checks => get(v, :n_comparisons, 0)))
    end
    isempty(vrows) || (body *= string("<h3>Does every model make sense?</h3>",
        table_html(vrows, [:model, :check, :worst_relative_error, :checks, :verdict];
            caption = :validation)))
    return section_html(:models, "The models", body;
        lead = "Five models, one engine: a service pool, a transfer line, a job shop, an " *
               "inventory position and a contact centre.")
end

"""The calibration section: the observations, the fits and the uncertainty."""
function calibration_section(bundle::AbstractDict)
    cal = get(bundle, :calibration, nothing)
    cal isa AbstractDict || return ""
    body = ""
    history = get(bundle, :history, nothing)
    if history isa PlantHistory
        rows = summarize_history(history)
        body *= string("<h3>The observations</h3>",
            table_html(rows, [:series, :n, :mean, :sd, :cv, :min, :p50, :p95, :max, :lag1];
                caption = :plant_history),
            kv_html(history.meta; keys = [:days, :base_rate, :service_mean, :failure_mtbf,
                :drift, :maintenance_day, :service_improvement, :seed]))
    end
    fits = SymDict[]
    for (key, fit) in cal
        fit isa AbstractDict || continue
        haskey(fit, :kind) || continue
        push!(fits, SymDict(:series => key, :family => fit[:kind], :mean => fit[:mean],
            :sd => fit[:sd], :cv => fit[:cv], :n => fit[:n], :sample_mean => fit[:sample_mean],
            :ks_stat => fit[:ks_stat], :ks_p => fit[:ks_p],
            :verdict => fit[:fits] ? :validated : :failed))
    end
    isempty(fits) || (body *= string("<h3>Maximum-likelihood fits</h3>",
        table_html(fits, [:series, :family, :mean, :sample_mean, :cv, :n, :ks_stat, :ks_p,
                :verdict]; caption = :fits),
        figure_html(get(figures_of(bundle), :calibration, nothing))))
    params = get(cal, :parameters, SymDict())
    isempty(params) || (body *= string("<h3>What the data implies for the model</h3>",
        kv_html(params; keys = [:arrival_rate, :service_rate, :mtbf, :mttr, :availability,
            :demand_mean])))
    return section_html(:calibration, "Calibration", body;
        lead = "The model parameters come from measurements, and every fit is tested against " *
               "the observations it claims to describe.")
end

"""The experiments section: warmup, replications, the comparison and the factorial design."""
function experiments_section(bundle::AbstractDict)
    body = ""
    if haskey(bundle, :warmup)
        wu = bundle[:warmup]
        horizon = Float64(get(get(bundle, :config, SymDict()), :horizon, 0.0))
        late = horizon > 0 && Float64(get(wu, :warmup, 0.0)) > 0.5 * horizon
        caveat = late ?
                 string(" That is most of the horizon: for this series the diagnostic could " *
                        "not find a plateau -- the curve moves by ", fmt_number(wu[:band]),
                        " around ", fmt_number(wu[:plateau]), " all the way to the end -- so ",
                        "the number below is a design decision, not a measurement: more " *
                        "replications or a longer window would settle it.") : ""
        body *= string("<h3>How long the transient lasts</h3>",
            paragraph_html(string("Welch's procedure on the ", code_string(wu[:series]),
                " series over ", wu[:replications], " replications suggests discarding the " *
                "first ", fmt_number(wu[:warmup]), " time units (plateau ",
                fmt_number(wu[:plateau]), " ± ", fmt_number(wu[:band]), ").", caveat)),
            figure_html(get(figures_of(bundle), :warmup, nothing)))
    end
    if haskey(bundle, :batch_means)
        bm = bundle[:batch_means]
        body *= string("<h3>One long run, honestly</h3>",
            table_html([bm], [:n, :mean, :half_width, :lo, :hi, :batches, :lag1, :adequate];
                caption = :batch_means))
    end
    exp = get(bundle, :experiment, nothing)
    exp isa ExperimentResult && (body *= string("<h3>The replications</h3>",
        metrics_table_html(exp; time_unit = model_time_unit(bundle_model(bundle))),
        figure_html(get(figures_of(bundle), :convergence, nothing))))
    cmp = get(bundle, :comparison, nothing)
    cmp isa SymDict && (body *= comparison_body(cmp, figures_of(bundle)))
    if haskey(bundle, :factorial)
        fd = bundle[:factorial]
        body *= string("<h3>Which knob matters?</h3>",
            table_html(get(fd, :effects, SymDict[]),
                [:term, :metric, :effect, :half_width, :lo, :hi, :verdict];
                caption = :factorial),
            figure_html(get(figures_of(bundle), :factorial, nothing)))
    end
    isempty(body) && return ""
    return section_html(:experiments, "Experiments", body;
        lead = "Replications, a detected warmup, batch means for a single run, paired " *
               "comparisons and a factorial design -- all with common random numbers.")
end

"""The online section: what the feed said and what the reevaluation decided."""
function online_section(bundle::AbstractDict)
    rec = get(bundle, :online, nothing)
    rec isa AbstractDict || return ""
    source = get(rec, :source, :generated)
    status = get(rec, :status, :offline)
    fresh = get(rec, :freshness, :unknown)
    verdict = get(rec, :verdict, :keep)
    body = callout_html(string("Source ", badge(code_string(source), verdict_class(source)),
        " &nbsp; status ", badge(code_string(status), verdict_class(status)),
        " &nbsp; freshness ", badge(code_string(fresh), verdict_class(fresh)),
        " &nbsp; verdict ", badge(code_string(verdict), verdict_class(verdict)),
        " (", code_string(get(rec, :reason, :unknown)), ")"), verdict_class(verdict))
    body *= string("<h3>The feed</h3>",
        kv_html(get(rec, :feed, SymDict());
            keys = [:url, :policy, :status, :source, :fetched_at, :age_days, :freshness,
                :attempts, :error, :fallback]))
    obs = get(rec, :observations, SymDict())
    if !isempty(obs)
        body *= string("<h3>What arrived</h3>",
            table_html([SymDict(:series => k, :observations => v) for (k, v) in obs
                        if v isa Real], [:series, :observations];
                caption = :feed_observations))
    end
    cmp = get(rec, :comparisons, SymDict[])
    isempty(cmp) || (body *= string("<h3>Offline against online</h3>",
        table_html(cmp, [:parameter, :offline, :online, :relative_change, :beyond_threshold];
            caption = :reevaluation)))
    ks = get(rec, :ks, SymDict())
    if !isempty(ks)
        body *= string("<h3>Are the two samples the same process?</h3>",
            table_html([SymDict(:series => k, :ks_stat => v[:stat], :ks_p => v[:p],
                    :n_offline => v[:n_offline], :n_online => v[:n_online],
                    :same_process => v[:same_process] ? :yes : :no) for (k, v) in ks],
                [:series, :ks_stat, :ks_p, :n_offline, :n_online, :same_process];
                caption = :two_sample_ks))
    end
    log = get(bundle, :reevaluation_log, nothing)
    if log isa AbstractVector && !isempty(log)
        body *= string("<h3>The reevaluation log</h3>",
            table_html([feed_row(r) for r in log],
                [:at, :source, :status, :freshness, :age_days, :observations, :worst_change,
                    :verdict, :reason]; caption = :log))
    end
    body *= paragraph_html("The model always answers from local data first; the feed only " *
                           "ever improves the picture, so nothing here fails when the " *
                           "network is down.")
    return section_html(:online, "Offline and online", body;
        lead = "The same observations, refreshed periodically, with the decision they " *
               "justify written down.")
end

"""The reports section: the manifest of everything the pipeline produced."""
function reports_section(bundle::AbstractDict)
    manifest = get(bundle, :manifest, SymDict())
    artifacts = get(bundle, :artifacts, SymDict())
    body = ""
    isempty(manifest) || (body *= string("<h3>Manifest</h3>", kv_html(manifest)))
    for (kind, list) in artifacts
        list isa AbstractVector || continue
        isempty(list) && continue
        body *= string("<h3>", html_escape(title_string(kind)), "</h3>",
            table_html([SymDict(:file => basename(String(p)),
                                :directory => dirname(String(p))) for p in list],
                [:file, :directory]; caption = kind))
    end
    seed = get(get(bundle, :config, SymDict()), :seed, 20260101)
    body *= paragraph_html(string("Reproduce everything with one command and one seed: ",
        "julia --project=. scripts/run_study.jl --seed=", seed, "."))
    return section_html(:reports, "Artefacts", body;
        lead = "Every number, figure and PDF in this repository is regenerated by one " *
               "command from one seed.")
end

"""The section of a bundle named by `key` (throws for an unknown key)."""
function section_of(bundle::AbstractDict, key::Symbol)
    k = Sym(key)
    k === :overview && return overview_section(bundle)
    k === :engine && return engine_section(bundle)
    k === :queues && return queues_section(bundle)
    k === :models && return models_section(bundle)
    k === :experiments && return experiments_section(bundle)
    k === :calibration && return calibration_section(bundle)
    k === :online && return online_section(bundle)
    k === :reports && return reports_section(bundle)
    throw(ArgumentError("unknown section :$k; known sections: " *
                        join(code_string.(ANALYSIS_KEYS), ", ")))
end

"""
    generation_stamp(at = Dates.now()) -> String

The date and time a printout was made, in a header's own words: `2026-09-24 07:21:20`.

A printed document carries the moment it was printed; everything else in it is a
function of the seed. A caller that needs byte-identical printouts pins the stamp
instead: `cfg[:generated] = "2026-09-24 07:21:20"`, or `cfg[:generated] = ""` to omit it.
"""
function generation_stamp(at::DateTime = Dates.now())
    return Dates.format(at, dateformat"yyyy-mm-dd HH:MM:SS")
end

"""The header record of a report: what it is, when it was made and from which seed."""
function report_meta(bundle::AbstractDict)
    cfg = get(bundle, :config, SymDict())
    d = SymDict()
    d[:title] = get(cfg, :title, :DiscreteEventSimulation)
    d[:model] = get(bundle, :model, :none)
    d[:seed] = get(cfg, :seed, 20260101)
    d[:replications] = get(cfg, :replications, 0)
    d[:horizon] = get(cfg, :horizon, 0.0)
    d[:warmup] = get(cfg, :warmup, 0.0)
    d[:generated] = get(cfg, :generated, generation_stamp())
    d[:engine] = :DiscreteSim
    d[:sections] = length(get(bundle, :sections, ANALYSIS_KEYS))
    return d
end

"""The table of contents of a list of `id => section` pairs."""
function toc_html(sections::AbstractVector{<:Pair})
    items = String[]
    for (id, _) in sections
        k = Sym(id)
        push!(items, string("<a href=\"#", code_string(k), "\">", title_string(k), "</a>"))
    end
    return string("<h2 id=\"contents\">Contents</h2><div class=\"toc\">",
        join(items, " &nbsp;|&nbsp; "), "</div>")
end

"""
    document_html(title, subtitle, sections; meta, toc, footer) -> String

Assemble a complete, self-contained HTML document from `id => section` pairs: the
stylesheet is inlined, every figure is already a data URI, and the table of
contents links to the section anchors.
"""
function document_html(title, subtitle, sections::AbstractVector{<:Pair};
    meta = nothing, toc::Bool = true, footer = nothing)
    parts = String[]
    if toc && length(sections) > 1
        push!(parts, toc_html(sections))
    end
    append!(parts, [last(s) for s in sections])
    meta_html = meta === nothing ? "" :
                string("<div class=\"meta\">", join([string(title_string(k), ": ",
                        fmt_number(v)) for (k, v) in meta], " &nbsp;|&nbsp; "), "</div>")
    foot = footer === nothing ? "" :
           string("<footer>", html_escape(footer), "</footer>")
    return string("<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">",
        "<title>", html_escape(title), "</title><style>", PRINTOUT_CSS, "</style></head>",
        "<body><div class=\"page\"><h1>", html_escape(title), "</h1>",
        "<div class=\"subtitle\">", html_escape(subtitle), "</div>", meta_html,
        join(parts), foot, "</div></body></html>")
end

"""The subtitle of a study, from its meta record."""
function report_subtitle(bundle::AbstractDict)
    meta = report_meta(bundle)
    return string("Discrete-event simulation in Julia: ", code_string(meta[:model]),
        " (", meta[:replications], " replications of ", fmt_number(meta[:horizon]),
        " minutes, seed ", meta[:seed], ")")
end

"""
    report_html(bundle; keys = ANALYSIS_KEYS, title) -> String

The whole study as one printout: every requested section, with the table of
contents, the header meta record and the footer.
"""
function report_html(bundle::AbstractDict; keys = ANALYSIS_KEYS,
    title = get(get(bundle, :config, SymDict()), :title, :DiscreteEventSimulation))
    sections = Pair{Symbol,String}[]
    for k in keys
        html = section_of(bundle, k)
        isempty(html) && continue
        push!(sections, Sym(k) => html)
    end
    meta = report_meta(bundle)
    return document_html(title_string(title), report_subtitle(bundle), sections;
        meta = meta,
        footer = string("Generated by DiscreteSim.jl from seed ",
            get(get(bundle, :config, SymDict()), :seed, 20260101),
            isempty(string(meta[:generated])) ? "" : string(" on ", meta[:generated]),
            "; every number is reproducible."))
end

"""
    preview_section(bundle, key) -> String

One section as a self-contained HTML fragment, ready for `HTML(...)` in a Pluto
cell: the print stylesheet travels with it, so what the notebook shows is what the
printer prints.
"""
function preview_section(bundle::AbstractDict, key::Symbol)
    return string("<style>", PRINTOUT_CSS, "</style><div class=\"page\">",
        section_of(bundle, key), "</div>")
end

"""One section as a standalone document (what the per-topic PDF prints)."""
function section_document(bundle::AbstractDict, key::Symbol)
    k = Sym(key)
    return document_html(title_string(k), report_subtitle(bundle),
        [k => section_of(bundle, k)]; meta = report_meta(bundle), toc = false,
        footer = string("DiscreteSim.jl, section ", code_string(k), ", seed ",
            get(get(bundle, :config, SymDict()), :seed, 20260101)))
end

## ---- printing -------------------------------------------------------------------

"""
    print_section_pdf(bundle, key; root, chrome, prefix, to_pdf) -> SymDict

Write one section as a printout and print it to PDF:
`reports/html/<prefix>_<key>.html` and `reports/pdf/<prefix>_<key>.pdf`. This is
what a notebook calls in its last cell, so the notebook is its own report and the
PDF is its printout -- the same HTML, printed.
"""
function print_section_pdf(bundle::AbstractDict, key::Symbol; root::AbstractString = pwd(),
    chrome = nothing, prefix::AbstractString = "notebook", to_pdf::Bool = true)
    html_dir = joinpath(root, "reports", "html")
    pdf_dir = joinpath(root, "reports", "pdf")
    html_path = joinpath(html_dir, string(prefix, "_", code_string(key), ".html"))
    pdf_path = joinpath(pdf_dir, string(prefix, "_", code_string(key), ".pdf"))
    write_printout(html_path, section_document(bundle, key))
    d = SymDict(:section => Sym(key), :html => html_path, :pdf => pdf_path,
        :html_bytes => filesize(html_path), :printed => false)
    if to_pdf && pdf_available(; explicit = chrome)
        html_to_pdf(html_path, pdf_path; chrome = chrome)
        d[:printed] = true
        d[:pdf_bytes] = filesize(pdf_path)
    end
    return d
end

"""
    print_report_pdf(bundle; root, chrome, name, keys) -> SymDict

Write the whole study as one printout and print it to PDF
(`reports/html/<name>.html`, `reports/pdf/<name>.pdf`).
"""
function print_report_pdf(bundle::AbstractDict; root::AbstractString = pwd(),
    chrome = nothing, name::AbstractString = "discrete_sim_report", keys = ANALYSIS_KEYS,
    to_pdf::Bool = true)
    html_dir = joinpath(root, "reports", "html")
    pdf_dir = joinpath(root, "reports", "pdf")
    html_path = joinpath(html_dir, string(name, ".html"))
    pdf_path = joinpath(pdf_dir, string(name, ".pdf"))
    write_printout(html_path, report_html(bundle; keys = keys))
    d = SymDict(:html => html_path, :pdf => pdf_path, :html_bytes => filesize(html_path),
        :printed => false)
    if to_pdf && pdf_available(; explicit = chrome)
        html_to_pdf(html_path, pdf_path; chrome = chrome)
        d[:printed] = true
        d[:pdf_bytes] = filesize(pdf_path)
    end
    return d
end

"""Print every section of a study as its own PDF (the report library)."""
function print_all_sections(bundle::AbstractDict; root::AbstractString = pwd(), chrome = nothing,
    keys = ANALYSIS_KEYS)
    out = SymDict()
    for k in keys
        isempty(section_of(bundle, k)) && continue
        out[k] = print_section_pdf(bundle, k; root = root, chrome = chrome)
    end
    return out
end