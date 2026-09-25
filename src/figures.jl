# =============================================================================
# figures.jl -- the charts that go into the report and the notebooks.
#
# Each function returns a `Plots.Plot`, and `nothing` when the data it would draw
# is not there, so a report can ask for every figure of a model and simply skip
# the ones that do not apply. `png_base64` and `data_uri` turn a plot into the data
# URI the HTML printout embeds, which is what makes the notebook and the PDF show
# exactly the same picture.
# =============================================================================

"""Default geometry of a report figure (width, height in pixels and resolution)."""
const FIGURE_SIZE = (; width = 1000, height = 320, dpi = 110)

"""Colour of each kind of series, used consistently in every figure."""
const FIGURE_COLOURS = (
    primary = "#1f5c8b",
    accent = "#c8442c",
    tertiary = "#6fbf73",
    highlight = "#e07b39",
    muted = "#78909c",
    band = "#bcd4e6",
)

"""Standard look of every report figure."""
function figure_theme(p::Plots.Plot)
    return Plots.plot(p;
        size = (FIGURE_SIZE.width, FIGURE_SIZE.height),
        dpi = FIGURE_SIZE.dpi,
        background_color = :white,
        background_color_inside = :white,
        foreground_color = "#333333",
        grid = true,
        gridalpha = 0.25,
        gridcolor = "#cccccc",
        legendfontsize = 9,
        tickfontsize = 9,
        guidefontsize = 10,
        titlefontsize = 11,
        left_margin = 6Plots.mm,
        right_margin = 3Plots.mm,
        top_margin = 3Plots.mm,
        bottom_margin = 4Plots.mm)
end

"""Encode a plot as base 64 PNG (what the HTML printout embeds)."""
function png_base64(p::Plots.Plot)
    io = IOBuffer()
    Plots.png(p, io)
    return Base64.base64encode(String(take!(io)))
end

"""A plot as a data URI, ready for an `img` tag."""
data_uri(p::Plots.Plot) = string("data:image/png;base64,", png_base64(p))

"""A figure bundle: the plot, the caption and the data URI of one chart."""
figure_of(p::Plots.Plot, caption) = (plot = p, caption = Sym(caption), uri = data_uri(p))

"""Queueing work in progress of a run over time (from the `:wip` recorder)."""
function fig_wip(run::Sim; label = :WIP)
    st = get(run.stats, :wip, nothing)
    st isa Recorder || return nothing
    isempty(st.times) && return nothing
    p = Plots.plot(st.times, st.values;
        label = string(title_string(label), " (mean ", round(mean(st.values), digits = 2),
            ")"),
        color = FIGURE_COLOURS.primary, linewidth = 1.2,
        xlabel = string("time (", code_string(time_unit(run)), ")"),
        ylabel = title_string(label), title = "Work in progress over time",
        legend = :topright)
    return figure_theme(p)
end

"""Waiting-time distribution of a run against the exponential it suggests."""
function fig_wait_hist(run::Sim; bins::Integer = 30)
    st = get(run.stats, :wait, nothing)
    st isa Tally || return nothing
    isempty(st.history) && return nothing
    x = st.history
    p = Plots.histogram(x; bins = Int(bins), normalize = :pdf, alpha = 0.55,
        color = FIGURE_COLOURS.band, label = "observed", xlabel = "waiting time",
        ylabel = "density",
        title = "Waiting time (mean " * string(round(mean(st), digits = 3)) * ")")
    lambda = 1 / max(mean(st), 1e-9)
    xs = range(0, quantile(x, 0.995); length = 200)
    p = Plots.plot!(p, xs, lambda .* exp.(-lambda .* xs);
        label = "exponential fit", color = FIGURE_COLOURS.accent, linewidth = 2.0)
    return figure_theme(p)
end

"""Utilisation and availability of every resource of a run."""
function fig_utilisation(run::Sim)
    rs = Resource[r for (_, r) in run.resources if r isa Resource]
    isempty(rs) && return nothing
    names = [code_string(r.name) for r in rs]
    p = Plots.bar(names, [utilisation(r) for r in rs]; label = "utilisation",
        color = FIGURE_COLOURS.primary, ylim = (0, 1.05), ylabel = "fraction",
        title = "Resource utilisation and availability", legend = :topright)
    p = Plots.plot!(p, names, [availability(r) for r in rs];
        seriestype = :scatter, markersize = 5, markerstrokewidth = 0,
        color = FIGURE_COLOURS.accent, label = "availability")
    return figure_theme(p)
end

"""Completions per time bucket: the throughput curve of a run."""
function fig_throughput(run::Sim; dt::Real = 0.0)
    trace = run.trace
    n_of(trace) == 0 && return nothing
    span = max(run.now, 1e-9)
    step = dt > 0 ? Float64(dt) : max(span / 40, 1e-9)
    times, counts = completions(trace, :ship, step)
    isempty(times) && return nothing
    p = Plots.plot(times, counts; label = "completions per bucket",
        color = FIGURE_COLOURS.tertiary, linewidth = 1.4, fill = (0, 0.15),
        xlabel = string("time (", code_string(time_unit(run)), ")"),
        ylabel = "items per bucket", title = "Throughput over time", legend = :topright)
    return figure_theme(p)
end

"""Scenario comparison: one bar per scenario with its confidence interval."""
function fig_scenarios(cmp::SymDict; metric::Symbol = :throughput, keys = nothing,
    time_unit::Symbol = :minutes)
    order = cmp[:order]
    metrics = keys === nothing ? [metric, :cycle_time_mean, :utilisation] : collect(keys)
    panels = Plots.Plot[]
    for m in metrics
        ci = [metric_ci(cmp[:results][nm], m) for nm in order]
        any(x -> x === nothing, ci) && continue
        means = [c[:mean] for c in ci]
        widths = [c[:half_width] for c in ci]
        p = Plots.bar([code_string(nm) for nm in order], means; yerror = widths,
            label = string(title_string(m)), color = FIGURE_COLOURS.primary,
            ylabel = code_string(metric_unit(m; time_unit = time_unit)),
            title = string(title_string(m), " by scenario"), legend = false)
        push!(panels, figure_theme(p))
    end
    isempty(panels) && return nothing
    return Plots.plot(panels...; layout = (1, length(panels)))
end

"""One parameter walked: the objective with its interval and the best value marked."""
function fig_sweep(sw::SymDict; time_unit::Symbol = :minutes)
    values = Float64.(sw[:values])
    ci = [metric_ci(res, sw[:objective]) for res in sw[:results]]
    any(x -> x === nothing, ci) && return nothing
    means = [c[:mean] for c in ci]
    widths = [c[:half_width] for c in ci]
    p = Plots.plot(values, means; ribbon = widths, fillalpha = 0.25, linewidth = 2.0,
        color = FIGURE_COLOURS.primary, label = "mean and 95% CI",
        xlabel = string(title_string(sw[:param]), " (", code_string(sw[:param]), ")"),
        ylabel = code_string(metric_unit(sw[:objective]; time_unit = time_unit)),
        title = string(title_string(sw[:objective]), " versus ", title_string(sw[:param])),
        legend = :topright, marker = :circle, markersize = 4)
    p = Plots.plot!(p, [sw[:best_value]], [means[sw[:best_index]]]; seriestype = :scatter,
        markersize = 7, color = FIGURE_COLOURS.accent,
        label = string("best: ", sw[:best_value]))
    return figure_theme(p)
end

"""Welch's warmup analysis: the averaged response, the moving average and the band."""
function fig_warmup(wu::SymDict)
    haskey(wu, :smoothed) || return nothing
    all(isnan, wu[:smoothed]) && return nothing
    p = Plots.plot(wu[:times], wu[:averaged]; label = "mean response",
        color = FIGURE_COLOURS.band, linewidth = 1.0,
        xlabel = "time (minutes)", ylabel = title_string(wu[:series]),
        title = "Warmup (Welch): the smoothed response settles at " *
                string(round(wu[:plateau], digits = 2)))
    p = Plots.plot!(p, wu[:times], wu[:smoothed]; label = "moving average",
        color = FIGURE_COLOURS.primary, linewidth = 2.0)
    p = Plots.plot!(p, wu[:times], fill(wu[:plateau], length(wu[:times]));
        label = "plateau", color = FIGURE_COLOURS.muted, linestyle = :dash)
    w = get(wu, :warmup, 0.0)
    if isfinite(w)
        p = Plots.plot!(p, wu[:times], fill(max(wu[:plateau] - wu[:band], 0.0),
            length(wu[:times])); label = "", color = FIGURE_COLOURS.muted, alpha = 0.0)
    end
    p = Plots.vline!(p, [w]; label = string("suggested warmup ", round(w, digits = 1)),
        color = FIGURE_COLOURS.accent, linestyle = :dot, linewidth = 1.5)
    return figure_theme(p)
end

"""Simulation against theory: the relative error of every cross-check."""
function fig_validation(v::SymDict)
    rows = get(v, :comparisons, SymDict[])
    isempty(rows) && return nothing
    names = [string(code_string(r[:observed_key]), " / ", code_string(r[:theory_key]))
             for r in rows]
    errors = [100 * r[:relative_error] for r in rows]
    colours = [r[:within_tolerance] ? FIGURE_COLOURS.tertiary : FIGURE_COLOURS.accent
               for r in rows]
    p = Plots.bar(names, errors; label = "", color = colours, ylabel = "relative error (%)",
        title = string("Simulation against theory (", code_string(v[:verdict]), "), ",
            "tolerance ", round(100 * v[:tolerance], digits = 0), "%"),
        legend = false, yrotation = 0)
    p = Plots.hline!(p, [100 * v[:tolerance]]; label = "tolerance",
        color = FIGURE_COLOURS.muted, linestyle = :dash)
    return figure_theme(p)
end

"""The observations of one series with the density of the family fitted to them."""
function fig_calibration(x::AbstractVector{<:Real}, fit_record::AbstractDict;
    series = :service, bins::Integer = 40)
    isempty(x) && return nothing
    p = Plots.histogram(x; bins = Int(bins), normalize = :pdf, alpha = 0.5,
        color = FIGURE_COLOURS.band, label = "observations", xlabel = code_string(series),
        ylabel = "density",
        title = string(title_string(series), ": ", code_string(fit_record[:kind]),
            " fit (KS p = ", round(fit_record[:ks_p], digits = 3), ")"))
    d = dist(fit_record)
    xs = range(quantile(x, 0.001), quantile(x, 0.999); length = 250)
    p = Plots.plot!(p, xs, pdf.(Ref(d), xs); label = "fitted density",
        color = FIGURE_COLOURS.accent, linewidth = 2.0)
    return figure_theme(p)
end

"""The effect of every factor of a factorial design, as a tornado plot."""
function fig_factorial(fd::SymDict)
    rows = get(fd, :effects, SymDict[])
    isempty(rows) && return nothing
    names = [code_string(r[:term]) for r in rows]
    effects = [r[:effect] for r in rows]
    widths = [r[:half_width] for r in rows]
    colours = [r[:verdict] === :helps ? FIGURE_COLOURS.tertiary :
               r[:verdict] === :hurts ? FIGURE_COLOURS.accent : FIGURE_COLOURS.muted
               for r in rows]
    p = Plots.bar(names, effects; yerror = widths, label = "", color = colours,
        ylabel = string("effect on ", code_string(fd[:objective])),
        title = string("Factorial effects on ", title_string(fd[:objective])),
        legend = false)
    p = Plots.hline!(p, [0.0]; label = "", color = "#888888", linewidth = 0.8)
    return figure_theme(p)
end

"""Convergence of one metric over the replications, with its interval."""
function fig_convergence(res::ExperimentResult; metric::Symbol = :throughput,
    time_unit::Symbol = :minutes)
    values = metric_series(res, metric)
    length(values) < 3 && return nothing
    ci = metric_ci(res, metric)
    cum = cumulative_mean(values)
    p = Plots.plot(1:length(cum), cum; label = "cumulative mean",
        color = FIGURE_COLOURS.primary, linewidth = 1.6, xlabel = "replication",
        ylabel = code_string(metric_unit(metric; time_unit = time_unit)),
        title = string(title_string(metric), " converges to ", round(ci[:mean], digits = 3),
            " ± ", round(ci[:half_width], digits = 3)))
    p = Plots.hline!(p, [ci[:mean]]; label = "mean", color = FIGURE_COLOURS.muted,
        linestyle = :dash)
    p = Plots.hline!(p, [ci[:lo], ci[:hi]]; label = "95% interval",
        color = FIGURE_COLOURS.band, linestyle = :dot)
    return figure_theme(p)
end

"""Resource occupancy of a run: the Gantt chart the trace makes possible."""
function fig_gantt(run::Sim; resource::Symbol = :none, limit::Integer = 60)
    n_of(run.trace) == 0 && return nothing
    name = Sym(resource) === :none ? _busiest_resource(run) : Sym(resource)
    name === :none && return nothing
    segments = occupation_segments(run.trace, name; limit = Int(limit))
    isempty(segments) && return nothing
    p = Plots.plot(; xlabel = string("time (", code_string(time_unit(run)), ")"),
        ylabel = code_string(name),
        title = string("Occupancy of ", code_string(name), " (first ", length(segments),
            " services)"), legend = false, yticks = [])
    for (i, (t0, t1, entity)) in enumerate(segments)
        Plots.plot!(p, [t0, t1], [i, i]; color = FIGURE_COLOURS.primary, linewidth = 4,
            label = "")
        Plots.annotate!(p, t0, i, Plots.text(code_string(entity), 5, :left, "#333333"))
    end
    return figure_theme(p)
end

"""Name of the resource a run used most (for the figures that need one)."""
function _busiest_resource(run::Sim)
    rs = Resource[r for (_, r) in run.resources if r isa Resource]
    isempty(rs) && return :none
    return rs[argmax([mean_queue_length(r) for r in rs])].name
end

"""
    figure_set(bundle; keys = nothing) -> SymDict

Every figure a report asks for, as a `SymDict` of `figure_of(...)` bundles. A
figure whose data is missing is skipped, so the same call works for every model:
`bundle` may carry `:run`, `:comparison`, `:sweep`, `:warmup`, `:validation`,
`:factorial`, `:calibration` (with `:history`) and `:experiment`.
"""
function figure_set(bundle::AbstractDict; keys = nothing)
    figs = SymDict()
    run = get(bundle, :run, nothing)
    unit = model_time_unit(bundle_model(bundle))
    if run isa Sim
        figs[:wip] = _maybe(fig_wip(run), :WorkInProgress)
        figs[:wait] = _maybe(fig_wait_hist(run), :WaitingTime)
        figs[:utilisation] = _maybe(fig_utilisation(run), :Utilisation)
        figs[:throughput] = _maybe(fig_throughput(run), :Throughput)
        figs[:gantt] = _maybe(fig_gantt(run), :Occupancy)
    end
    haskey(bundle, :comparison) &&
        (figs[:scenarios] = _maybe(fig_scenarios(bundle[:comparison]; time_unit = unit),
            :Scenarios))
    haskey(bundle, :sweep) &&
        (figs[:sweep] = _maybe(fig_sweep(bundle[:sweep]; time_unit = unit), :Sweep))
    haskey(bundle, :warmup) && (figs[:warmup] = _maybe(fig_warmup(bundle[:warmup]), :Warmup))
    haskey(bundle, :validation) &&
        (figs[:validation] = _maybe(fig_validation(bundle[:validation]), :Validation))
    haskey(bundle, :factorial) &&
        (figs[:factorial] = _maybe(fig_factorial(bundle[:factorial]), :Factorial))
    haskey(bundle, :calibration) && haskey(bundle, :history) &&
        (figs[:calibration] = _maybe(
            fig_calibration(history_series(bundle[:history], :service),
                bundle[:calibration][:service]; series = :service), :Calibration))
    haskey(bundle, :experiment) &&
        (figs[:convergence] = _maybe(fig_convergence(bundle[:experiment]; time_unit = unit),
            :Convergence))
    keys === nothing && return figs
    return subset(figs, keys)
end

"""Wrap a plot in a figure bundle, unless there is no plot."""
_maybe(p, caption) = p === nothing ? nothing : figure_of(p, Sym(caption))

"""The plots of a figure set, in insertion order (for a quick notebook display)."""
figure_plots(figs::AbstractDict) = Plots.Plot[f[:plot] for (_, f) in figs if f !== nothing]