#!/usr/bin/env julia
# =============================================================================
# run_notebooks.jl -- run every Pluto notebook headless and print its PDF.
#
#   julia --project=. scripts/run_notebooks.jl [options]
#
#     --only=00_Study,03_The_Models   run only the listed notebooks
#     --no-save                       do not write the notebooks back
#
# Each notebook loads the artefacts of `scripts/run_study.jl`, shows its section
# of the report and, in its last cell, prints that section to
# `reports/pdf/notebook_<section>.pdf` -- so this script is what proves that a
# reader can open the notebooks and get the PDFs out of them.
# =============================================================================

using DiscreteSim

const NOTEBOOK_DIR = joinpath(pwd(), "notebooks")

function main(args = ARGS)
    only = [a for a in args if startswith(a, "--only=")]
    selected = isempty(only) ? nothing : split(only[1][8:end], ',')
    save = !any(==("--no-save"), args)

    files = notebook_files(NOTEBOOK_DIR)
    selected === nothing ||
        (files = [f for f in files if any(s -> startswith(basename(f), s), selected)])
    println("running ", length(files), " notebook(s) from ", NOTEBOOK_DIR, "\n")

    reports = Dict{Symbol,Any}[]
    for f in files
        push!(reports, run_notebook(f; save = save))
        print_notebook_report(reports[end])
    end
    ok = count(r -> r[:ok], reports)
    println("\nnotebooks passed : ", ok, " / ", length(reports))
    return reports
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
