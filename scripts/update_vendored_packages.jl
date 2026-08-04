# Update the vendored `packages/` trees to the newest upstream release.
#
#     julia scripts/update_vendored_packages.jl          # report only
#     julia scripts/update_vendored_packages.jl --apply  # also pull the subtrees
#
# The `packages-old/` tiers are intentionally never touched: they are pinned to the last
# release supporting Julia 1.5 / 1.9.
#
# After applying, bump the tags in `vendored_packages.jl` so a fresh bootstrap reproduces
# the same trees.

include("vendored_packages.jl")

const APPLY = "--apply" in ARGS

outdated = Tuple{String,String,VersionNumber,VersionNumber}[]

for (prefix, (location, _)) in CURRENT_SUBTREES
    if haskey(UPDATE_EXCLUSIONS, prefix)
        println("$prefix: skipped — $(UPDATE_EXCLUSIONS[prefix])")
        continue
    end

    current = vendored_version(prefix)
    tags = remote_tags(location)
    if isempty(tags)
        @warn "No release tags found upstream" prefix location
        continue
    end
    latest = maximum(tags)

    println("$prefix: vendored $current, latest $latest")
    latest > current && push!(outdated, (prefix, location, current, latest))
end

if isempty(outdated)
    println("\nEverything is up to date.")
elseif !APPLY
    println("\n$(length(outdated)) package(s) can be updated. Re-run with --apply to pull them.")
else
    for (prefix, location, _, latest) in outdated
        @info "Pulling subtree" prefix latest
        git("subtree", "pull", "--prefix", prefix, "https://github.com/$location", "v$latest", "--squash")
    end
    println("\nUpdated $(length(outdated)) package(s). Remember to bump the pinned tags in scripts/vendored_packages.jl.")
end
