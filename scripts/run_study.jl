#!/usr/bin/env julia
# =============================================================================
# run_study.jl -- generate the data, the experiments, the printouts and the PDFs.
#
#   julia --project=. scripts/run_study.jl [options]
#
#     --seed=20260101        seed of the whole study (reproducibility)
#     --days=90              days of plant history to generate
#     --reps=12              replications per experiment
#     --horizon=6000         length of one run, in the model time unit
#     --warmup=600           time discarded at the start of every run
#     --model=machine_shop   the model the study is built around
#     --objective=...        metric the study optimises (:cycle_time_mean by default)
#     --online=offline_first online policy: offline_first, online_first or cache_only
#     --url=...              override the periodic feed URL
#     --no-data              skip the CSV/JSON export
#     --no-pdf               skip the PDF printing
#     --no-figures           skip the figures (faster)
#     --parallel             spread the replications over the available threads
#     --root=PATH            repository root (default: the working directory)
# =============================================================================

using DiscreteSim
using Dates

"""Parse `--key=value` options into a symbol-keyed record."""
function parse_options(args::Vector{String})
    opts = SymDict()
    for a in args
        startswith(a, "--") || continue
        body = a[3:end]
        key, _, value = partition_string(body, '=')
        k = Sym(key)
        opts[k] = value === "" ? true :
                  k in (:seed, :reps, :replications) ? parse(Int, value) :
                  k in (:days, :horizon, :warmup) ? parse(Float64, value) :
                  String(value)
    end
    return opts
end

"""Split a string at the first occurrence of `sep`."""
function partition_string(s::AbstractString, sep::Char)
    i = findfirst(==(sep), s)
    i === nothing && return (String(s), sep, "")
    return (String(s[1:(i - 1)]), sep, String(s[(i + 1):end]))
end

function main(args = ARGS)
    opts = parse_options(collect(String.(args)))
    root = get(opts, :root, pwd())
    online = OnlineConfig(policy = Sym(get(opts, :online, :offline_first)))
    haskey(opts, :url) && (online.url = String(opts[:url]))
    cfg = PipelineConfig(
        root = root,
        seed = get(opts, :seed, 20260101),
        days = get(opts, :days, 90.0),
        replications = get(opts, :reps, get(opts, :replications, 12)),
        horizon = get(opts, :horizon, 6000.0),
        warmup = get(opts, :warmup, 600.0),
        featured = Sym(get(opts, :model, :machine_shop)),
        objective = Sym(get(opts, :objective, :cycle_time_mean)),
        export_data = !get(opts, :no_data, false),
        render_pdf = !get(opts, :no_pdf, false),
        figures = !get(opts, :no_figures, false),
        parallel = get(opts, :parallel, false),
        online = online,
    )

    println("DiscreteSim study")
    println("  root         : ", cfg.root)
    println("  seed         : ", cfg.seed, "   days ", cfg.days)
    println("  design       : ", cfg.replications, " replications of ", cfg.horizon,
        " (warmup ", cfg.warmup, ")")
    println("  models       : ", join(code_string.(cfg.models), ", "))
    println("  featured     : ", code_string(cfg.featured), "  objective ",
        code_string(cfg.objective))
    println("  online policy: ", code_string(cfg.online.policy), "  ", cfg.online.url)
    println("  pdf printing : ", pdf_available(; explicit = cfg.chrome) ?
        string("enabled (", find_chrome(; explicit = cfg.chrome), ")") :
        "requested but no browser found")
    println()

    t0 = time()
    bundle = run_study(cfg)
    println()
    report_manifest(bundle[:manifest])
    println()
    println("elapsed      : ", round(time() - t0, digits = 1), " s")
    return bundle
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
