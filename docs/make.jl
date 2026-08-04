using Documenter, JuliaSessionsControllers

makedocs(
    sitename = "JuliaSessionsControllers.jl",
    modules = [JuliaSessionsControllers],
    # Stated explicitly so the build does not depend on a configured git remote.
    repo = Documenter.Remotes.GitHub("julia-testitems", "JuliaSessionsControllers.jl"),
    pages = [
        "Home" => "index.md",
        "API" => "api.md",
        "Internals" => "internals.md",
    ],
    checkdocs = :exports,
    # The vendored dependencies carry their own docstrings, which are not ours to publish.
    checkdocs_ignored_modules = [
        JuliaSessionsControllers.CancellationTokens,
        JuliaSessionsControllers.JSON,
        JuliaSessionsControllers.JSONRPC,
        JuliaSessionsControllers.URIParser,
        JuliaSessionsControllers.JuliaSessionServerProtocol,
    ],
)

deploydocs(repo = "github.com/julia-testitems/JuliaSessionsControllers.jl.git")
