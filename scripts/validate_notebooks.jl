#!/usr/bin/env julia
# =============================================================================
# validate_notebooks.jl -- check every notebook the way Pluto will run it.
#
#   julia --project=. scripts/validate_notebooks.jl [notebooks]
#
# The checks are static (they never start Julia for the notebook): the Pluto
# header, unique cell ids, a `Cell order` section that lists every cell, one
# top-level expression per code cell, no reference to a global that is never
# defined, and at least one cell that writes the printout and prints its PDF.
# Exit code 1 when a notebook does not pass, so a CI can gate on it.
# =============================================================================

using DiscreteSim

function main(args = ARGS)
    dir = isempty(args) ? "notebooks" : String(first(args))
    results = validate_notebooks(dir)
    isempty(results) && (println("no notebooks found in ", dir); return 1)
    print_validation_report(results)
    failed = count(r -> !r[:ok], results)
    if failed > 0
        println("\n", failed, " notebook(s) failed the static checks")
        exit(1)
    end
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
