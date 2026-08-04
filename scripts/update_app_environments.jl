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

environments_dir() = normpath(joinpath(REPO_ROOT, "sessionprocess", "environments"))

develop_command() = "using Pkg; Pkg.develop(PackageSpec(path=\"../../JuliaSessionServer\"))"

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

    @info "Building session process environment" version path
    run(Cmd(`julia +$julia_spec --project=. -e $(develop_command())`, dir=path))

    version in ("1.0", "1.1") && normalize_manifest_separators(version)
    return nothing
end

requested = isempty(ARGS) ? JULIA_VERSIONS : ARGS

for version in requested
    build_environment(version, version)
end

# The fallback environment covers Julia versions newer than anything listed above.
isempty(ARGS) && build_environment("fallback", "nightly")
