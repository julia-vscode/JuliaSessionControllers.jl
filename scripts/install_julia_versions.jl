# Install every Julia version the session processes support, via juliaup.
#
#     julia scripts/install_julia_versions.jl

const JULIA_VERSIONS = [
    "1.0", "1.1", "1.2", "1.3", "1.4", "1.5", "1.6", "1.7",
    "1.8", "1.9", "1.10", "1.11", "1.12", "1.13", "nightly",
]

for version in JULIA_VERSIONS
    @info "Installing Julia" version
    try
        run(`juliaup add $version`)
    catch err
        @warn "Could not install Julia $version" exception = (err,)
    end
end
