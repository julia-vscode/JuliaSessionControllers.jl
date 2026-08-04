using TestItemRunner

ENV["JULIA_DEBUG"] = "JuliaSessionsControllers"

# The cross-version suite needs every supported Julia installed via juliaup, so it is opt-in.
const RUN_COMPREHENSIVE = get(ENV, "JSC_COMPREHENSIVE", "false") == "true"

@run_package_tests filter = ti -> startswith(ti.filename, joinpath(@__DIR__, "")) &&
                                 (RUN_COMPREHENSIVE || !(:comprehensive_platform in ti.tags))
