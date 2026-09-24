# =============================================================================
# runtests.jl -- the test suite of DiscreteSim.
#
#   julia --project=. -e 'using Pkg; Pkg.test()'
#
# The suite is organised the way the package is: one file per layer, from the
# vocabulary and the calendar up to the pipeline and the notebooks. The tests that
# matter most are the ones that check the engine against *theory* (M/M/1, M/M/c,
# Little's law) and the ones that check that a run is reproducible from its seed:
# everything else can be wrong and still look plausible, those cannot.
# =============================================================================

using DiscreteSim
using Test
using Statistics
using Random
using Dates
using Printf
using Distributions
import StableRNGs
import Tables
import JSON3
import HTTP
import Plots
import Statistics: mean, std, var, quantile
import Distributions: cdf, pdf
import Base: minimum, maximum

const TEST_TMP = mktempdir(; prefix = "discretesim_test")

@testset "DiscreteSim" verbose = true begin
    include("test_symbols.jl")
    include("test_engine.jl")
    include("test_processes.jl")
    include("test_resources.jl")
    include("test_statistics.jl")
    include("test_random.jl")
    include("test_analytical.jl")
    include("test_experiments.jl")
    include("test_models.jl")
    include("test_data.jl")
    include("test_online.jl")
    include("test_printout.jl")
    include("test_notebooks.jl")
    include("test_pipeline.jl")
end
