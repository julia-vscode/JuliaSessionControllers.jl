# Regenerate the private environments the session processes activate, one per supported
# Julia version. Requires juliaup with every listed version installed
# (see `install_julia_versions.jl`).
#
#     julia scripts/update_app_environments.jl [1.12 1.13 ...]
#
# Pass versions to regenerate only those; with no arguments every version is rebuilt.

include("vendored_packages.jl")

const JULIA_VERSIONS = [
    "1.0", "1.1", "1.2", "1.3", "1.4", "1.5", "1.6", "1.7",
    "1.8", "1.9", "1.10", "1.11", "1.12", "1.13",
]

# BenchmarkTools cannot be `include`d like the other vendored packages, so it is developed
# into the environment as a real package instead — only where the vendored release runs.
const BENCHMARKTOOLS_MIN_JULIA = v"1.6"
const BENCHMARKTOOLS_STACK = ["BenchmarkTools", "Compat", "JSON", "PrecompileTools", "Preferences"]

environments_dir() = normpath(joinpath(REPO_ROOT, "sessionprocess", "environments"))

function develop_specs(julia_version::VersionNumber)
    specs = ["PackageSpec(path=\"../../JuliaSessionServer\")"]
    if julia_version >= BENCHMARKTOOLS_MIN_JULIA
        for pkg in BENCHMARKTOOLS_STACK
            push!(specs, "PackageSpec(path=\"../../../packages/$pkg\")")
        end
    end
    return "using Pkg; Pkg.develop([" * join(specs, ", ") * "])"
end

"""
Julia 1.0 and 1.1 write Windows path separators into the manifest, which then fails to
resolve on other platforms. Rewrite them to forward slashes.
"""
function normalize_manifest_separators(version::AbstractString)
    filename = joinpath(environments_dir(), "v$version", "Manifest.toml")
    isfile(filename) || return
    write(filename, replace(read(filename, String), "\\\\" => '/'))
end

function build_environment(version::AbstractString, julia_spec::AbstractString)
    path = joinpath(environments_dir(), version == "fallback" ? "fallback" : "v$version")
    mkpath(path)

    julia_version = version == "fallback" ? VersionNumber(string(VERSION.major, '.', VERSION.minor)) : VersionNumber(version)
    @info "Building session process environment" version path
    run(Cmd(`julia +$julia_spec --project=. -e $(develop_specs(julia_version))`, dir=path))

    version in ("1.0", "1.1") && normalize_manifest_separators(version)
    return nothing
end

requested = isempty(ARGS) ? JULIA_VERSIONS : ARGS

for version in requested
    build_environment(version, version)
end

# The fallback environment covers Julia versions newer than anything listed above.
isempty(ARGS) && build_environment("fallback", "nightly")
