# Shared registry of the vendored package trees.
#
# `packages/` holds the versions used on modern Julia. `packages-old/v1.5` and
# `packages-old/v1.9` hold the last releases that still support those older Julia
# versions; `sessionprocess/JuliaSessionServer/src/pkg_imports.jl` picks between them.

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

"""
Vendored trees that track upstream: prefix => (github location, pinned tag).

Only the `packages/` entries are updated by `update_vendored_packages.jl`; the
`packages-old/` tiers are frozen at the last release supporting their Julia version.
"""
const CURRENT_SUBTREES = [
    "packages/BenchmarkTools"     => ("JuliaCI/BenchmarkTools.jl", "v1.8.0"),
    "packages/CancellationTokens" => ("davidanthoff/CancellationTokens.jl", "v2.3.0"),
    "packages/CodeTracking"       => ("timholy/CodeTracking.jl", "v3.0.2"),
    "packages/Compat"             => ("JuliaLang/Compat.jl", "v4.18.1"),
    "packages/DebugAdapter"       => ("julia-vscode/DebugAdapter.jl", "v3.1.0"),
    "packages/JSON"               => ("JuliaIO/JSON.jl", "v0.20.1"),
    "packages/JSONRPC"            => ("julia-vscode/JSONRPC.jl", "v3.0.1"),
    "packages/JuliaInterpreter"   => ("JuliaDebug/JuliaInterpreter.jl", "v0.10.12"),
    "packages/LoweredCodeUtils"   => ("JuliaDebug/LoweredCodeUtils.jl", "v3.5.1"),
    "packages/OrderedCollections" => ("JuliaCollections/OrderedCollections.jl", "v1.8.1"),
    "packages/Preferences"        => ("JuliaPackaging/Preferences.jl", "v1.5.2"),
    "packages/Revise"             => ("timholy/Revise.jl", "v3.14.4"),
    "packages/TestEnv"            => ("JuliaTesting/TestEnv.jl", "v1.103.6"),
    "packages/URIParser"          => ("JuliaWeb/URIParser.jl", "v0.4.1"),
]

# Not vendored as a subtree: the `Compiler` package LoweredCodeUtils needs on Julia >= 1.10.
# Upstream (JuliaLang/BaseCompiler.jl) only tags releases that vendor the whole compiler
# pinned to a single Julia version, which is not what we want. We ship the 21-line
# re-export shim as first-party source in sessionprocess/JuliaSessionServer/src instead.

const OLD_SUBTREES = [
    "packages-old/v1.9/CodeTracking"       => ("timholy/CodeTracking.jl", "v1.3.9"),
    "packages-old/v1.9/JuliaInterpreter"   => ("JuliaDebug/JuliaInterpreter.jl", "v0.9.37"),
    "packages-old/v1.9/LoweredCodeUtils"   => ("JuliaDebug/LoweredCodeUtils.jl", "v3.0.5"),
    "packages-old/v1.9/Revise"             => ("timholy/Revise.jl", "v3.6.6"),

    "packages-old/v1.5/CodeTracking"       => ("timholy/CodeTracking.jl", "v1.1.2"),
    "packages-old/v1.5/JuliaInterpreter"   => ("JuliaDebug/JuliaInterpreter.jl", "v0.8.21"),
    "packages-old/v1.5/LoweredCodeUtils"   => ("JuliaDebug/LoweredCodeUtils.jl", "v2.1.1"),
    "packages-old/v1.5/OrderedCollections" => ("JuliaCollections/OrderedCollections.jl", "v1.5.0"),
    "packages-old/v1.5/Revise"             => ("timholy/Revise.jl", "v3.2.1"),
]

"""
Packages deliberately excluded from automated updates, with the reason why.
"""
const UPDATE_EXCLUSIONS = Dict(
    "packages/JSON" => "Newer JSON versions add dependencies we would have to vendor too.",
)

git(args...; dir=REPO_ROOT) = run(addenv(Cmd(`git $(collect(args))`, dir=dir), "GIT_MERGE_AUTOEDIT" => "no"))

"""
    remote_tags(location)

All `vX.Y.Z` tags of a GitHub repository, as `VersionNumber`s. Uses `git ls-remote` so
that no GitHub API token is required.
"""
function remote_tags(location::AbstractString)
    out = read(`git ls-remote --tags --refs https://github.com/$location`, String)
    versions = VersionNumber[]
    for line in eachsplit(out, '\n')
        m = match(r"refs/tags/v(\d+\.\d+\.\d+)$", strip(line))
        m === nothing || push!(versions, VersionNumber(m[1]))
    end
    return versions
end

vendored_version(prefix) = VersionNumber(
    something(
        match(r"(?m)^version\s*=\s*\"([^\"]+)\"", read(joinpath(REPO_ROOT, prefix, "Project.toml"), String)),
        error("No version found in $prefix/Project.toml"),
    )[1]
)
