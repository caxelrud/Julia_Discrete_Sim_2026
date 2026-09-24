# =============================================================================
# pipeline.jl -- one command that produces every artefact of the study.
#
# The pipeline is deliberately split in two halves:
#
# * `run_study` does the expensive work once -- generate the plant history,
#   calibrate the models, run every experiment, print every PDF -- and writes
#   everything it produced to `data/` (JSON and CSV), `reports/figures/` (PNG),
#   `reports/html/` and `reports/pdf/`.
# * `load_study` reads those artefacts back in a fraction of a second, which is
#   what a Pluto notebook uses: opening a notebook shows the *same* numbers and
#   the *same* figures as the report, without re-running a study every time a cell
#   is evaluated.
#
# Both halves see the same symbol-keyed bundle, so `overview_section`,
# `print_section_pdf` and the figures do not care which one produced it.
# =============================================================================

"""
    PipelineConfig

Everything the study needs, keyed by `Symbol` so it can also be passed as a plain
dictionary: `:root`, `:seed`, `:days`, `:replications`, `:horizon`, `:warmup`,
`:models`, `:featured`, `:objective`, `:sweep_values`, `:export_data`,
`:render_pdf`, `:chrome`, `:parallel`, `:figures`, `:title` and the two data
records `:online` ([`OnlineConfig`](@ref)) and `:plan` ([`ReevaluationPlan`](@ref)).
"""
Base.@kwdef mutable struct PipelineConfig
    root::String = pwd()
    title::Symbol = :DiscreteEventSimulation
    seed::Int = 20260101
    days::Float64 = 90.0
    replications::Int = 12
    horizon::Float64 = 6000.0
    warmup::Float64 = 600.0
    models::Vector{Symbol} = collect(MODELS)
    featured::Symbol = :machine_shop
    objective::Symbol = :cycle_time_mean
    sweep_param::Symbol = :arrival_rate
    sweep_values::Vector{Float64} = Float64[0.055, 0.075, 0.095, 0.11, 0.125]
    comparisons::Vector{Symbol} = Symbol[]
    warmup_replications::Int = 4
    data_dir::String = "data"
    html_dir::String = joinpath("reports", "html")
    pdf_dir::String = joinpath("reports", "pdf")
    figure_dir::String = joinpath("reports", "figures")
    export_data::Bool = true
    render_pdf::Bool = true
    print_sections::Bool = true
    chrome::Union{Nothing,String} = nothing
    parallel::Bool = false
    figures::Bool = true
    online::OnlineConfig = OnlineConfig()
    plan::ReevaluationPlan = ReevaluationPlan(7, :days)
end

PipelineConfig(d::AbstractDict) = begin
    known = Set{Symbol}(fieldnames(PipelineConfig))
    kwargs = Pair{Symbol,Any}[]
    for (k, v) in d
        key = Sym(k)
        key in known || continue
        push!(kwargs, key => (key === :online && v isa AbstractDict ? OnlineConfig(v) :
                              key === :plan && v isa AbstractDict ? ReevaluationPlan(v) : v))
    end
    PipelineConfig(; kwargs...)
end

"""Absolute path of one of the directories of a study."""
function path_of(cfg::PipelineConfig, key::Symbol)
    k = Sym(key)
    k === :root && return cfg.root
    k === :data && return joinpath(cfg.root, cfg.data_dir)
    k === :html && return joinpath(cfg.root, cfg.html_dir)
    k === :pdf && return joinpath(cfg.root, cfg.pdf_dir)
    k === :figures && return joinpath(cfg.root, cfg.figure_dir)
    throw(ArgumentError("unknown output :$k of the pipeline"))
end

"""The experiment configuration of one model of the study."""
study_experiment(cfg::PipelineConfig; replications = cfg.replications,
    warmup = cfg.warmup, horizon = cfg.horizon) =
    ExperimentConfig(replications = Int(replications), horizon = Float64(horizon),
        warmup = Float64(warmup), seed = cfg.seed, parallel = cfg.parallel)

## ---- the heavy half: compute everything ------------------------------------------

"""
    analysis_bundle(cfg::PipelineConfig = PipelineConfig()) -> SymDict

Run the whole study and return the symbol-keyed bundle every section and figure
reads: `:config`, `:history`, `:calibration`, `:models`, `:experiment`,
`:validation`, `:comparison`, `:sweep`, `:warmup`, `:batch_means`, `:factorial`,
`:online`, `:reevaluation_log`, `:run`, `:theory`, `:observed`, `:figures` and
`:artifacts`.
"""
function analysis_bundle(cfg::PipelineConfig = PipelineConfig())
    root = cfg.root
    data_dir = path_of(cfg, :data)
    figure_dir = path_of(cfg, :figures)
    artifacts = SymDict(:data => String[], :figures => String[], :html => String[],
        :pdf => String[])

    @info "DiscreteSim study" root = root seed = cfg.seed days = cfg.days
    history = generate_history(; seed = cfg.seed, days = cfg.days)
    calibration = calibrate(history)

    ## ---- the data layer: the same observations, exported twice ------------------
    if cfg.export_data
        append!(artifacts[:data], write_history_csv(history, data_dir))
        push!(artifacts[:data], write_json_payload(joinpath(data_dir, "history.json"),
            SymDict(:counts => history.counts, :meta => history.meta,
                :summary => summarize_history(history))))
        push!(artifacts[:data], write_json_payload(joinpath(data_dir, "calibration.json"),
            calibration))
        push!(artifacts[:data],
            write_online_feed(history, joinpath(data_dir, "online_feed.json");
                window_days = cfg.days))
    end

    ## ---- the reevaluation round ---------------------------------------------------
    feed = fetch_online(cfg.online)
    reevaluation = reevaluate(calibration; history = history, cfg = cfg.online,
        model = cfg.featured, plan = cfg.plan,
        log_path = joinpath(data_dir, "reevaluation_log.json"))
    reevaluation_log_rows = reevaluation_log(joinpath(data_dir, "reevaluation_log.json"))

    ## ---- one experiment per model, plus its cross-check ---------------------------
    experiments = SymDict()
    validations = SymDict()
    samples = SymDict()
    for name in cfg.models
        params = model_params_from_calibration(calibration, name)
        config = study_experiment(cfg)
        experiments[name] = experiment(opts -> build_model(name, params, opts), config;
            name = name)
        run = run_replication(opts -> build_model(name, params, opts), config, 1)
        samples[name] = run
        validations[name] = validate_model(run, name, params)
    end
    featured = cfg.featured
    featured_params = model_params_from_calibration(calibration, featured)
    featured_config = study_experiment(cfg)
    featured_run = run_replication(opts -> build_model(featured, featured_params, opts),
        ExperimentConfig(replications = 1, horizon = cfg.horizon, warmup = cfg.warmup,
            seed = cfg.seed, trace = true), 1)

    ## ---- the comparison, the sweep, the warmup and the factorial design ----------
    scenario_names = isempty(cfg.comparisons) ? collect(model_scenarios(featured)) :
                     collect(cfg.comparisons)
    comparison = compare_scenarios(
        [s => (opts -> build_calibrated_scenario(calibration, featured, s, opts))
         for s in scenario_names], study_experiment(cfg);
        objective = cfg.objective, name = Symbol(featured, :_scenarios))

    sweep_result = sweep((v, opts) -> build_model(featured,
            model_params(featured_params, (cfg.sweep_param => v,)), opts), cfg.sweep_param,
        cfg.sweep_values, study_experiment(cfg; replications = max(4, cfg.replications ÷ 2));
        name = Symbol(:sweep, :_, cfg.sweep_param), objective = cfg.objective)

    warmup_result = warmup_analysis(
        opts -> build_model(featured, featured_params, opts),
        study_experiment(cfg; replications = cfg.warmup_replications);
        series = model_series(featured), window = 20)

    batch = batch_means(metric_series(experiments[featured], cfg.objective))

    factorial_result = factorial_design(
        (levels, opts) -> build_model(featured,
            model_params(featured_params,
                (cfg.sweep_param => Float64(levels[cfg.sweep_param]),
                 :arrival_rate => Float64(levels[:arrival_rate]))), opts),
        [cfg.sweep_param, :arrival_rate],
        Dict(cfg.sweep_param => (Float64(first(cfg.sweep_values)),
                Float64(last(cfg.sweep_values))),
            :arrival_rate => (Float64(featured_params[:arrival_rate]),
                Float64(1.2 * featured_params[:arrival_rate]))),
        study_experiment(cfg; replications = cfg.warmup_replications);
        objective = cfg.objective)

    ## ---- the theory comparison of the featured model -----------------------------
    theory_record = model_theory(featured, featured_params)
    observed = theory_record === nothing ? nothing :
               observed_summary(featured_run, model_resource(featured) in
                                keys(featured_run.resources) ? model_resource(featured) :
                                _busiest_resource(featured_run))

    ## ---- the bundle, without the figures yet -------------------------------------
    bundle = SymDict()
    bundle[:config] = config_record(cfg)
    bundle[:history] = history
    bundle[:calibration] = calibration
    bundle[:feed] = feed
    bundle[:online] = reevaluation
    bundle[:reevaluation_log] = reevaluation_log_rows
    bundle[:models] = experiments
    bundle[:experiment] = experiments[featured]
    bundle[:validation] = validations[featured]
    bundle[:validations] = validations
    bundle[:samples] = samples
    bundle[:run] = featured_run
    bundle[:model] = featured
    bundle[:params] = featured_params
    bundle[:theory] = theory_record
    bundle[:observed] = observed
    bundle[:comparison] = comparison
    bundle[:sweep] = sweep_result
    bundle[:warmup] = warmup_result
    bundle[:batch_means] = batch
    bundle[:factorial] = factorial_result
    bundle[:artifacts] = artifacts

    ## ---- the figures -------------------------------------------------------------
    if cfg.figures
        figs = figure_set(bundle)
        for (key, f) in figs
            f === nothing && continue
            path = joinpath(figure_dir, string(code_string(key), ".png"))
            mkpath(figure_dir)
            Plots.savefig(f[:plot], path)
            push!(artifacts[:figures], path)
            figs[key] = figure_from_png(path, f[:caption])
        end
        bundle[:figures] = figs
    else
        bundle[:figures] = SymDict()
    end

    ## ---- the artefacts of the printouts ------------------------------------------
    if cfg.export_data
        push!(artifacts[:data], write_json_payload(joinpath(data_dir, "analysis.json"),
            study_json(bundle)))
    end
    if cfg.render_pdf
        full = print_report_pdf(bundle; root = cfg.root, chrome = cfg.chrome,
            to_pdf = true)
        push!(artifacts[:html], full[:html])
        full[:printed] && push!(artifacts[:pdf], full[:pdf])
        if cfg.print_sections
            for (key, out) in print_all_sections(bundle; root = cfg.root, chrome = cfg.chrome)
                push!(artifacts[:html], out[:html])
                out[:printed] && push!(artifacts[:pdf], out[:pdf])
            end
        end
    end

    bundle[:manifest] = manifest_of(cfg, bundle, artifacts)
    return bundle
end

"""The `:config` record of a study (what the report and the JSON show)."""
function config_record(cfg::PipelineConfig)
    d = SymDict()
    d[:title] = cfg.title
    d[:root] = cfg.root
    d[:seed] = cfg.seed
    d[:days] = cfg.days
    d[:replications] = cfg.replications
    d[:horizon] = cfg.horizon
    d[:warmup] = cfg.warmup
    d[:models] = cfg.models
    d[:featured] = cfg.featured
    d[:objective] = cfg.objective
    d[:sweep_param] = cfg.sweep_param
    d[:sweep_values] = cfg.sweep_values
    d[:online_policy] = cfg.online.policy
    d[:online_url] = cfg.online.url
    d[:reevaluation_plan] = describe_plan(cfg.plan)
    d[:parallel] = cfg.parallel
    return d
end

"""A figure bundle built from a PNG file on disk (what `load_study` sees)."""
function figure_from_png(path::AbstractString, caption = :figure)
    return (plot = nothing, caption = Sym(caption), uri = png_data_uri(path), path = path)
end

"""Data URI of a PNG file (`""` when it is not there)."""
function png_data_uri(path::AbstractString)
    isfile(path) || return ""
    return string("data:image/png;base64,", Base64.base64encode(read(path)))
end

## ---- the light half: JSON in, bundle out -----------------------------------------

"""One experiment as a JSON record (enough to rebuild it, and to print it)."""
function result_json(res::ExperimentResult)
    d = SymDict()
    d[:name] = res.name
    d[:kind] = res.kind
    d[:config] = SymDict((f => getfield(res.config, f)
                          for f in fieldnames(ExperimentConfig)))
    d[:scenario] = res.scenario
    d[:per_replication] = res.per_replication
    d[:summary] = res.summary
    d[:notes] = res.notes
    return d
end

"""JSON has no `NaN`: a `nothing` in a numeric field means `NaN` when read back."""
function restore_nan(d::AbstractDict)
    out = SymDict()
    for (k, v) in d
        out[k] = v === nothing ? NaN : v
    end
    return out
end

"""Rebuild an `ExperimentResult` from its JSON record (the sample run is gone)."""
function result_from_json(d::AbstractDict)
    cfg = ExperimentConfig(SymDict((k => v for (k, v) in get(d, :config, SymDict()))))
    records = SymDict[restore_nan(SymDict(r)) for r in get(d, :per_replication, Any[])]
    summary = SymDict()
    for (k, v) in get(d, :summary, SymDict())
        summary[Sym(k)] = v isa AbstractDict ? restore_nan(SymDict(v)) : v
    end
    return ExperimentResult(Sym(get(d, :name, :experiment)), Sym(get(d, :kind, :replications)),
        cfg, SymDict(get(d, :scenario, SymDict())), records, summary, nothing,
        SymDict(get(d, :notes, SymDict())))
end

"""The JSON-able form of a comparison."""
function comparison_json(cmp::AbstractDict)
    d = SymDict()
    d[:name] = get(cmp, :name, :comparison)
    d[:objective] = get(cmp, :objective, :throughput)
    d[:order] = get(cmp, :order, Symbol[])
    d[:baseline] = get(cmp, :baseline, :none)
    d[:best] = get(cmp, :best, :none)
    d[:comparisons] = get(cmp, :comparisons, SymDict[])
    d[:verdicts] = get(cmp, :verdicts, SymDict())
    d[:results] = SymDict(nm => result_json(res) for (nm, res) in get(cmp, :results, SymDict())
                          if res isa ExperimentResult)
    return d
end

"""The JSON-able form of a sweep."""
function sweep_json(sw::AbstractDict)
    d = SymDict()
    for k in (:param, :values, :objective, :direction, :metrics, :means, :rows, :best_index,
        :best_value, :best_ci)
        haskey(sw, k) && (d[k] = sw[k])
    end
    d[:results] = [result_json(r) for r in get(sw, :results, ExperimentResult[])]
    return d
end

"""The JSON-able form of the reevaluation (the raw payload is not repeated)."""
function online_json(rec::AbstractDict)
    d = SymDict((k => v for (k, v) in rec if k !== :feed))
    feed = SymDict((k => v for (k, v) in get(rec, :feed, SymDict()) if k !== :payload))
    d[:feed] = feed
    return d
end

"""
    study_json(bundle) -> SymDict

The whole study as one JSON-ready record: every number a report or a notebook
needs, with the experiment objects in their rebuildable form.
"""
function study_json(bundle::AbstractDict)
    d = SymDict()
    d[:config] = get(bundle, :config, SymDict())
    d[:model] = get(bundle, :model, :none)
    d[:params] = get(bundle, :params, SymDict())
    history = get(bundle, :history, nothing)
    d[:history] = history isa PlantHistory ?
                  SymDict(:counts => history.counts, :meta => history.meta,
                      :summary => summarize_history(history)) : SymDict()
    d[:calibration] = get(bundle, :calibration, SymDict())
    d[:models] = SymDict(name => result_json(res)
                         for (name, res) in get(bundle, :models, SymDict())
                         if res isa ExperimentResult)
    exp = get(bundle, :experiment, nothing)
    d[:experiment] = exp isa ExperimentResult ? result_json(exp) : SymDict()
    d[:validation] = get(bundle, :validation, SymDict())
    d[:validations] = get(bundle, :validations, SymDict())
    cmp = get(bundle, :comparison, nothing)
    d[:comparison] = cmp isa AbstractDict ? comparison_json(cmp) : SymDict()
    sw = get(bundle, :sweep, nothing)
    d[:sweep] = sw isa AbstractDict ? sweep_json(sw) : SymDict()
    d[:warmup] = get(bundle, :warmup, SymDict())
    d[:batch_means] = get(bundle, :batch_means, SymDict())
    d[:factorial] = get(bundle, :factorial, SymDict())
    rec = get(bundle, :online, nothing)
    d[:online] = rec isa AbstractDict ? online_json(rec) : SymDict()
    d[:reevaluation_log] = get(bundle, :reevaluation_log, Any[])
    d[:theory] = get(bundle, :theory, nothing)
    d[:observed] = get(bundle, :observed, nothing)
    d[:artifacts] = get(bundle, :artifacts, SymDict())
    d[:manifest] = get(bundle, :manifest, SymDict())
    return d
end

## ---- the manifest ----------------------------------------------------------------

"""What the study produced, in one record (this is what a CI looks at)."""
function manifest_of(cfg::PipelineConfig, bundle::AbstractDict, artifacts::AbstractDict)
    d = SymDict()
    d[:title] = cfg.title
    d[:root] = cfg.root
    d[:seed] = cfg.seed
    d[:models] = length(cfg.models)
    d[:featured] = cfg.featured
    d[:replications] = cfg.replications
    d[:horizon] = cfg.horizon
    d[:warmup] = cfg.warmup
    d[:validation] = get(get(bundle, :validation, SymDict()), :verdict, :not_applicable)
    d[:reevaluation] = get(get(bundle, :online, SymDict()), :verdict, :keep)
    d[:pdf] = !isempty(get(artifacts, :pdf, String[]))
    d[:n_data] = length(get(artifacts, :data, String[]))
    d[:n_figures] = length(get(artifacts, :figures, String[]))
    d[:n_html] = length(get(artifacts, :html, String[]))
    d[:n_pdf] = length(get(artifacts, :pdf, String[]))
    d[:status] = d[:validation] === :failed ? :attention : :ok
    return d
end

"""Print the manifest as a short table (what the console of a CI shows)."""
function report_manifest(manifest::AbstractDict; io::IO = stdout)
    println(io, "manifest")
    for (k, v) in manifest
        label = rpad(code_string(k), 14)
        println(io, "  ", label, " ", v isa Real ? fmt_number(v) : code_string(v))
    end
    return io
end

"""`report_manifest(io, manifest)`, for `sprint` and other IO-first callers."""
report_manifest(io::IO, manifest::AbstractDict) = report_manifest(manifest; io = io)

## ---- the two entry points --------------------------------------------------------

"""
    run_study(cfg::PipelineConfig = PipelineConfig()) -> SymDict

Run the study, write every artefact (data, figures, printouts, PDFs) and return
the bundle. This is what `scripts/run_study.jl` calls, and what a scheduled job
calls to refresh the repository -- including the periodic reevaluation.
"""
function run_study(cfg::PipelineConfig = PipelineConfig())
    t0 = time()
    bundle = analysis_bundle(cfg)
    bundle[:elapsed_seconds] = round(time() - t0, digits = 1)
    bundle[:manifest][:elapsed_seconds] = bundle[:elapsed_seconds]
    if cfg.export_data
        write_json_payload(joinpath(path_of(cfg, :data), "manifest.json"), bundle[:manifest])
    end
    return bundle
end

"""
    load_study(root = pwd()) -> SymDict

Read a study back from disk: `data/analysis.json` for the numbers and
`reports/figures/*.png` for the pictures. A notebook opens in a second and shows
the same study the report was printed from; `bundle[:loaded]` says it was read
rather than computed, and `bundle[:run]` is `nothing` because a `Sim` is not a
JSON type.
"""
function load_study(root::AbstractString = pwd())
    path = joinpath(root, "data", "analysis.json")
    isfile(path) || throw(ArgumentError(string("no study found at ", path,
        "; run julia --project=. scripts/run_study.jl first")))
    raw = symbolize_deep(read_json_file(path))
    bundle = SymDict()
    bundle[:config] = get(raw, :config, SymDict())
    bundle[:model] = get(raw, :model, :none)
    bundle[:params] = get(raw, :params, SymDict())
    bundle[:history] = get(raw, :history, SymDict())
    bundle[:calibration] = get(raw, :calibration, SymDict())
    bundle[:models] = SymDict(name => result_from_json(d)
                              for (name, d) in get(raw, :models, SymDict()))
    bundle[:experiment] = haskey(get(raw, :experiment, SymDict()), :summary) ?
                          result_from_json(raw[:experiment]) : nothing
    bundle[:validation] = get(raw, :validation, SymDict())
    bundle[:validations] = get(raw, :validations, SymDict())
    bundle[:online] = get(raw, :online, SymDict())
    bundle[:reevaluation_log] = get(raw, :reevaluation_log, Any[])
    bundle[:warmup] = get(raw, :warmup, SymDict())
    bundle[:batch_means] = get(raw, :batch_means, SymDict())
    bundle[:factorial] = get(raw, :factorial, SymDict())
    bundle[:theory] = get(raw, :theory, nothing)
    bundle[:observed] = get(raw, :observed, nothing)
    bundle[:artifacts] = get(raw, :artifacts, SymDict())
    bundle[:manifest] = get(raw, :manifest, SymDict())
    bundle[:comparison] = _comparison_from_json(get(raw, :comparison, SymDict()))
    bundle[:sweep] = _sweep_from_json(get(raw, :sweep, SymDict()))
    bundle[:figures] = figure_set_from_dir(joinpath(root, "reports", "figures"))
    bundle[:run] = nothing
    bundle[:loaded] = true
    return bundle
end

"""Rebuild a comparison record from JSON."""
function _comparison_from_json(d::AbstractDict)
    isempty(d) && return d
    out = SymDict()
    for k in (:name, :objective, :order, :baseline, :best, :comparisons, :verdicts)
        haskey(d, k) && (out[k] = d[k])
    end
    out[:results] = SymDict(nm => result_from_json(r) for (nm, r) in get(d, :results, SymDict()))
    return out
end

"""Rebuild a sweep record from JSON."""
function _sweep_from_json(d::AbstractDict)
    isempty(d) && return d
    out = SymDict()
    for (k, v) in d
        k === :results && continue
        out[k] = v
    end
    out[:results] = [result_from_json(r) for r in get(d, :results, Any[])]
    return out
end

"""Every figure of a repository, read back from the PNG files, by name."""
function figure_set_from_dir(dir::AbstractString)
    figs = SymDict()
    isdir(dir) || return figs
    for f in sort(readdir(dir))
        endswith(f, ".png") || continue
        name = Symbol(replace(f, ".png" => ""))
        figs[name] = figure_from_png(joinpath(dir, f), name)
    end
    return figs
end