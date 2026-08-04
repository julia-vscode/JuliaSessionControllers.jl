# One-time bootstrap of the vendored package trees.
#
#     julia scripts/bootstrap_vendored_packages.jl
#
# Adds every entry of `CURRENT_SUBTREES` / `OLD_SUBTREES` as a squashed git subtree.
# Trees that already exist are skipped, so the script is safe to re-run after a failure.
# Use `update_vendored_packages.jl` to move `packages/` forward afterwards.

include("vendored_packages.jl")

function add_subtree(prefix, location, tag)
    if isdir(joinpath(REPO_ROOT, prefix))
        @info "Skipping, already vendored" prefix
        return false
    end

    @info "Adding subtree" prefix location tag
    git("subtree", "add", "--prefix", prefix, "https://github.com/$location", tag, "--squash")
    return true
end

added = 0
for (prefix, (location, tag)) in vcat(CURRENT_SUBTREES, OLD_SUBTREES)
    global added += add_subtree(prefix, location, tag)
end

@info "Bootstrap finished" added total = length(CURRENT_SUBTREES) + length(OLD_SUBTREES)
